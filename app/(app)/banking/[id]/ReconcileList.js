'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { money, readableError, shortDate } from '@/lib/format';

/**
 * The reconciliation screen.
 *
 * Each unmatched statement line expands to show what the database thinks
 * it might be, in order of trustworthiness:
 *
 *   1. Something already in the ledger for that amount around that date.
 *      Almost always right, and confirming it is what stops bank imports
 *      duplicating what the sales and purchase ledgers already recorded.
 *   2. An unpaid invoice or bill for exactly this amount, which can be
 *      settled and allocated in one action.
 *   3. A saved rule matching the description.
 *
 * Failing all three, code it by hand — with the option to remember the
 * coding as a rule so the same payment next month is one click.
 */

const KIND_LABELS = {
  journal_line: 'Already recorded',
  ledger_item: 'Unpaid invoice',
  rule: 'Saved rule',
};

function Suggestion({ suggestion, onUse, busy }) {
  const strong = suggestion.score >= 0.9;

  return (
    <div
      className="suggestion"
      style={{
        borderColor: strong ? 'var(--accent)' : 'var(--line-strong)',
        background: strong ? 'var(--accent-wash)' : 'var(--surface)',
      }}
    >
      <div style={{ flex: 1, minWidth: 0 }}>
        <div className="row" style={{ gap: '0.4375rem' }}>
          <span className={`pill ${strong ? 'pill-accent' : ''}`}>
            {KIND_LABELS[suggestion.kind] || suggestion.kind}
          </span>
          <strong className="small">{suggestion.label}</strong>
        </div>
        <div className="hint" style={{ marginTop: '0.1875rem' }}>
          {suggestion.detail}
          {suggestion.ref_date && ` · ${shortDate(suggestion.ref_date)}`}
        </div>
      </div>
      <button className="btn btn-primary btn-sm" onClick={onUse} disabled={busy}>
        {suggestion.kind === 'journal_line'
          ? 'This is it'
          : suggestion.kind === 'ledger_item'
          ? 'Settle it'
          : 'Use rule'}
      </button>
    </div>
  );
}

function LineRow({ line, orgId, accounts, vatCodes, contacts, bankAccounts, pro, currencyCode }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [suggestions, setSuggestions] = useState(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [mode, setMode] = useState('nominal');

  const isIn = Number(line.amount) > 0;

  const [form, setForm] = useState({
    account_id: '',
    vat_code_id: '',
    contact_id: '',
    description: line.description,
    remember: false,
    to_bank_account_id: '',
  });

  const set = (patch) => setForm((f) => ({ ...f, ...patch }));

  async function expand() {
    setOpen(!open);
    if (open || suggestions) return;

    setLoading(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc('suggest_matches_for_line', {
      p_line_id: line.id,
    });
    setLoading(false);

    if (error) {
      setError(readableError(error));
      return;
    }
    setSuggestions(data || []);
  }

  async function run(fn) {
    setBusy(true);
    setError(null);
    const { error } = await fn(createClient());
    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }
    router.refresh();
  }

  /* Every suggestion carries the payload needed to act on it, built by
     suggest_matches_for_line(), so nothing is reconstructed here. */
  const useSuggestion = (s) => {
    if (s.kind === 'journal_line') {
      return run((sb) =>
        sb.rpc('match_statement_line', {
          p_line_id: line.id,
          p_journal_line_id: s.ref_id,
        })
      );
    }

    return run((sb) =>
      sb.rpc('create_from_statement_line', {
        p_line_id: line.id,
        p_config: s.payload,
      })
    );
  };

  const createManually = () =>
    run((sb) =>
      sb.rpc('create_from_statement_line', {
        p_line_id: line.id,
        p_config:
          mode === 'transfer'
            ? { kind: 'transfer', to_bank_account_id: form.to_bank_account_id }
            : mode === 'settle'
            ? { kind: 'settle', contact_id: form.contact_id, auto_allocate: true }
            : {
                kind: 'nominal',
                account_id: form.account_id,
                vat_code_id: form.vat_code_id || null,
                contact_id: form.contact_id || null,
                description: form.description,
                remember: form.remember,
              },
      })
    );

  const exclude = () =>
    run((sb) =>
      sb.rpc('exclude_statement_line', {
        p_line_id: line.id,
        p_reason: 'Not a business transaction',
      })
    );

  const manualReady =
    mode === 'transfer'
      ? Boolean(form.to_bank_account_id)
      : mode === 'settle'
      ? Boolean(form.contact_id)
      : Boolean(form.account_id);

  const strongCount = (suggestions || []).filter((s) => s.score >= 0.9).length;

  return (
    <>
      <tr onClick={expand} style={{ cursor: 'pointer' }}>
        <td className="nowrap">{shortDate(line.date)}</td>
        <td className="small">{line.description}</td>
        <td>
          <span className={`num ${isIn ? 'num-positive' : 'num-negative'}`}>
            {money(line.amount)}
          </span>
        </td>
        <td>
          {suggestions === null ? (
            <span className="muted small">{open && loading ? 'Looking…' : ''}</span>
          ) : strongCount > 0 ? (
            <span className="pill pill-accent">{strongCount} likely match</span>
          ) : suggestions.length > 0 ? (
            <span className="pill pill-caution">{suggestions.length} possible</span>
          ) : (
            <span className="pill">Needs coding</span>
          )}
        </td>
        <td>
          <button className="btn btn-ghost btn-sm">{open ? 'Close' : 'Deal with it'}</button>
        </td>
      </tr>

      {open && (
        <tr className="no-hover">
          <td colSpan={5} style={{ background: 'var(--surface-sunk)', padding: '1rem 1.25rem' }}>
            {error && <div className="notice notice-error">{error}</div>}

            {loading && <p className="hint">Looking for a match…</p>}

            {suggestions?.length > 0 && (
              <div className="stack stack-sm" style={{ marginBottom: '1rem' }}>
                {suggestions.map((s, i) => (
                  <Suggestion
                    key={`${s.kind}-${s.ref_id}-${i}`}
                    suggestion={s}
                    busy={busy}
                    onUse={() => useSuggestion(s)}
                  />
                ))}
              </div>
            )}

            <div className="card">
              <div className="card-head">
                <h3>{suggestions?.length ? 'Or record it yourself' : 'Record it'}</h3>
                <div className="btn-row">
                  {['nominal', 'settle', 'transfer'].map((m) => (
                    <button
                      key={m}
                      className={`btn btn-sm ${mode === m ? 'btn-primary' : 'btn-ghost'}`}
                      onClick={() => setMode(m)}
                    >
                      {m === 'nominal'
                        ? pro ? 'To a nominal' : 'A cost or sale'
                        : m === 'settle'
                        ? isIn ? 'Customer payment' : 'Supplier payment'
                        : 'Transfer'}
                    </button>
                  ))}
                </div>
              </div>

              <div className="card-body">
                {mode === 'nominal' && (
                  <>
                    <div className="grid grid-2">
                      <label className="field">
                        <span className="label">{pro ? 'Account' : 'Category'}</span>
                        <select
                          className="select"
                          value={form.account_id}
                          onChange={(e) => set({ account_id: e.target.value })}
                        >
                          <option value="">Choose…</option>
                          {accounts.map((a) => (
                            <option key={a.id} value={a.id}>
                              {pro ? `${a.code} — ${a.name}` : a.friendly_name || a.name}
                            </option>
                          ))}
                        </select>
                      </label>

                      {vatCodes.length > 0 && (
                        <label className="field">
                          <span className="label">VAT</span>
                          <select
                            className="select"
                            value={form.vat_code_id}
                            onChange={(e) => set({ vat_code_id: e.target.value })}
                          >
                            <option value="">No VAT</option>
                            {vatCodes.map((v) => (
                              <option key={v.id} value={v.id}>
                                {pro ? `${v.code} ${v.rate}%` : v.friendly_name}
                              </option>
                            ))}
                          </select>
                          <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                            VAT comes out of the {money(Math.abs(line.amount))}, it is not added on.
                          </span>
                        </label>
                      )}
                    </div>

                    <label className="field">
                      <span className="label">Description</span>
                      <input
                        className="input"
                        value={form.description}
                        onChange={(e) => set({ description: e.target.value })}
                      />
                    </label>

                    <label className="row" style={{ gap: '0.5rem', cursor: 'pointer' }}>
                      <input
                        type="checkbox"
                        checked={form.remember}
                        onChange={(e) => set({ remember: e.target.checked })}
                      />
                      <span className="small">
                        Remember this for anything similar in future
                      </span>
                    </label>
                  </>
                )}

                {mode === 'settle' && (
                  <label className="field" style={{ marginBottom: 0 }}>
                    <span className="label">{isIn ? 'Which customer?' : 'Which supplier?'}</span>
                    <select
                      className="select"
                      value={form.contact_id}
                      onChange={(e) => set({ contact_id: e.target.value })}
                    >
                      <option value="">Choose…</option>
                      {contacts
                        .filter((c) => (isIn ? c.is_customer : c.is_supplier))
                        .map((c) => (
                          <option key={c.id} value={c.id}>{c.name}</option>
                        ))}
                    </select>
                    <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                      Their oldest unpaid items will be settled first. Anything
                      left over sits on account.
                    </span>
                  </label>
                )}

                {mode === 'transfer' && (
                  <label className="field" style={{ marginBottom: 0 }}>
                    <span className="label">
                      {isIn ? 'Which account did it come from?' : 'Which account did it go to?'}
                    </span>
                    <select
                      className="select"
                      value={form.to_bank_account_id}
                      onChange={(e) => set({ to_bank_account_id: e.target.value })}
                    >
                      <option value="">Choose…</option>
                      {bankAccounts.map((b) => (
                        <option key={b.id} value={b.id}>{b.name}</option>
                      ))}
                    </select>
                  </label>
                )}

                <div className="btn-row mt-md">
                  <button className="btn btn-danger btn-sm" onClick={exclude} disabled={busy}>
                    Not business, ignore it
                  </button>
                  <div className="spacer" />
                  <button
                    className="btn btn-primary btn-sm"
                    onClick={createManually}
                    disabled={!manualReady || busy}
                  >
                    {busy ? 'Recording…' : 'Record and reconcile'}
                  </button>
                </div>
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

export default function ReconcileList({
  lines,
  orgId,
  accounts,
  vatCodes,
  contacts,
  bankAccounts,
  pro,
  currencyCode,
}) {
  if (lines.length === 0) {
    return (
      <div className="empty">
        <h3>Everything is dealt with</h3>
        <p>
          Every imported line has been matched or excluded. Import the next
          statement when you have it.
        </p>
      </div>
    );
  }

  return (
    <table className="table table-flush">
      <thead>
        <tr>
          <th style={{ width: '7rem' }}>Date</th>
          <th>Description</th>
          <th className="num" style={{ width: '8rem' }}>Amount</th>
          <th style={{ width: '10rem' }}>Suggestion</th>
          <th style={{ width: '8rem' }} />
        </tr>
      </thead>
      <tbody>
        {lines.map((line) => (
          <LineRow
            key={line.id}
            line={line}
            orgId={orgId}
            accounts={accounts}
            vatCodes={vatCodes}
            contacts={contacts}
            bankAccounts={bankAccounts}
            pro={pro}
            currencyCode={currencyCode}
          />
        ))}
      </tbody>
    </table>
  );
}

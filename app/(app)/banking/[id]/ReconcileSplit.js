'use client';

import { useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { money, readableError, shortDate } from '@/lib/format';

/**
 * Reconciliation, side by side.
 *
 * The bank's version of the transaction on the left, what Clearview is
 * going to do with it on the right. Suggestions are already loaded and
 * already shown — nothing has to be clicked open to find out whether
 * there is a match waiting.
 *
 * The right-hand side is pre-filled from the best suggestion, so the
 * common case is reading one line and pressing one button. Everything is
 * still editable, and the alternatives are one click away.
 */

/**
 * What the suggestion proposes to DO, not what it found.
 *
 * "Unpaid invoice" describes the thing; "pay off supplier invoice"
 * describes what pressing Accept will do, which is the only thing the
 * reader actually needs to decide about.
 */
function suggestionLabel(kind, isIn) {
  if (kind === 'journal_line') return 'Suggested: match to a transaction already recorded';
  if (kind === 'ledger_item') {
    return isIn
      ? 'Suggested: settle customer invoice'
      : 'Suggested: pay off supplier invoice';
  }
  if (kind === 'rule') return 'Suggested: apply your saved rule';
  return 'Suggested';
}

function shortKindLabel(kind, isIn) {
  if (kind === 'journal_line') return 'Already recorded';
  if (kind === 'ledger_item') return isIn ? 'Customer invoice' : 'Supplier invoice';
  if (kind === 'rule') return 'Saved rule';
  return kind;
}

const MODES = [
  ['nominal', 'Category'],
  ['settle', 'Invoice'],
  ['transfer', 'Transfer'],
];

function Line({
  line, suggestions, accounts, vatCodes, contacts, bankAccounts,
  pro, vatEnabled, orgId, bankAccountId,
}) {
  const router = useRouter();
  const isIn = Number(line.amount) > 0;
  const gross = Math.abs(Number(line.amount));

  const best = suggestions[0] || null;
  const alternatives = suggestions.slice(1);

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [showAlternatives, setShowAlternatives] = useState(false);
  const [manual, setManual] = useState(false);

  // Pre-fill from a rule suggestion, since that already carries a coding.
  const ruleSuggestion = suggestions.find((s) => s.kind === 'rule');

  const [mode, setMode] = useState('nominal');
  const [form, setForm] = useState({
    account_id: ruleSuggestion?.payload?.account_id || '',
    vat_code_id: vatEnabled ? ruleSuggestion?.payload?.vat_code_id || '' : '',
    contact_id: '',
    description: line.description,
    to_bank_account_id: '',
  });

  /* Outstanding items for the chosen contact, and what is being put
     against each. Chosen deliberately rather than swept oldest-first —
     when you are looking at one payment on a bank statement you usually
     know exactly which invoice it settles. */
  const [items, setItems] = useState([]);
  const [loadingItems, setLoadingItems] = useState(false);
  const [alloc, setAlloc] = useState({});

  useEffect(() => {
    if (mode !== 'settle' || !form.contact_id) {
      setItems([]);
      setAlloc({});
      return;
    }

    let cancelled = false;
    setLoadingItems(true);

    createClient()
      .from('ledger_item_outstanding')
      .select('id, date, due_date, reference, item_type, outstanding_amount, days_overdue')
      .eq('organisation_id', orgId)
      .eq('contact_id', form.contact_id)
      .eq('ledger', isIn ? 'sales' : 'purchase')
      .eq('direction', isIn ? 'debit' : 'credit')
      .gt('outstanding_amount', 0)
      .order('due_date', { nullsFirst: false })
      .then(({ data }) => {
        if (cancelled) return;
        const rows = data || [];
        setItems(rows);
        setLoadingItems(false);

        // An exact match for the whole payment is almost certainly the
        // right answer, so fill it in rather than making them do it.
        const exact = rows.find(
          (r) => Math.abs(Number(r.outstanding_amount) - gross) < 0.005
        );
        setAlloc(exact ? { [exact.id]: gross.toFixed(2) } : {});
      });

    return () => {
      cancelled = true;
    };
  }, [mode, form.contact_id, orgId, isIn, gross]);

  const allocated = useMemo(
    () =>
      Math.round(
        Object.values(alloc).reduce((s, v) => s + (Number(v) || 0), 0) * 100
      ) / 100,
    [alloc]
  );

  const onAccount = Math.round((gross - allocated) * 100) / 100;
  const overAllocated = allocated > gross + 0.005;

  const [rule, setRule] = useState({
    save: false,
    pattern: line.suggested_pattern || '',
    scope: 'this',
    reach: null,
  });

  const set = (patch) => setForm((f) => ({ ...f, ...patch }));

  /* How many other unmatched lines this rule would catch. Checked when
     the pattern changes so the reach is visible before it is saved. */
  async function checkReach(pattern) {
    if (!pattern.trim()) {
      setRule((r) => ({ ...r, reach: null }));
      return;
    }
    const supabase = createClient();
    const { data } = await supabase.rpc('preview_rule_matches', {
      p_organisation_id: orgId,
      p_bank_account_id: rule.scope === 'this' ? bankAccountId : null,
      p_pattern: pattern,
      p_match_type: 'contains',
      p_direction: isIn ? 'in' : 'out',
      p_exclude_line_id: line.id,
    });
    setRule((r) => ({ ...r, reach: data ?? 0 }));
  }

  async function run(fn) {
    setBusy(true);
    setError(null);
    const { error } = await fn(createClient());
    setBusy(false);
    if (error) {
      setError(readableError(error));
      return false;
    }
    router.refresh();
    return true;
  }

  const accept = (s) =>
    s.kind === 'journal_line'
      ? run((sb) =>
          sb.rpc('match_statement_line', {
            p_line_id: line.id,
            p_journal_line_id: s.ref_id,
          })
        )
      : run((sb) =>
          sb.rpc('create_from_statement_line', {
            p_line_id: line.id,
            p_config: s.payload,
          })
        );

  async function record() {
    const config =
      mode === 'transfer'
        ? { kind: 'transfer', to_bank_account_id: form.to_bank_account_id }
        : mode === 'settle'
        ? {
            kind: 'settle',
            contact_id: form.contact_id,
            allocations: Object.entries(alloc)
              .filter(([, v]) => Number(v) > 0)
              .map(([item_id, v]) => ({ item_id, amount: Number(v) })),
          }
        : {
            kind: 'nominal',
            account_id: form.account_id,
            vat_code_id: form.vat_code_id || null,
            contact_id: form.contact_id || null,
            description: form.description,
          };

    const ok = await run((sb) =>
      sb.rpc('create_from_statement_line', { p_line_id: line.id, p_config: config })
    );

    if (!ok || !rule.save || mode !== 'nominal' || !form.account_id) return;

    // Save the rule, then optionally sweep up everything else it catches.
    const supabase = createClient();
    const { data: ruleId, error: ruleError } = await supabase.rpc('create_match_rule', {
      p_config: {
        organisation_id: orgId,
        bank_account_id: rule.scope === 'this' ? bankAccountId : null,
        name: rule.pattern.trim(),
        pattern: rule.pattern.trim(),
        match_type: 'contains',
        direction: isIn ? 'in' : 'out',
        account_id: form.account_id,
        vat_code_id: form.vat_code_id || null,
        contact_id: form.contact_id || null,
      },
    });

    if (ruleError) {
      setError(readableError(ruleError));
      return;
    }

    // Deliberately no bulk apply. The rule now suggests itself on every
    // matching line, and each one is still accepted individually — every
    // transaction gets looked at before it reaches the ledger.
    router.refresh();
  }

  const grouped = useMemo(() => {
    const g = new Map();
    for (const a of accounts) {
      const key = a.account_type?.report_group || 'Other';
      if (!g.has(key)) g.set(key, []);
      g.get(key).push(a);
    }
    return [...g.entries()];
  }, [accounts]);

  const ready =
    mode === 'transfer'
      ? Boolean(form.to_bank_account_id)
      : mode === 'settle'
      ? Boolean(form.contact_id) && !overAllocated
      : Boolean(form.account_id);

  const showSuggestion = best && !manual;

  return (
    <div className="recon">
      {/* ---------------- Left: what the bank says ---------------- */}
      <div className="recon-bank">
        <div className="recon-date">{shortDate(line.date)}</div>
        <div className="recon-desc">{line.description}</div>
        {line.reference && <div className="code small muted">{line.reference}</div>}
        <div className={`recon-amount ${isIn ? 'num-positive' : ''}`}>
          {isIn ? '+' : '−'}{money(gross)}
        </div>
        {line.balance != null && (
          <div className="hint">Balance {money(line.balance)}</div>
        )}
      </div>

      {/* ---------------- Right: what we will do ------------------ */}
      <div className="recon-treatment">
        {error && <div className="notice notice-error">{error}</div>}

        {showSuggestion ? (
          <>
            <div className="recon-suggestion">
              <div style={{ flex: 1, minWidth: 0 }}>
                <span className={`pill ${best.score >= 0.9 ? 'pill-accent' : 'pill-caution'}`}>
                  {suggestionLabel(best.kind, isIn)}
                </span>
                <div className="recon-suggestion-label">{best.label}</div>
                <div className="hint">
                  {best.detail}
                  {best.ref_date && ` · ${shortDate(best.ref_date)}`}
                </div>
              </div>
              <button className="btn btn-primary" onClick={() => accept(best)} disabled={busy}>
                {busy ? '…' : best.kind === 'journal_line' ? 'That’s it' : 'Accept'}
              </button>
            </div>

            <div className="row" style={{ gap: '0.5rem', marginTop: '0.625rem', flexWrap: 'wrap' }}>
              {alternatives.length > 0 && (
                <button
                  className="btn btn-secondary btn-sm"
                  onClick={() => setShowAlternatives(!showAlternatives)}
                >
                  {showAlternatives ? 'Hide' : `${alternatives.length} other`}
                </button>
              )}
              <button className="btn btn-secondary btn-sm" onClick={() => setManual(true)}>
                Something else
              </button>
              <div className="spacer" />
              <button
                className="btn btn-ghost btn-sm"
                disabled={busy}
                onClick={() =>
                  run((sb) =>
                    sb.rpc('exclude_statement_line', {
                      p_line_id: line.id,
                      p_reason: 'Not a business transaction',
                    })
                  )
                }
              >
                Ignore
              </button>
            </div>

            {showAlternatives &&
              alternatives.map((s, i) => (
                <div className="recon-alt" key={`${s.kind}-${s.ref_id}-${i}`}>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <span className="pill">{shortKindLabel(s.kind, isIn)}</span>{' '}
                    <strong className="small">{s.label}</strong>
                    <div className="hint">{s.detail}</div>
                  </div>
                  <button className="btn btn-secondary btn-sm" onClick={() => accept(s)} disabled={busy}>
                    Use
                  </button>
                </div>
              ))}
          </>
        ) : (
          <>
            <div className="row" style={{ gap: '0.375rem', marginBottom: '0.75rem', flexWrap: 'wrap' }}>
              {MODES.map(([m, label]) => (
                <button
                  key={m}
                  className={`btn btn-sm ${mode === m ? 'btn-primary' : 'btn-secondary'}`}
                  onClick={() => setMode(m)}
                >
                  {label}
                </button>
              ))}
              {best && (
                <button className="btn btn-ghost btn-sm" onClick={() => setManual(false)}>
                  Back to the suggestion
                </button>
              )}
            </div>

            {mode === 'nominal' && (
              <>
                <div className="recon-fields">
                  <label className="field" style={{ marginBottom: 0 }}>
                    <span className="label">{pro ? 'Account' : 'Category'}</span>
                    <select
                      className="select"
                      value={form.account_id}
                      onChange={(e) => set({ account_id: e.target.value })}
                    >
                      <option value="">Choose…</option>
                      {grouped.map(([group, items]) => (
                        <optgroup key={group} label={group}>
                          {items.map((a) => (
                            <option key={a.id} value={a.id}>
                              {pro ? `${a.code} — ${a.name}` : a.friendly_name || a.name}
                            </option>
                          ))}
                        </optgroup>
                      ))}
                    </select>
                  </label>

                  {vatEnabled && (
                    <label className="field" style={{ marginBottom: 0 }}>
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
                    </label>
                  )}
                </div>

                {vatEnabled && form.vat_code_id && (
                  <p className="hint" style={{ marginTop: '0.5rem' }}>
                    VAT comes out of the {money(gross)}, not on top of it.
                  </p>
                )}

                {/* ---- Turn this treatment into a rule ---- */}
                <div className="recon-rule">
                  <label className="row" style={{ gap: '0.5rem', cursor: 'pointer' }}>
                    <input
                      type="checkbox"
                      checked={rule.save}
                      onChange={(e) => {
                        const on = e.target.checked;
                        setRule((r) => ({
                          ...r,
                          save: on,
                          pattern: r.pattern || line.suggested_pattern || '',
                        }));
                        if (on) checkReach(rule.pattern || line.suggested_pattern || '');
                      }}
                      disabled={!form.account_id}
                    />
                    <span className="small" style={{ fontWeight: 600 }}>
                      Do this automatically next time
                    </span>
                  </label>

                  {rule.save && (
                    <div style={{ marginTop: '0.625rem' }}>
                      <div className="recon-fields">
                        <label className="field" style={{ marginBottom: 0 }}>
                          <span className="label">When the description contains</span>
                          <input
                            className="input"
                            value={rule.pattern}
                            onChange={(e) => {
                              setRule((r) => ({ ...r, pattern: e.target.value }));
                              checkReach(e.target.value);
                            }}
                          />
                        </label>

                        <label className="field" style={{ marginBottom: 0 }}>
                          <span className="label">Applies to</span>
                          <select
                            className="select"
                            value={rule.scope}
                            onChange={(e) => {
                              setRule((r) => ({ ...r, scope: e.target.value }));
                              checkReach(rule.pattern);
                            }}
                          >
                            <option value="this">This account only</option>
                            <option value="all">Every bank account</option>
                          </select>
                        </label>
                      </div>

                      {rule.reach != null && (
                        <p className="hint" style={{ marginTop: '0.5rem', marginBottom: 0 }}>
                          {rule.reach > 0 ? (
                            <>
                              This will be suggested on <strong>{rule.reach}</strong> other
                              line{rule.reach === 1 ? '' : 's'} waiting here, and on future
                              statements. Nothing is posted until you accept it.
                            </>
                          ) : (
                            <>
                              Nothing else here matches yet. It will be suggested on
                              future statements.
                            </>
                          )}
                        </p>
                      )}
                    </div>
                  )}
                </div>
              </>
            )}

            {mode === 'settle' && (
              <>
                <label className="field" style={{ marginBottom: form.contact_id ? '0.875rem' : 0 }}>
                  <span className="label">
                    {isIn ? 'Which customer paid?' : 'Which supplier?'}
                  </span>
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
                </label>

                {form.contact_id && loadingItems && (
                  <p className="hint">Looking up what is outstanding…</p>
                )}

                {form.contact_id && !loadingItems && items.length === 0 && (
                  <div className="notice notice-caution" style={{ marginBottom: 0 }}>
                    Nothing outstanding for them. The whole {money(gross)} will sit
                    on account until there is something to match it against.
                  </div>
                )}

                {form.contact_id && !loadingItems && items.length > 0 && (
                  <>
                    <span className="label">
                      {isIn ? 'What is this paying?' : 'Which invoices does this pay?'}
                    </span>

                    <table className="alloc-table">
                      <thead>
                        <tr>
                          <th>Reference</th>
                          <th style={{ width: '6.5rem' }}>Due</th>
                          <th className="num" style={{ width: '6.5rem' }}>Outstanding</th>
                          <th className="num" style={{ width: '7rem' }}>Put against</th>
                          <th style={{ width: '3rem' }} />
                        </tr>
                      </thead>
                      <tbody>
                        {items.map((item) => {
                          const remaining =
                            Math.round((gross - allocated + (Number(alloc[item.id]) || 0)) * 100) / 100;
                          const fill = Math.min(remaining, Number(item.outstanding_amount));

                          return (
                            <tr key={item.id}>
                              <td>
                                <span className="code small">
                                  {item.reference || item.item_type}
                                </span>
                                <div className="hint">{shortDate(item.date)}</div>
                              </td>
                              <td className="small nowrap">
                                {item.due_date ? shortDate(item.due_date) : ''}
                                {item.days_overdue > 0 && (
                                  <> <span className="pill pill-negative">{item.days_overdue}d</span></>
                                )}
                              </td>
                              <td className="num">
                                <span className="num">{money(item.outstanding_amount)}</span>
                              </td>
                              <td>
                                <input
                                  className="input num"
                                  inputMode="decimal"
                                  style={{ padding: '0.3125rem 0.5rem' }}
                                  value={alloc[item.id] || ''}
                                  placeholder="0.00"
                                  onChange={(e) =>
                                    setAlloc((a) => ({ ...a, [item.id]: e.target.value }))
                                  }
                                />
                              </td>
                              <td>
                                <button
                                  className="btn btn-ghost btn-sm"
                                  disabled={fill <= 0}
                                  title="Put as much of this payment against it as will fit"
                                  onClick={() =>
                                    setAlloc((a) => ({ ...a, [item.id]: fill.toFixed(2) }))
                                  }
                                >
                                  Fill
                                </button>
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>

                    <div
                      className={`notice ${
                        overAllocated
                          ? 'notice-error'
                          : onAccount > 0
                          ? 'notice-caution'
                          : 'notice-info'
                      }`}
                      style={{ marginTop: '0.75rem', marginBottom: 0 }}
                    >
                      {overAllocated ? (
                        <>
                          You have put {money(allocated)} against invoices but the
                          payment is only {money(gross)}. Reduce one of them.
                        </>
                      ) : onAccount > 0 ? (
                        <>
                          {money(allocated)} allocated. The remaining{' '}
                          <strong>{money(onAccount)}</strong> will sit on account
                          and can be matched later.
                        </>
                      ) : (
                        <>The whole {money(gross)} is allocated.</>
                      )}
                    </div>
                  </>
                )}
              </>
            )}

            {mode === 'transfer' && (
              <label className="field" style={{ marginBottom: 0 }}>
                <span className="label">
                  {isIn ? 'Came from which account?' : 'Went to which account?'}
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

            <div className="btn-row" style={{ marginTop: '0.875rem' }}>
              <button
                className="btn btn-ghost btn-sm"
                disabled={busy}
                onClick={() =>
                  run((sb) =>
                    sb.rpc('exclude_statement_line', {
                      p_line_id: line.id,
                      p_reason: 'Not a business transaction',
                    })
                  )
                }
              >
                Ignore
              </button>
              <div className="spacer" />
              <button className="btn btn-primary" onClick={record} disabled={!ready || busy}>
                {busy ? 'Recording…' : 'Record it'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

export default function ReconcileSplit({
  lines, suggestionsByLine, orgId, bankAccountId,
  accounts, vatCodes, contacts, bankAccounts, pro, vatEnabled,
}) {
  if (lines.length === 0) {
    return (
      <div className="card">
        <div className="empty">
          <h3>Everything is dealt with</h3>
          <p>
            Every imported line has been matched or ignored. Import the next
            statement when you have it.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="stack" style={{ gap: '0.75rem' }}>
      <div className="recon-heading">
        <span>From your bank</span>
        <span>How it will be treated</span>
      </div>

      {lines.map((line) => (
        <Line
          key={line.id}
          line={line}
          suggestions={suggestionsByLine[line.id] || []}
          orgId={orgId}
          bankAccountId={bankAccountId}
          accounts={accounts}
          vatCodes={vatCodes}
          contacts={contacts}
          bankAccounts={bankAccounts}
          pro={pro}
          vatEnabled={vatEnabled}
        />
      ))}
    </div>
  );
}

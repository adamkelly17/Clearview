'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError, shortDate, today } from '@/lib/format';
import BalanceBeam from '@/components/BalanceBeam';

const blankLine = () => ({
  key: Math.random().toString(36).slice(2),
  account_id: '',
  description: '',
  debit: '',
  credit: '',
});

export default function EntryForm({ orgId, accounts, pro, currencyCode, window: periodWindow }) {
  const router = useRouter();

  const [date, setDate] = useState(today());
  const [description, setDescription] = useState('');
  const [reference, setReference] = useState('');
  const [lines, setLines] = useState([blankLine(), blankLine()]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [done, setDone] = useState(null);

  /* Accounts grouped by their report section so the picker reads like
     a chart of accounts rather than an alphabetical soup. */
  const grouped = useMemo(() => {
    const groups = new Map();
    for (const a of accounts) {
      const g = a.account_type?.report_group || 'Other';
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(a);
    }
    return [...groups.entries()];
  }, [accounts]);

  const totals = useMemo(() => {
    let debit = 0;
    let credit = 0;
    for (const l of lines) {
      debit += Number(l.debit) || 0;
      credit += Number(l.credit) || 0;
    }
    return { debit: Math.round(debit * 100) / 100, credit: Math.round(credit * 100) / 100 };
  }, [lines]);

  const balanced = totals.debit > 0 && Math.abs(totals.debit - totals.credit) < 0.005;
  const filled = lines.filter((l) => l.account_id && (Number(l.debit) || Number(l.credit)));
  const ready = balanced && filled.length >= 2 && description.trim().length > 0;

  function update(key, patch) {
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  /* Typing in one column clears the other: a line is one side or the
     other, never both. Enforcing it here means the user never sees the
     database complain about it. */
  function setAmount(key, side, value) {
    update(key, side === 'debit' ? { debit: value, credit: '' } : { credit: value, debit: '' });
  }

  function addLine() {
    setLines((ls) => [...ls, blankLine()]);
  }

  function removeLine(key) {
    setLines((ls) => (ls.length <= 2 ? ls : ls.filter((l) => l.key !== key)));
  }

  /** Fills the empty side of the last blank amount so it balances. */
  function balanceRemainder() {
    const diff = Math.round((totals.debit - totals.credit) * 100) / 100;
    if (diff === 0) return;

    const target = lines.find((l) => !l.debit && !l.credit) || lines[lines.length - 1];
    if (diff > 0) update(target.key, { credit: diff.toFixed(2), debit: '' });
    else update(target.key, { debit: Math.abs(diff).toFixed(2), credit: '' });
  }

  async function post() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const payload = filled.map((l) => ({
      account_id: l.account_id,
      description: l.description || null,
      debit: Number(l.debit) || 0,
      credit: Number(l.credit) || 0,
    }));

    const { data, error } = await supabase.rpc('post_journal', {
      p_organisation_id: orgId,
      p_date: date,
      p_description: description.trim(),
      p_lines: payload,
      p_reference: reference.trim() || null,
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    setDone(data);
    setLines([blankLine(), blankLine()]);
    setDescription('');
    setReference('');
    router.refresh();
  }

  const outsideWindow =
    periodWindow && (date < periodWindow.from || date > periodWindow.to);

  return (
    <>
      {error && <div className="notice notice-error">{error}</div>}

      {done && (
        <div className="notice notice-info">
          Transaction recorded.{' '}
          <a href="/journals">See it in the list</a> or enter another below.
        </div>
      )}

      {outsideWindow && (
        <div className="notice notice-caution">
          {periodWindow
            ? `That date is outside your open periods (${shortDate(periodWindow.from)} to ${shortDate(periodWindow.to)}). Choose another date or reopen the period in Settings.`
            : 'There are no open periods to post into.'}
        </div>
      )}

      <div className="card">
        <div className="card-body">
          <div className="grid grid-3">
            <label className="field">
              <span className="label">Date</span>
              <input
                className="input"
                type="date"
                value={date}
                onChange={(e) => setDate(e.target.value)}
              />
            </label>

            <label className="field" style={{ gridColumn: 'span 2' }}>
              <span className="label">What is this for?</span>
              <input
                className="input"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="Rent for May"
              />
            </label>
          </div>

          <label className="field" style={{ maxWidth: '18rem', marginBottom: 0 }}>
            <span className="label">
              Reference <span className="muted">(optional)</span>
            </span>
            <input
              className="input"
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="DD-0501"
            />
          </label>
        </div>
      </div>

      <div className="card mt-md">
        <div className="card-head">
          <h2>{pro ? 'Journal lines' : 'The two sides'}</h2>
          <button className="btn btn-secondary btn-sm" onClick={addLine}>
            Add a line
          </button>
        </div>

        <div className="card-body">
          <table className="entry-grid">
            <thead>
              <tr>
                <th style={{ width: '34%' }}>{pro ? 'Account' : 'Category'}</th>
                <th>Details</th>
                <th className="num" style={{ width: '7.5rem' }}>
                  {pro ? 'Debit' : 'Out'}
                </th>
                <th className="num" style={{ width: '7.5rem' }}>
                  {pro ? 'Credit' : 'In'}
                </th>
                <th style={{ width: '2rem' }} />
              </tr>
            </thead>
            <tbody>
              {lines.map((line) => (
                <tr key={line.key}>
                  <td>
                    <select
                      className="select"
                      value={line.account_id}
                      onChange={(e) => update(line.key, { account_id: e.target.value })}
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
                  </td>
                  <td>
                    <input
                      className="input"
                      value={line.description}
                      onChange={(e) => update(line.key, { description: e.target.value })}
                      placeholder="Optional"
                    />
                  </td>
                  <td>
                    <input
                      className="input num"
                      inputMode="decimal"
                      value={line.debit}
                      onChange={(e) => setAmount(line.key, 'debit', e.target.value)}
                      placeholder="0.00"
                    />
                  </td>
                  <td>
                    <input
                      className="input num"
                      inputMode="decimal"
                      value={line.credit}
                      onChange={(e) => setAmount(line.key, 'credit', e.target.value)}
                      placeholder="0.00"
                    />
                  </td>
                  <td>
                    <button
                      className="entry-remove"
                      onClick={() => removeLine(line.key)}
                      disabled={lines.length <= 2}
                      aria-label="Remove this line"
                      title="Remove this line"
                    >
                      ×
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="mt-md">
        <BalanceBeam
          debit={totals.debit}
          credit={totals.credit}
          pro={pro}
          currencyCode={currencyCode}
        />
      </div>

      <div className="btn-row mt-md">
        <button
          className="btn btn-secondary"
          onClick={balanceRemainder}
          disabled={balanced || (totals.debit === 0 && totals.credit === 0)}
        >
          Even it up
        </button>
        <div className="spacer" />
        <button
          className="btn btn-primary"
          onClick={post}
          disabled={!ready || busy || outsideWindow}
        >
          {busy ? 'Recording…' : 'Record it'}
        </button>
      </div>

      {!ready && !balanced && (
        <p className="hint mt-md">
          {pro
            ? 'A journal can only be posted once debits equal credits.'
            : 'The two sides need to match before this can be recorded. "Even it up" will fill in the difference for you.'}
        </p>
      )}
    </>
  );
}

'use client';

import { useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readStatementFile, buildImportRows } from '@/lib/statement';
import { money, readableError, shortDate } from '@/lib/format';

/**
 * Importing a statement, in four visible steps.
 *
 * The mapping step exists because there is no standard for UK bank
 * statement CSVs — every bank differs on column names, on whether amounts
 * are one signed column or two, and on date order. The layout is guessed
 * and the guess is shown, but it is never applied silently: being wrong
 * about which column is the amount, or reading 04/03 as 3 April, is not a
 * recoverable error once it is in the ledger.
 *
 * The preview is the safeguard. You see actual dates and actual signed
 * amounts before anything is written.
 */
export default function ImportForm({ orgId, bankAccount, savedMapping }) {
  const router = useRouter();
  const inputRef = useRef(null);

  const [step, setStep] = useState('choose');
  const [fileName, setFileName] = useState('');
  const [headers, setHeaders] = useState([]);
  const [records, setRecords] = useState([]);
  const [mapping, setMapping] = useState(null);
  const [dragging, setDragging] = useState(false);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);

  async function handleFile(file) {
    setError(null);
    setBusy(true);

    try {
      const parsed = await readStatementFile(file);
      setFileName(file.name);
      setHeaders(parsed.headers);
      setRecords(parsed.records);

      // Reuse the layout from last time if the headers still line up.
      const saved = savedMapping;
      const savedFits =
        saved &&
        [saved.date, saved.description, saved.amount, saved.moneyIn, saved.moneyOut]
          .filter(Boolean)
          .every((c) => parsed.headers.includes(c));

      setMapping(savedFits ? { ...parsed.mapping, ...saved } : parsed.mapping);
      setStep('map');
    } catch (e) {
      setError(readableError(e));
    } finally {
      setBusy(false);
    }
  }

  const built = useMemo(
    () => (mapping && records.length ? buildImportRows(records, mapping) : { rows: [], problems: [] }),
    [records, mapping]
  );

  const totals = useMemo(() => {
    const inSum = built.rows.filter((r) => r.amount > 0).reduce((s, r) => s + r.amount, 0);
    const outSum = built.rows.filter((r) => r.amount < 0).reduce((s, r) => s + r.amount, 0);
    return {
      in: Math.round(inSum * 100) / 100,
      out: Math.round(outSum * 100) / 100,
      net: Math.round((inSum + outSum) * 100) / 100,
    };
  }, [built.rows]);

  const dates = useMemo(() => {
    if (!built.rows.length) return null;
    const sorted = [...built.rows].map((r) => r.date).sort();
    return { from: sorted[0], to: sorted[sorted.length - 1] };
  }, [built.rows]);

  /* The closing balance from the last row, if the file carried one. Lets
     the reconciliation compare against what the bank says. */
  const closingBalance = useMemo(() => {
    if (!mapping?.balance || !built.rows.length) return null;
    const withBalance = built.rows.filter((r) => r.balance != null);
    if (!withBalance.length) return null;
    return withBalance.sort((a, b) => (a.date < b.date ? -1 : 1))[withBalance.length - 1].balance;
  }, [built.rows, mapping]);

  const mappingReady =
    mapping?.date &&
    (mapping.amountMode === 'single' ? mapping.amount : mapping.moneyIn || mapping.moneyOut);

  async function doImport() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { data, error } = await supabase.rpc('import_statement', {
      p_config: {
        organisation_id: orgId,
        bank_account_id: bankAccount.id,
        source_filename: fileName,
        closing_balance: closingBalance,
        mapping,
        lines: built.rows,
      },
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    setResult(data);
    setStep('done');
    router.refresh();
  }

  const set = (patch) => setMapping((m) => ({ ...m, ...patch }));

  const ColumnPicker = ({ label, field, hint }) => (
    <label className="field">
      <span className="label">{label}</span>
      <select
        className="select"
        value={mapping?.[field] || ''}
        onChange={(e) => set({ [field]: e.target.value || null })}
      >
        <option value="">Not in this file</option>
        {headers.map((h) => (
          <option key={h} value={h}>{h}</option>
        ))}
      </select>
      {hint && <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>{hint}</span>}
    </label>
  );

  /* ---------------- Step 1: choose a file ---------------- */
  if (step === 'choose') {
    return (
      <>
        {error && <div className="notice notice-error">{error}</div>}

        <div
          className={`dropzone ${dragging ? 'dropzone-active' : ''}`}
          onClick={() => inputRef.current?.click()}
          onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
          onDragLeave={() => setDragging(false)}
          onDrop={(e) => {
            e.preventDefault();
            setDragging(false);
            if (e.dataTransfer.files[0]) handleFile(e.dataTransfer.files[0]);
          }}
        >
          <h3>{busy ? 'Reading the file…' : 'Drop a statement here'}</h3>
          <p className="hint">
            CSV or Excel, downloaded from your bank. Any layout — you get to
            confirm which column is which.
          </p>
          <input
            ref={inputRef}
            type="file"
            accept=".csv,.xlsx,.xls,.txt"
            style={{ display: 'none' }}
            onChange={(e) => {
              if (e.target.files[0]) handleFile(e.target.files[0]);
              e.target.value = '';
            }}
          />
        </div>

        <p className="hint mt-lg">
          Re-importing an overlapping date range is safe. Rows already present
          are recognised and skipped rather than duplicated.
        </p>
      </>
    );
  }

  /* ---------------- Step 2: map the columns ---------------- */
  if (step === 'map') {
    return (
      <>
        {error && <div className="notice notice-error">{error}</div>}

        <div className="notice notice-info">
          Read <strong>{records.length}</strong> rows from{' '}
          <strong>{fileName}</strong>. Check the columns below — the guess is
          usually right but not always.
        </div>

        <div className="card">
          <div className="card-head"><h2>Which column is which?</h2></div>
          <div className="card-body">
            <div className="grid grid-2">
              <ColumnPicker label="Date" field="date" />

              <label className="field">
                <span className="label">Date order</span>
                <select
                  className="select"
                  value={mapping.dateFormat}
                  onChange={(e) => set({ dateFormat: e.target.value })}
                >
                  <option value="dmy">Day first — 04/03/2026 is 4 March</option>
                  <option value="mdy">Month first — 04/03/2026 is 3 April</option>
                </select>
                <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                  Check this against the preview. Getting it wrong shifts
                  transactions between months without any error.
                </span>
              </label>
            </div>

            <ColumnPicker label="Description" field="description" />

            <label className="field">
              <span className="label">How are amounts laid out?</span>
              <select
                className="select"
                style={{ maxWidth: '24rem' }}
                value={mapping.amountMode}
                onChange={(e) => set({ amountMode: e.target.value })}
              >
                <option value="single">One column, negative for money out</option>
                <option value="split">Two columns, money in and money out</option>
              </select>
            </label>

            {mapping.amountMode === 'single' ? (
              <ColumnPicker label="Amount" field="amount" />
            ) : (
              <div className="grid grid-2">
                <ColumnPicker label="Money in" field="moneyIn" />
                <ColumnPicker label="Money out" field="moneyOut" />
              </div>
            )}

            <ColumnPicker
              label="Running balance"
              field="balance"
              hint="Optional. If present, the closing figure is used to check the reconciliation."
            />
          </div>
        </div>

        <div className="btn-row mt-lg">
          <button className="btn btn-secondary" onClick={() => setStep('choose')}>Back</button>
          <div className="spacer" />
          <button
            className="btn btn-primary"
            onClick={() => setStep('preview')}
            disabled={!mappingReady}
          >
            Preview
          </button>
        </div>

        {!mappingReady && (
          <p className="hint mt-md">
            A date column and at least one amount column are needed.
          </p>
        )}
      </>
    );
  }

  /* ---------------- Step 3: preview ---------------- */
  if (step === 'preview') {
    return (
      <>
        {error && <div className="notice notice-error">{error}</div>}

        <div className="grid grid-4">
          <div className="card"><div className="card-body">
            <div className="eyebrow">Rows</div>
            <div className="num" style={{ fontSize: '1.25rem', fontWeight: 600, textAlign: 'left', marginTop: '0.25rem' }}>
              {built.rows.length}
            </div>
          </div></div>
          <div className="card"><div className="card-body">
            <div className="eyebrow">Money in</div>
            <div className="num num-positive" style={{ fontSize: '1.25rem', fontWeight: 600, textAlign: 'left', marginTop: '0.25rem' }}>
              {money(totals.in)}
            </div>
          </div></div>
          <div className="card"><div className="card-body">
            <div className="eyebrow">Money out</div>
            <div className="num num-negative" style={{ fontSize: '1.25rem', fontWeight: 600, textAlign: 'left', marginTop: '0.25rem' }}>
              {money(Math.abs(totals.out))}
            </div>
          </div></div>
          <div className="card"><div className="card-body">
            <div className="eyebrow">Dates</div>
            <div className="small" style={{ marginTop: '0.4375rem', fontWeight: 600 }}>
              {dates ? `${shortDate(dates.from)} to ${shortDate(dates.to)}` : '—'}
            </div>
          </div></div>
        </div>

        {built.problems.length > 0 && (
          <div className="notice notice-caution mt-md">
            <strong>{built.problems.length} row{built.problems.length === 1 ? '' : 's'} will be skipped.</strong>{' '}
            {built.problems.slice(0, 3).map((p) => `Row ${p.row}: ${p.reason}.`).join(' ')}
            {built.problems.length > 3 && ' …'}
            {' '}If that looks wrong, go back and check the column mapping.
          </div>
        )}

        <div className="card mt-md">
          <div className="card-head">
            <h2>First 15 rows as they will be imported</h2>
            <span className="hint">Check the dates read the way you expect</span>
          </div>
          <table className="table table-flush">
            <thead>
              <tr>
                <th style={{ width: '7rem' }}>Date</th>
                <th>Description</th>
                <th className="num" style={{ width: '8rem' }}>Amount</th>
                {mapping.balance && <th className="num" style={{ width: '8rem' }}>Balance</th>}
              </tr>
            </thead>
            <tbody>
              {built.rows.slice(0, 15).map((r, i) => (
                <tr key={i}>
                  <td className="nowrap">{shortDate(r.date)}</td>
                  <td className="small">{r.description}</td>
                  <td>
                    <span className={`num ${r.amount > 0 ? 'num-positive' : 'num-negative'}`}>
                      {money(r.amount)}
                    </span>
                  </td>
                  {mapping.balance && (
                    <td><span className="num">{r.balance == null ? '' : money(r.balance)}</span></td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="btn-row mt-md">
          <button className="btn btn-secondary" onClick={() => setStep('map')} disabled={busy}>
            Change the mapping
          </button>
          <div className="spacer" />
          <button
            className="btn btn-primary"
            onClick={doImport}
            disabled={busy || built.rows.length === 0}
          >
            {busy ? 'Importing…' : `Import ${built.rows.length} rows`}
          </button>
        </div>
      </>
    );
  }

  /* ---------------- Step 4: done ---------------- */
  return (
    <div className="card">
      <div className="empty">
        <h3>
          {result?.inserted > 0
            ? `${result.inserted} line${result.inserted === 1 ? '' : 's'} imported`
            : 'Nothing new to import'}
        </h3>
        <p>
          {result?.duplicates > 0 && (
            <>
              {result.duplicates} row{result.duplicates === 1 ? ' was' : 's were'} already
              here and {result.duplicates === 1 ? 'was' : 'were'} skipped.{' '}
            </>
          )}
          {result?.inserted > 0
            ? 'Next, match them against what is already recorded.'
            : 'This statement had already been imported.'}
        </p>
        <div className="btn-row mt-md" style={{ justifyContent: 'center' }}>
          <button className="btn btn-secondary" onClick={() => { setStep('choose'); setResult(null); }}>
            Import another
          </button>
          <a href={`/banking/${bankAccount.id}`} className="btn btn-primary">
            Match them up
          </a>
        </div>
      </div>
    </div>
  );
}

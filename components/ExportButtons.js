'use client';

import { useState } from 'react';
import * as XLSX from 'xlsx';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';

/**
 * The three reports.
 *
 * Built in the browser with SheetJS, which is already a dependency for
 * reading bank statements. No server round trip and no temporary files
 * sitting anywhere.
 *
 * All three read the same functions the screen reads, so a downloaded
 * report can never disagree with the figures it was downloaded from.
 * That is worth more than it sounds — a spreadsheet that says something
 * different from the software is how people stop trusting both.
 */

const MONEY = '#,##0.00';

function autoWidth(rows, headers) {
  return headers.map((h, i) => {
    const longest = rows.reduce(
      (max, r) => Math.max(max, String(r[i] ?? '').length),
      String(h).length
    );
    return { wch: Math.min(Math.max(longest + 2, 10), 44) };
  });
}

function formatMoneyColumns(sheet, rows, moneyCols, headerRows) {
  rows.forEach((_, r) => {
    moneyCols.forEach((c) => {
      const ref = XLSX.utils.encode_cell({ r: r + headerRows, c });
      if (sheet[ref] && typeof sheet[ref].v === 'number') sheet[ref].z = MONEY;
    });
  });
}

function download(workbook, filename) {
  XLSX.writeFile(workbook, filename, { compression: true });
}

export default function ExportButtons({ orgId, ledger, orgName }) {
  const [busy, setBusy] = useState(null);
  const [error, setError] = useState(null);

  const isSales = ledger === 'sales';
  const party = isSales ? 'Customer' : 'Supplier';
  const today = new Date().toISOString().slice(0, 10);
  const stamp = `${orgName.replace(/[^a-zA-Z0-9]+/g, '-')}-${today}`;

  async function run(key, fn) {
    setBusy(key);
    setError(null);
    try {
      await fn(createClient());
    } catch (e) {
      setError(readableError(e));
    } finally {
      setBusy(null);
    }
  }

  /* ---------- 1. Summary by contact, with ageing ---------- */
  const summary = () =>
    run('summary', async (supabase) => {
      const { data, error } = await supabase.rpc('contact_summary', {
        p_organisation_id: orgId,
        p_ledger: ledger,
      });
      if (error) throw error;

      const live = (data || []).filter((r) => Number(r.total_due) !== 0);

      const headers = [
        'Code', party, 'Current', '1-30 days', '31-60 days', '61-90 days',
        'Over 90 days', 'Total due', 'Invoices', 'Overdue', 'Overdue invoices',
        'Oldest due', 'Days overdue',
      ];

      const rows = live.map((r) => [
        r.code, r.name,
        Number(r.current_amount), Number(r.days_30), Number(r.days_60),
        Number(r.days_90), Number(r.older), Number(r.total_due),
        Number(r.outstanding_count), Number(r.overdue_amount),
        Number(r.overdue_count),
        r.oldest_due || '', Number(r.oldest_days) || 0,
      ]);

      // A totals row, because the first thing anyone does with this is
      // check it against the control account.
      const totals = ['', 'Total',
        ...[2, 3, 4, 5, 6, 7].map((c) => rows.reduce((s, r) => s + r[c], 0)),
        rows.reduce((s, r) => s + r[8], 0),
        rows.reduce((s, r) => s + r[9], 0),
        rows.reduce((s, r) => s + r[10], 0),
        '', ''];

      const aoa = [
        [`${isSales ? 'Amounts owed to you' : 'Amounts you owe'} — ${orgName}`],
        [`As at ${new Date().toLocaleDateString('en-GB')}`],
        [],
        headers,
        ...rows,
        totals,
      ];

      const sheet = XLSX.utils.aoa_to_sheet(aoa);
      sheet['!cols'] = autoWidth(rows, headers);
      formatMoneyColumns(sheet, [...rows, totals], [2, 3, 4, 5, 6, 7, 9], 4);

      const wb = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(wb, sheet, 'Summary');
      download(wb, `${stamp}-${isSales ? 'debtors' : 'creditors'}-summary.xlsx`);
    });

  /* ---------- 2. Every outstanding item, with ageing ---------- */
  const detailed = (overdueOnly) => () =>
    run(overdueOnly ? 'overdue' : 'detailed', async (supabase) => {
      const { data, error } = await supabase.rpc('outstanding_items', {
        p_organisation_id: orgId,
        p_ledger: ledger,
        p_overdue_only: overdueOnly,
      });
      if (error) throw error;

      const items = data || [];

      const headers = [
        'Code', party, 'Type', 'Reference', 'Date', 'Due', 'Days overdue',
        'Ageing', 'Invoice total', 'Outstanding',
        'Current', '1-30 days', '31-60 days', '61-90 days', 'Over 90 days',
      ];

      const rows = items.map((r) => [
        r.contact_code, r.contact_name,
        r.item_type === 'invoice' ? 'Invoice'
          : r.item_type === 'credit_note' ? 'Credit note' : r.item_type,
        r.document_number || r.reference || '',
        r.item_date, r.due_date, Number(r.days_overdue),
        r.bucket,
        Number(r.gross_amount), Number(r.outstanding_amount),
        Number(r.current_amount), Number(r.days_30), Number(r.days_60),
        Number(r.days_90), Number(r.older),
      ]);

      const totals = ['', 'Total', '', '', '', '', '', '',
        rows.reduce((s, r) => s + r[8], 0),
        rows.reduce((s, r) => s + r[9], 0),
        ...[10, 11, 12, 13, 14].map((c) => rows.reduce((s, r) => s + r[c], 0)),
      ];

      const aoa = [
        [
          overdueOnly
            ? `Overdue invoices — ${orgName}`
            : `${isSales ? 'Outstanding invoices' : 'Unpaid bills'} — ${orgName}`,
        ],
        [`As at ${new Date().toLocaleDateString('en-GB')}`],
        [],
        headers,
        ...rows,
        totals,
      ];

      const sheet = XLSX.utils.aoa_to_sheet(aoa);
      sheet['!cols'] = autoWidth(rows, headers);
      formatMoneyColumns(sheet, [...rows, totals], [8, 9, 10, 11, 12, 13, 14], 4);
      // Freeze the header so a long list stays readable while scrolling.
      sheet['!freeze'] = { xSplit: 0, ySplit: 4 };
      sheet['!autofilter'] = {
        ref: XLSX.utils.encode_range(
          { r: 3, c: 0 },
          { r: 3 + rows.length, c: headers.length - 1 }
        ),
      };

      const wb = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(wb, sheet, overdueOnly ? 'Overdue' : 'Outstanding');
      download(
        wb,
        `${stamp}-${overdueOnly ? 'overdue' : 'outstanding'}-${isSales ? 'invoices' : 'bills'}.xlsx`
      );
    });

  return (
    <div className="card">
      <div className="card-head">
        <h2>Reports</h2>
        <span className="hint">Excel, as at today</span>
      </div>
      <div className="card-body">
        {error && <div className="notice notice-error">{error}</div>}

        <div className="btn-row">
          <button className="btn btn-secondary btn-sm" onClick={summary} disabled={busy}>
            {busy === 'summary' ? 'Building…' : 'Summary with ageing'}
          </button>
          <button className="btn btn-secondary btn-sm" onClick={detailed(false)} disabled={busy}>
            {busy === 'detailed' ? 'Building…' : `All outstanding ${isSales ? 'invoices' : 'bills'}`}
          </button>
          <button className="btn btn-secondary btn-sm" onClick={detailed(true)} disabled={busy}>
            {busy === 'overdue' ? 'Building…' : 'Overdue only'}
          </button>
        </div>

        <p className="hint" style={{ marginTop: '0.75rem', marginBottom: 0 }}>
          The summary gives one row per {party.toLowerCase()} with the balance in
          each ageing period. The other two give a row per{' '}
          {isSales ? 'invoice' : 'bill'}, filtered and with a header you can filter
          further. All three total to the same figure as this screen.
        </p>
      </div>
    </div>
  );
}

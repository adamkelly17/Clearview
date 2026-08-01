import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { shortDate } from '@/lib/format';
import Money from '@/components/Money';
import ReverseButton from '@/components/ReverseButton';

export const dynamic = 'force-dynamic';

const SOURCE_LABELS = {
  manual: 'Manual',
  opening_balance: 'Opening balance',
  sales_invoice: 'Sales invoice',
  sales_credit: 'Sales credit',
  sales_receipt: 'Receipt',
  purchase_invoice: 'Bill',
  purchase_credit: 'Purchase credit',
  purchase_payment: 'Payment',
  bank_payment: 'Bank payment',
  bank_receipt: 'Bank receipt',
  bank_transfer: 'Transfer',
  vat_return: 'VAT return',
  depreciation: 'Depreciation',
  year_end: 'Year end',
  reversal: 'Reversal',
};

export default async function JournalsPage() {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;

  const { data: journals } = await supabase
    .from('journal')
    .select('id, journal_no, date, reference, description, source_type, reversed_by_journal_id, reverses_journal_id, journal_line(debit)')
    .eq('organisation_id', org.id)
    .order('date', { ascending: false })
    .order('journal_no', { ascending: false })
    .limit(200);

  const rows = (journals || []).map((j) => ({
    ...j,
    total: (j.journal_line || []).reduce((sum, l) => sum + Number(l.debit || 0), 0),
  }));

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>{pro ? 'Journals' : 'Transactions'}</h1>
          <p>
            Everything recorded, newest first. Nothing here can be edited or
            deleted — a mistake is corrected by reversing it, which leaves both
            entries on the record.
          </p>
        </div>
        <Link href="/journals/new" className="btn btn-primary">
          Record a transaction
        </Link>
      </div>

      <div className="card">
        {rows.length === 0 ? (
          <div className="empty">
            <h3>Nothing recorded yet</h3>
            <p>
              Once you record your first transaction it will appear here, along
              with everything the sales, purchase and bank screens post later.
            </p>
            <Link href="/journals/new" className="btn btn-primary mt-md">
              Record the first one
            </Link>
          </div>
        ) : (
          <table className="table table-flush">
            <thead>
              <tr>
                {pro && <th style={{ width: '4.5rem' }}>No.</th>}
                <th style={{ width: '7rem' }}>Date</th>
                <th>Description</th>
                <th style={{ width: '8rem' }}>Reference</th>
                <th style={{ width: '9rem' }}>Type</th>
                <th className="num" style={{ width: '8rem' }}>Amount</th>
                <th style={{ width: '7rem' }} />
              </tr>
            </thead>
            <tbody>
              {rows.map((j) => {
                const reversed = Boolean(j.reversed_by_journal_id);
                return (
                  <tr key={j.id}>
                    {pro && <td className="code">{j.journal_no}</td>}
                    <td className="nowrap">{shortDate(j.date)}</td>
                    <td>
                      {j.description}
                      {reversed && (
                        <>
                          {' '}
                          <span className="pill pill-negative">Reversed</span>
                        </>
                      )}
                      {j.reverses_journal_id && (
                        <>
                          {' '}
                          <span className="pill">Reversal</span>
                        </>
                      )}
                    </td>
                    <td className="code">{j.reference || ''}</td>
                    <td>
                      <span className="pill">
                        {SOURCE_LABELS[j.source_type] || j.source_type}
                      </span>
                    </td>
                    <td>
                      <Money value={j.total} />
                    </td>
                    <td>
                      {!reversed && !j.reverses_journal_id && (
                        <ReverseButton journalId={j.id} description={j.description} />
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>

      {rows.length >= 200 && (
        <p className="hint mt-md">Showing the most recent 200 transactions.</p>
      )}
    </div>
  );
}

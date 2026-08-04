import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireOrg } from '@/lib/org';
import { money, shortDate } from '@/lib/format';
import Money from '@/components/Money';

export const dynamic = 'force-dynamic';

const SOURCE_LABELS = {
  manual: 'Manual', opening_balance: 'Opening balance',
  sales_invoice: 'Invoice', sales_credit: 'Credit note', sales_receipt: 'Receipt',
  purchase_invoice: 'Bill', purchase_credit: 'Credit note', purchase_payment: 'Payment',
  bank_payment: 'Bank payment', bank_receipt: 'Bank receipt', bank_transfer: 'Transfer',
  vat_return: 'VAT return', depreciation: 'Depreciation', year_end: 'Year end',
  reversal: 'Reversal', allocation: 'Allocation',
};

/**
 * Nominal activity. Every transaction that touched one account, with a
 * running balance.
 *
 * account_activity() has existed in the database since phase 1 but had
 * nothing calling it, which meant the trial balance and the chart of
 * accounts were dead ends — rows that looked like they should open
 * something and did not.
 */
export default async function AccountActivityPage({ params, searchParams }) {
  const { supabase, org, features, currentYear } = await requireOrg();
  const pro = features.accountant_mode;

  const { data: account } = await supabase
    .from('account')
    .select('*, account_type(name, report_group, class)')
    .eq('organisation_id', org.id)
    .eq('id', params.id)
    .maybeSingle();

  if (!account) notFound();

  const from = searchParams?.from || currentYear?.start_date || `${new Date().getFullYear()}-01-01`;
  const to = searchParams?.to || currentYear?.end_date || new Date().toISOString().slice(0, 10);

  const { data: rows } = await supabase.rpc('account_activity', {
    p_organisation_id: org.id,
    p_account_id: params.id,
    p_from_date: from,
    p_to_date: to,
  });

  const lines = rows || [];
  const closing = lines.length ? Number(lines[lines.length - 1].running_balance) : 0;
  const debits = lines.reduce((s, r) => s + Number(r.debit || 0), 0);
  const credits = lines.reduce((s, r) => s + Number(r.credit || 0), 0);
  const opening = lines.length
    ? Number(lines[0].running_balance) - Number(lines[0].debit || 0) + Number(lines[0].credit || 0)
    : 0;

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <div className="eyebrow">
            {pro ? `${account.code} · ` : ''}
            {account.account_type?.report_group}
            {account.is_control ? ' · maintained automatically' : ''}
          </div>
          <h1>{pro ? account.name : account.friendly_name || account.name}</h1>
          <p>Every transaction that touched this account between the dates shown.</p>
        </div>
        <div className="btn-row">
          <Link href="/accounts" className="btn btn-secondary">All categories</Link>
          {!account.is_system && (
            <Link href={`/accounts/${params.id}/edit`} className="btn btn-secondary">
              Edit
            </Link>
          )}
          <form className="row" style={{ gap: '0.5rem' }}>
            <input className="input" type="date" name="from" defaultValue={from} style={{ width: 'auto' }} />
            <input className="input" type="date" name="to" defaultValue={to} style={{ width: 'auto' }} />
            <button className="btn btn-primary" type="submit">Show</button>
          </form>
        </div>
      </div>

      <div className="grid grid-4">
        <div className="card"><div className="card-body">
          <div className="eyebrow">Brought forward</div>
          <div className="num" style={{ fontSize: '1.25rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(opening, { currency: org.base_currency_code })}
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Debits</div>
          <div className="num" style={{ fontSize: '1.25rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(debits)}
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Credits</div>
          <div className="num" style={{ fontSize: '1.25rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(credits)}
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Carried forward</div>
          <div className="num" style={{ fontSize: '1.25rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(closing, { currency: org.base_currency_code })}
          </div>
        </div></div>
      </div>

      <div className="card mt-lg">
        {lines.length === 0 ? (
          <div className="empty">
            <h3>Nothing in this period</h3>
            <p>No transactions touched this account between {shortDate(from)} and {shortDate(to)}.</p>
          </div>
        ) : (
          <table className="table table-flush">
            <thead>
              <tr>
                <th style={{ width: '7rem' }}>Date</th>
                {pro && <th style={{ width: '4.5rem' }}>No.</th>}
                <th>Description</th>
                <th style={{ width: '8rem' }}>Reference</th>
                <th style={{ width: '8rem' }}>Type</th>
                <th className="num" style={{ width: '7.5rem' }}>Debit</th>
                <th className="num" style={{ width: '7.5rem' }}>Credit</th>
                <th className="num" style={{ width: '8rem' }}>Balance</th>
              </tr>
            </thead>
            <tbody>
              {lines.map((r) => (
                <tr key={`${r.journal_id}-${r.journal_no}-${r.debit}-${r.credit}`}>
                  <td className="nowrap">{shortDate(r.date)}</td>
                  {pro && <td className="code">{r.journal_no}</td>}
                  <td>
                    {r.line_description || r.description}
                    {r.line_description && r.description !== r.line_description && (
                      <div className="hint">{r.description}</div>
                    )}
                  </td>
                  <td className="code small">{r.reference || ''}</td>
                  <td><span className="pill">{SOURCE_LABELS[r.source_type] || r.source_type}</span></td>
                  <td><Money value={r.debit} blankZero /></td>
                  <td><Money value={r.credit} blankZero /></td>
                  <td><Money value={r.running_balance} /></td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={pro ? 5 : 4}>Carried forward</td>
                <td><Money value={debits} /></td>
                <td><Money value={credits} /></td>
                <td><Money value={closing} /></td>
              </tr>
            </tfoot>
          </table>
        )}
      </div>
    </div>
  );
}

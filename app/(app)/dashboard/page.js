import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { currency, shortDate } from '@/lib/format';
import Money from '@/components/Money';

export const dynamic = 'force-dynamic';

export default async function DashboardPage() {
  const { supabase, org, features, currentYear } = await requireOrg();
  const pro = features.accountant_mode;

  const to = currentYear?.end_date || new Date().toISOString().slice(0, 10);

  const [{ data: tb }, { data: recent }, { count: journalCount }, { data: agedSales }, { data: agedPurchase }] = await Promise.all([
    supabase.rpc('trial_balance', { p_organisation_id: org.id, p_to_date: to }),
    supabase
      .from('journal')
      .select('id, journal_no, date, description, source_type, journal_line(debit)')
      .eq('organisation_id', org.id)
      .order('date', { ascending: false })
      .order('journal_no', { ascending: false })
      .limit(6),
    supabase
      .from('journal')
      .select('id', { count: 'exact', head: true })
      .eq('organisation_id', org.id),
    supabase.rpc('aged_analysis', { p_organisation_id: org.id, p_ledger: 'sales' }),
    supabase.rpc('aged_analysis', { p_organisation_id: org.id, p_ledger: 'purchase' }),
  ]);

  const rows = tb || [];
  const sumBy = (fn) =>
    rows.filter(fn).reduce((s, r) => s + Number(r.credit || 0) - Number(r.debit || 0), 0);

  const income = sumBy((r) => r.class === 'income');
  const expenses = -sumBy((r) => r.class === 'expense');
  const profit = income - expenses;
  const cash = -sumBy((r) => r.type_code === 'bank');
  const owedToYou = (agedSales || []).reduce((s, a) => s + Number(a.total || 0), 0);
  const owedByYou = (agedPurchase || []).reduce((s, a) => s + Number(a.total || 0), 0);
  const overdueToYou = (agedSales || []).reduce(
    (s, a) =>
      s + Number(a.days_30 || 0) + Number(a.days_60 || 0) +
          Number(a.days_90 || 0) + Number(a.older || 0),
    0
  );

  const cards = [
    { label: pro ? 'Turnover' : 'Money earned', value: income },
    { label: pro ? 'Expenditure' : 'Money spent', value: expenses },
    { label: profit >= 0 ? 'Profit so far' : 'Loss so far', value: Math.abs(profit), tone: profit >= 0 ? 'positive' : 'negative' },
    { label: 'In the bank', value: cash },
  ];

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>Overview</h1>
          <p>
            {currentYear
              ? `Year to ${shortDate(currentYear.end_date)}`
              : 'No financial year is open'}
          </p>
        </div>
        <div className="btn-row">
          <Link href="/bills/new" className="btn btn-secondary">Enter a bill</Link>
          <Link href="/invoices/new" className="btn btn-primary">Raise an invoice</Link>
        </div>
      </div>

      {journalCount === 0 && (
        <div className="notice notice-info">
          Your accounts are set up and empty. Add a customer, raise an invoice,
          and the figures here will start to move.
        </div>
      )}

      <div className="grid grid-4">
        {cards.map((c) => (
          <div className="card" key={c.label}>
            <div className="card-body">
              <div className="eyebrow">{c.label}</div>
              <div
                className="num"
                style={{
                  fontSize: '1.5rem',
                  fontWeight: 600,
                  marginTop: '0.375rem',
                  textAlign: 'left',
                  color: c.tone === 'negative' ? 'var(--negative)' : 'var(--ink)',
                }}
              >
                {currency(c.value, org.base_currency_code)}
              </div>
            </div>
          </div>
        ))}
      </div>

      <div className="grid grid-2 mt-lg">
        <div className="card">
          <div className="card-head">
            <h2>Who owes what</h2>
            <Link href="/reports/aged-debtors" className="btn btn-open btn-sm">
              Aged debtors
            </Link>
          </div>
          <table className="table table-flush">
            <tbody>
              <tr className="no-hover">
                <td>{pro ? 'Trade debtors' : 'Owed to you'}</td>
                <td><Money value={owedToYou} /></td>
              </tr>
              <tr className="no-hover">
                <td style={{ paddingLeft: '1.75rem' }} className="muted small">
                  of which overdue
                </td>
                <td>
                  <span className={overdueToYou > 0 ? 'num num-negative' : 'num num-nil'}>
                    {currency(overdueToYou, org.base_currency_code)}
                  </span>
                </td>
              </tr>
              <tr className="no-hover">
                <td>{pro ? 'Trade creditors' : 'You owe'}</td>
                <td><Money value={owedByYou} /></td>
              </tr>
            </tbody>
          </table>
        </div>

        <div className="card">
          <div className="card-head">
            <h2>Recent activity</h2>
            <Link href="/journals" className="btn btn-open btn-sm">See all</Link>
          </div>
          {(recent || []).length === 0 ? (
            <div className="empty" style={{ padding: '2rem 1.25rem' }}>
              <p>Nothing recorded yet.</p>
            </div>
          ) : (
            <table className="table table-flush">
              <tbody>
                {(recent || []).map((j) => (
                  <tr key={j.id}>
                    <td className="nowrap muted small" style={{ width: '6rem' }}>
                      {shortDate(j.date)}
                    </td>
                    <td>{j.description}</td>
                    <td>
                      <Money
                        value={(j.journal_line || []).reduce((s, l) => s + Number(l.debit || 0), 0)}
                      />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}

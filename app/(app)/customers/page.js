import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { money, shortDate } from '@/lib/format';
import Money from '@/components/Money';
import SortHeader from '@/components/SortHeader';
import ActionsMenu from '@/components/ActionsMenu';
import ExportButtons from '@/components/ExportButtons';

export const dynamic = 'force-dynamic';

const SORTS = {
  code: (r) => r.code || '',
  name: (r) => (r.name || '').toLowerCase(),
  total_due: (r) => Number(r.total_due),
  outstanding_count: (r) => Number(r.outstanding_count),
  overdue_amount: (r) => Number(r.overdue_amount),
  overdue_count: (r) => Number(r.overdue_count),
  oldest_days: (r) => Number(r.oldest_days),
};

export default async function CustomersPage({ searchParams }) {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;
  const ccy = org.base_currency_code;

  const { data } = await supabase.rpc('contact_summary', {
    p_organisation_id: org.id,
    p_ledger: 'sales',
  });

  const rows = [...(data || [])];

  // Sorted here rather than in SQL: the list is small, and doing it in one
  // place keeps the sort keys and the column headings from drifting apart.
  const sort = SORTS[searchParams?.sort] ? searchParams.sort : 'name';
  const dir = searchParams?.dir === 'desc' ? -1 : 1;
  const key = SORTS[sort];

  rows.sort((a, b) => {
    const av = key(a);
    const bv = key(b);
    if (av < bv) return -1 * dir;
    if (av > bv) return 1 * dir;
    return (a.name || '').localeCompare(b.name || '');
  });

  const totals = rows.reduce(
    (t, r) => ({
      due: t.due + Number(r.total_due),
      overdue: t.overdue + Number(r.overdue_amount),
      invoices: t.invoices + Number(r.outstanding_count),
      overdueInvoices: t.overdueInvoices + Number(r.overdue_count),
    }),
    { due: 0, overdue: 0, invoices: 0, overdueInvoices: 0 }
  );

  const active = rows.filter((r) => r.active).length;

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Customers</h1>
          <p>Who you sell to, and what they still owe.</p>
        </div>
        <div className="btn-row">
          <Link href="/invoices/new?type=credit" className="btn btn-secondary">
            Credit note
          </Link>
          <Link href="/invoices/new" className="btn btn-secondary">Invoice</Link>
          <Link href="/money/receipt" className="btn btn-secondary">Money received</Link>
          <Link href="/customers/new" className="btn btn-primary">Add a customer</Link>
        </div>
      </div>

      {rows.length > 0 && (
        <>
          <div className="grid grid-4">
            <div className="card"><div className="card-body">
              <div className="eyebrow">Owed to you</div>
              <div className="num headline">{money(totals.due, { currency: ccy })}</div>
              <div className="hint">
                {totals.invoices} invoice{totals.invoices === 1 ? '' : 's'}
              </div>
            </div></div>

            <div className="card"><div className="card-body">
              <div className="eyebrow">Overdue</div>
              <div
                className="num headline"
                style={{ color: totals.overdue > 0 ? 'var(--negative)' : 'var(--ink)' }}
              >
                {money(totals.overdue, { currency: ccy })}
              </div>
              <div className="hint">
                {totals.overdueInvoices} invoice{totals.overdueInvoices === 1 ? '' : 's'}
              </div>
            </div></div>

            <div className="card"><div className="card-body">
              <div className="eyebrow">Customers</div>
              <div className="num headline">{active}</div>
              <div className="hint">
                {rows.filter((r) => Number(r.total_due) !== 0).length} with a balance
              </div>
            </div></div>

            <div className="card"><div className="card-body">
              <div className="eyebrow">Over their limit</div>
              <div
                className="num headline"
                style={{ color: rows.some((r) => r.over_limit) ? 'var(--caution)' : 'var(--ink)' }}
              >
                {rows.filter((r) => r.over_limit).length}
              </div>
              <div className="hint">Where a limit is set</div>
            </div></div>
          </div>

          <div className="mt-lg">
            <ExportButtons orgId={org.id} ledger="sales" orgName={org.name} />
          </div>
        </>
      )}

      <div className="card mt-lg">
        {rows.length === 0 ? (
          <div className="empty">
            <h3>No customers yet</h3>
            <p>Add the first one and you can start raising invoices.</p>
            <Link href="/customers/new" className="btn btn-primary mt-md">Add a customer</Link>
          </div>
        ) : (
          <table className="table table-flush">
            <thead>
              <tr>
                {pro && <SortHeader field="code">Code</SortHeader>}
                <SortHeader field="name">Name</SortHeader>
                <SortHeader field="total_due" numeric defaultDesc>Total due</SortHeader>
                <SortHeader field="outstanding_count" numeric defaultDesc>Invoices</SortHeader>
                <SortHeader field="overdue_amount" numeric defaultDesc>Overdue</SortHeader>
                <SortHeader field="overdue_count" numeric defaultDesc>Overdue invoices</SortHeader>
                <SortHeader field="oldest_days" numeric defaultDesc>Oldest</SortHeader>
                <th style={{ width: '7rem' }} />
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.contact_id}>
                  {pro && <td className="code">{c.code}</td>}
                  <td>
                    <Link href={`/customers/${c.contact_id}`} className="table-link">
                      {c.name}
                    </Link>
                    {c.on_hold && <> <span className="pill pill-negative">On hold</span></>}
                    {c.over_limit && <> <span className="pill pill-caution">Over limit</span></>}
                    {!c.active && <> <span className="pill">Inactive</span></>}
                  </td>
                  <td><Money value={c.total_due} blankZero /></td>
                  <td>
                    <span className={Number(c.outstanding_count) ? 'num' : 'num num-nil'}>
                      {c.outstanding_count || ''}
                    </span>
                  </td>
                  <td>
                    <span className={Number(c.overdue_amount) ? 'num num-negative' : 'num num-nil'}>
                      {Number(c.overdue_amount) ? money(c.overdue_amount) : ''}
                    </span>
                  </td>
                  <td>
                    <span className={Number(c.overdue_count) ? 'num num-negative' : 'num num-nil'}>
                      {c.overdue_count || ''}
                    </span>
                  </td>
                  <td>
                    {Number(c.oldest_days) > 0 ? (
                      <span className="num">
                        {c.oldest_days}d
                      </span>
                    ) : (
                      <span className="num num-nil" />
                    )}
                  </td>
                  <td className="actions" style={{ position: 'relative' }}>
                    <ActionsMenu
                      items={[
                        { href: `/customers/${c.contact_id}`, label: 'View activity' },
                        { href: `/customers/${c.contact_id}/edit`, label: 'Edit customer' },
                        { divider: true },
                        { href: `/invoices/new?contact=${c.contact_id}`, label: 'Raise an invoice' },
                        {
                          href: `/invoices/new?type=credit&contact=${c.contact_id}`,
                          label: 'Raise a credit note',
                        },
                        { href: `/money/receipt?contact=${c.contact_id}`, label: 'Record a receipt' },
                      ]}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={pro ? 2 : 1}>Total</td>
                <td><Money value={totals.due} /></td>
                <td><span className="num">{totals.invoices}</span></td>
                <td>
                  <span className={totals.overdue ? 'num num-negative' : 'num num-nil'}>
                    {money(totals.overdue)}
                  </span>
                </td>
                <td><span className="num">{totals.overdueInvoices}</span></td>
                <td colSpan={2} />
              </tr>
            </tfoot>
          </table>
        )}
      </div>
    </div>
  );
}

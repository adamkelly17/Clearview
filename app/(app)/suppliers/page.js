import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { money } from '@/lib/format';
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

export default async function SuppliersPage({ searchParams }) {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;
  const ccy = org.base_currency_code;

  const { data } = await supabase.rpc('contact_summary', {
    p_organisation_id: org.id,
    p_ledger: 'purchase',
  });

  const rows = [...(data || [])];
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
      bills: t.bills + Number(r.outstanding_count),
      overdueBills: t.overdueBills + Number(r.overdue_count),
    }),
    { due: 0, overdue: 0, bills: 0, overdueBills: 0 }
  );

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Suppliers</h1>
          <p>Who you buy from, and what you still owe them.</p>
        </div>
        <div className="btn-row">
          <Link href="/bills/new?type=credit" className="btn btn-secondary">Credit note</Link>
          <Link href="/bills/new" className="btn btn-secondary">Bill</Link>
          <Link href="/money/payment" className="btn btn-secondary">Money paid out</Link>
          <Link href="/suppliers/new" className="btn btn-primary">Add a supplier</Link>
        </div>
      </div>

      {rows.length > 0 && (
        <>
          <div className="grid grid-4">
            <div className="card"><div className="card-body">
              <div className="eyebrow">You owe</div>
              <div className="num headline">{money(totals.due, { currency: ccy })}</div>
              <div className="hint">{totals.bills} bill{totals.bills === 1 ? '' : 's'}</div>
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
                {totals.overdueBills} bill{totals.overdueBills === 1 ? '' : 's'}
              </div>
            </div></div>

            <div className="card"><div className="card-body">
              <div className="eyebrow">Suppliers</div>
              <div className="num headline">{rows.filter((r) => r.active).length}</div>
              <div className="hint">
                {rows.filter((r) => Number(r.total_due) !== 0).length} with a balance
              </div>
            </div></div>

            <div className="card"><div className="card-body">
              <div className="eyebrow">Under CIS</div>
              <div className="num headline">
                {rows.filter((r) => r.cis_registered).length}
              </div>
              <div className="hint">Subcontractors</div>
            </div></div>
          </div>

          <div className="mt-lg">
            <ExportButtons orgId={org.id} ledger="purchase" orgName={org.name} />
          </div>
        </>
      )}

      <div className="card mt-lg">
        {rows.length === 0 ? (
          <div className="empty">
            <h3>No suppliers yet</h3>
            <p>Add the first one and you can start entering bills.</p>
            <Link href="/suppliers/new" className="btn btn-primary mt-md">Add a supplier</Link>
          </div>
        ) : (
          <table className="table table-flush">
            <thead>
              <tr>
                {pro && <SortHeader field="code">Code</SortHeader>}
                <SortHeader field="name">Name</SortHeader>
                <SortHeader field="total_due" numeric defaultDesc>You owe</SortHeader>
                <SortHeader field="outstanding_count" numeric defaultDesc>Bills</SortHeader>
                <SortHeader field="overdue_amount" numeric defaultDesc>Overdue</SortHeader>
                <SortHeader field="overdue_count" numeric defaultDesc>Overdue bills</SortHeader>
                <SortHeader field="oldest_days" numeric defaultDesc>Oldest</SortHeader>
                <th style={{ width: '7rem' }} />
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.contact_id}>
                  {pro && <td className="code">{c.code}</td>}
                  <td>
                    <Link href={`/suppliers/${c.contact_id}`} className="table-link">
                      {c.name}
                    </Link>
                    {c.cis_registered && <> <span className="pill pill-accent">CIS</span></>}
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
                      <span className="num">{c.oldest_days}d</span>
                    ) : (
                      <span className="num num-nil" />
                    )}
                  </td>
                  <td className="actions" style={{ position: 'relative' }}>
                    <ActionsMenu
                      items={[
                        { href: `/suppliers/${c.contact_id}`, label: 'View activity' },
                        { href: `/suppliers/${c.contact_id}/edit`, label: 'Edit supplier' },
                        { divider: true },
                        { href: `/bills/new?contact=${c.contact_id}`, label: 'Enter a bill' },
                        {
                          href: `/bills/new?type=credit&contact=${c.contact_id}`,
                          label: 'Enter a credit note',
                        },
                        { href: `/money/payment?contact=${c.contact_id}`, label: 'Record a payment' },
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
                <td><span className="num">{totals.bills}</span></td>
                <td>
                  <span className={totals.overdue ? 'num num-negative' : 'num num-nil'}>
                    {money(totals.overdue)}
                  </span>
                </td>
                <td><span className="num">{totals.overdueBills}</span></td>
                <td colSpan={2} />
              </tr>
            </tfoot>
          </table>
        )}
      </div>
    </div>
  );
}

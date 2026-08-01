import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import Money from '@/components/Money';
import { shortDate } from '@/lib/format';

export const dynamic = 'force-dynamic';

export default async function CustomersPage() {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;

  const [{ data: contacts }, { data: aged }] = await Promise.all([
    supabase
      .from('contact')
      .select('id, code, name, email, phone, credit_limit, on_hold, active')
      .eq('organisation_id', org.id)
      .eq('is_customer', true)
      .order('name'),
    supabase.rpc('aged_analysis', { p_organisation_id: org.id, p_ledger: 'sales' }),
  ]);

  const owed = new Map((aged || []).map((a) => [a.contact_id, a]));
  const rows = contacts || [];
  const total = (aged || []).reduce((s, a) => s + Number(a.total || 0), 0);
  const overdue = (aged || []).reduce(
    (s, a) => s + Number(a.days_30 || 0) + Number(a.days_60 || 0) + Number(a.days_90 || 0) + Number(a.older || 0),
    0
  );

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Customers</h1>
          <p>Who you sell to, and what they still owe.</p>
        </div>
        <div className="btn-row">
          <Link href="/money/receipt" className="btn btn-secondary">Money received</Link>
          <Link href="/customers/new" className="btn btn-primary">Add a customer</Link>
        </div>
      </div>

      {rows.length > 0 && (
        <div className="grid grid-3">
          <div className="card"><div className="card-body">
            <div className="eyebrow">Owed to you</div>
            <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
              {new Intl.NumberFormat('en-GB', { style: 'currency', currency: org.base_currency_code }).format(total)}
            </div>
          </div></div>
          <div className="card"><div className="card-body">
            <div className="eyebrow">Overdue</div>
            <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left', color: overdue > 0 ? 'var(--negative)' : 'var(--ink)' }}>
              {new Intl.NumberFormat('en-GB', { style: 'currency', currency: org.base_currency_code }).format(overdue)}
            </div>
          </div></div>
          <div className="card"><div className="card-body">
            <div className="eyebrow">Customers</div>
            <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
              {rows.filter((r) => r.active).length}
            </div>
          </div></div>
        </div>
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
                {pro && <th style={{ width: '5rem' }}>Code</th>}
                <th>Name</th>
                <th>Contact</th>
                <th className="num" style={{ width: '9rem' }}>Owed</th>
                <th style={{ width: '9rem' }}>Oldest due</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => {
                const a = owed.get(c.id);
                const over = a && Number(a.total) > 0 && a.oldest_due && new Date(a.oldest_due) < new Date();
                return (
                  <tr key={c.id}>
                    {pro && <td className="code">{c.code}</td>}
                    <td>
                      <Link href={`/customers/${c.id}`}>{c.name}</Link>
                      {c.on_hold && <> <span className="pill pill-negative">On hold</span></>}
                      {!c.active && <> <span className="pill">Inactive</span></>}
                    </td>
                    <td className="muted small">{c.email || c.phone || ''}</td>
                    <td><Money value={a?.total || 0} blankZero /></td>
                    <td className="small">
                      {a?.oldest_due ? (
                        <>
                          {shortDate(a.oldest_due)}
                          {over && <> <span className="pill pill-negative">Overdue</span></>}
                        </>
                      ) : ''}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

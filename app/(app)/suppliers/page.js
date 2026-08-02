import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import Money from '@/components/Money';
import { shortDate } from '@/lib/format';

export const dynamic = 'force-dynamic';

export default async function SuppliersPage() {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;

  const [{ data: contacts }, { data: aged }] = await Promise.all([
    supabase
      .from('contact')
      .select('id, code, name, email, phone, cis_registered, active')
      .eq('organisation_id', org.id)
      .eq('is_supplier', true)
      .order('name'),
    supabase.rpc('aged_analysis', { p_organisation_id: org.id, p_ledger: 'purchase' }),
  ]);

  const owed = new Map((aged || []).map((a) => [a.contact_id, a]));
  const rows = contacts || [];
  const total = (aged || []).reduce((s, a) => s + Number(a.total || 0), 0);

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Suppliers</h1>
          <p>Who you buy from, and what you still owe them.</p>
        </div>
        <div className="btn-row">
          <Link href="/money/payment" className="btn btn-secondary">Money paid out</Link>
          <Link href="/suppliers/new" className="btn btn-primary">Add a supplier</Link>
        </div>
      </div>

      {rows.length > 0 && (
        <div className="grid grid-2">
          <div className="card"><div className="card-body">
            <div className="eyebrow">You owe</div>
            <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
              {new Intl.NumberFormat('en-GB', { style: 'currency', currency: org.base_currency_code }).format(total)}
            </div>
          </div></div>
          <div className="card"><div className="card-body">
            <div className="eyebrow">Suppliers</div>
            <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
              {rows.filter((r) => r.active).length}
            </div>
          </div></div>
        </div>
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
                {pro && <th style={{ width: '5rem' }}>Code</th>}
                <th>Name</th>
                <th>Contact</th>
                <th style={{ width: '6rem' }} />
                <th className="num" style={{ width: '9rem' }}>You owe</th>
                <th style={{ width: '8rem' }}>Oldest due</th>
                <th style={{ width: '5.5rem' }} />
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => {
                const a = owed.get(c.id);
                return (
                  <tr key={c.id}>
                    {pro && <td className="code">{c.code}</td>}
                    <td>
                      <Link href={`/suppliers/${c.id}`} className="table-link">{c.name}</Link>
                      {!c.active && <> <span className="pill">Inactive</span></>}
                    </td>
                    <td className="muted small">{c.email || c.phone || ''}</td>
                    <td>{c.cis_registered && <span className="pill pill-accent">CIS</span>}</td>
                    <td><Money value={a?.total || 0} blankZero /></td>
                    <td className="small">{a?.oldest_due ? shortDate(a.oldest_due) : ''}</td>
                    <td className="actions">
                      <Link href={`/suppliers/${c.id}`} className="btn btn-open btn-sm">
                        Open
                      </Link>
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

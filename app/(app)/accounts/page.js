import { Fragment } from 'react';
import { requireOrg } from '@/lib/org';
import Money from '@/components/Money';

export const dynamic = 'force-dynamic';

export default async function AccountsPage() {
  const { supabase, org, features, currentYear } = await requireOrg();
  const pro = features.accountant_mode;

  const to = currentYear?.end_date || new Date().toISOString().slice(0, 10);

  const [{ data: accounts }, { data: tb }] = await Promise.all([
    supabase
      .from('account')
      .select('id, code, name, friendly_name, is_control, is_system, active, account_type(name, report_group, sort_order)')
      .eq('organisation_id', org.id)
      .order('code'),
    supabase.rpc('trial_balance', { p_organisation_id: org.id, p_to_date: to }),
  ]);

  const balances = new Map(
    (tb || []).map((r) => [r.account_id, Number(r.debit || 0) - Number(r.credit || 0)])
  );

  const groups = new Map();
  for (const a of accounts || []) {
    const g = a.account_type?.report_group || 'Other';
    if (!groups.has(g)) groups.set(g, { sort: a.account_type?.sort_order ?? 999, rows: [] });
    groups.get(g).rows.push(a);
  }
  const ordered = [...groups.entries()].sort((a, b) => a[1].sort - b[1].sort);

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>{pro ? 'Chart of accounts' : 'Categories'}</h1>
          <p>
            {pro
              ? 'The nominal ledger. Accounts marked as system accounts are maintained automatically and cannot be posted to by hand.'
              : 'Every transaction is filed into one of these. The ones marked automatic look after themselves.'}
          </p>
        </div>
      </div>

      <div className="card">
        <table className="table table-flush">
          <thead>
            <tr>
              {pro && <th style={{ width: '5rem' }}>Code</th>}
              <th>Name</th>
              {pro && <th>Type</th>}
              <th style={{ width: '8rem' }} />
              <th className="num" style={{ width: '9rem' }}>Balance</th>
            </tr>
          </thead>
          <tbody>
            {ordered.map(([group, { rows }]) => (
              <Fragment key={group}>
                <tr className="row-group no-hover">
                  <td colSpan={pro ? 5 : 3}>{group}</td>
                </tr>
                {rows.map((a) => {
                  const bal = balances.get(a.id) || 0;
                  return (
                    <tr key={a.id}>
                      {pro && <td className="code">{a.code}</td>}
                      <td>
                        {pro ? a.name : a.friendly_name || a.name}
                        {!a.active && ' '}
                        {!a.active && <span className="pill">Inactive</span>}
                      </td>
                      {pro && <td className="muted small">{a.account_type?.name}</td>}
                      <td>
                        {a.is_control && (
                          <span className="pill pill-accent">Automatic</span>
                        )}
                      </td>
                      <td><Money value={bal} blankZero /></td>
                    </tr>
                  );
                })}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>

      <p className="hint mt-md">
        Adding and editing accounts arrives with the next phase. The list above
        is the standard UK layout, adjusted for a {org.entity_type?.name?.toLowerCase() || 'business'}.
      </p>
    </div>
  );
}

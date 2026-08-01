import { Fragment } from 'react';
import { requireOrg } from '@/lib/org';
import { shortDate } from '@/lib/format';
import Money from '@/components/Money';

export const dynamic = 'force-dynamic';

export default async function TrialBalancePage({ searchParams }) {
  const { supabase, org, features, currentYear } = await requireOrg();
  const pro = features.accountant_mode;

  const to = searchParams?.to || currentYear?.end_date || new Date().toISOString().slice(0, 10);

  const { data: rows, error } = await supabase.rpc('trial_balance', {
    p_organisation_id: org.id,
    p_to_date: to,
  });

  const lines = rows || [];
  const totalDebit = lines.reduce((s, r) => s + Number(r.debit || 0), 0);
  const totalCredit = lines.reduce((s, r) => s + Number(r.credit || 0), 0);
  const agrees = Math.abs(totalDebit - totalCredit) < 0.005;

  /* Group by report section, preserving the account_type sort order
     that came back from the database. */
  const groups = [];
  for (const r of lines) {
    const last = groups[groups.length - 1];
    if (last && last.name === r.report_group) last.rows.push(r);
    else groups.push({ name: r.report_group, rows: [r] });
  }

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>Trial balance</h1>
          <p>
            Every account with a balance as at {shortDate(to)}. The two columns
            must agree — if they ever do not, something is wrong with the
            ledger itself.
          </p>
        </div>
        <form className="row" style={{ gap: '0.5rem' }}>
          <input className="input" type="date" name="to" defaultValue={to} style={{ width: 'auto' }} />
          <button className="btn btn-secondary" type="submit">Show</button>
        </form>
      </div>

      {error && <div className="notice notice-error">{error.message}</div>}

      {lines.length === 0 ? (
        <div className="card">
          <div className="empty">
            <h3>Nothing to show yet</h3>
            <p>
              The trial balance fills up as soon as you record your first
              transaction.
            </p>
          </div>
        </div>
      ) : (
        <>
          <div className="card">
            <table className="table table-flush">
              <thead>
                <tr>
                  {pro && <th style={{ width: '5rem' }}>Code</th>}
                  <th>Account</th>
                  <th className="num" style={{ width: '9rem' }}>Debit</th>
                  <th className="num" style={{ width: '9rem' }}>Credit</th>
                </tr>
              </thead>
              <tbody>
                {groups.map((g) => (
                  <Fragment key={g.name}>
                    <tr className="row-group no-hover">
                      <td colSpan={pro ? 4 : 3}>{g.name}</td>
                    </tr>
                    {g.rows.map((r) => (
                      <tr key={r.account_id}>
                        {pro && <td className="code">{r.code}</td>}
                        <td>{pro ? r.name : r.friendly_name}</td>
                        <td><Money value={r.debit} blankZero /></td>
                        <td><Money value={r.credit} blankZero /></td>
                      </tr>
                    ))}
                  </Fragment>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan={pro ? 2 : 1}>Total</td>
                  <td><Money value={totalDebit} /></td>
                  <td><Money value={totalCredit} /></td>
                </tr>
              </tfoot>
            </table>
          </div>

          <div className={`notice mt-md ${agrees ? 'notice-info' : 'notice-error'}`}>
            {agrees
              ? 'Debits and credits agree.'
              : `Debits and credits do not agree. Difference of ${Math.abs(totalDebit - totalCredit).toFixed(2)}. This should never happen — please report it.`}
          </div>
        </>
      )}
    </div>
  );
}

import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { money } from '@/lib/format';
import Money from '@/components/Money';

export const dynamic = 'force-dynamic';

const TYPE_LABELS = {
  current: 'Current account',
  savings: 'Savings',
  credit_card: 'Credit card',
  cash: 'Cash',
  loan: 'Loan',
};

export default async function BankingPage() {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;

  const { data: accounts } = await supabase
    .from('bank_account')
    .select('*, account(code, name, friendly_name)')
    .eq('organisation_id', org.id)
    .eq('active', true)
    .order('name');

  // One reconciliation summary per account. A handful of accounts, so a
  // few round trips is cheaper than a view that has to guess the date.
  const summaries = await Promise.all(
    (accounts || []).map(async (b) => {
      const { data } = await supabase.rpc('bank_reconciliation', {
        p_bank_account_id: b.id,
      });
      return { id: b.id, summary: (data || [])[0] || null };
    })
  );

  const byId = new Map(summaries.map((s) => [s.id, s.summary]));
  const totalToDo = summaries.reduce(
    (sum, s) => sum + Number(s.summary?.unmatched_lines || 0),
    0
  );
  const totalCash = summaries.reduce(
    (sum, s) => sum + Number(s.summary?.ledger_balance || 0),
    0
  );

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Banking</h1>
          <p>
            {totalToDo > 0
              ? `${totalToDo} statement line${totalToDo === 1 ? '' : 's'} waiting to be dealt with.`
              : 'Import a statement and match it against what is already recorded.'}
          </p>
        </div>
        <Link href="/banking/new" className="btn btn-primary">Add an account</Link>
      </div>

      <div className="grid grid-2">
        <div className="card"><div className="card-body">
          <div className="eyebrow">Across all accounts</div>
          <div className="num" style={{ fontSize: '1.5rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(totalCash, { currency: org.base_currency_code })}
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Still to deal with</div>
          <div
            className="num"
            style={{
              fontSize: '1.5rem', fontWeight: 600, marginTop: '0.25rem',
              textAlign: 'left',
              color: totalToDo > 0 ? 'var(--caution)' : 'var(--ink)',
            }}
          >
            {totalToDo}
          </div>
        </div></div>
      </div>

      <div className="card mt-lg">
        {(accounts || []).length === 0 ? (
          <div className="empty">
            <h3>No bank accounts</h3>
            <p>
              Your chart of accounts normally comes with a current account,
              savings, petty cash and a credit card. Add one if none appear here.
            </p>
            <Link href="/banking/new" className="btn btn-primary mt-md">
              Add an account
            </Link>
          </div>
        ) : (
          <table className="table table-flush">
            <thead>
              <tr>
                {pro && <th style={{ width: '5rem' }}>Code</th>}
                <th>Account</th>
                <th>Type</th>
                <th className="num" style={{ width: '9rem' }}>Balance</th>
                <th className="num" style={{ width: '8rem' }}>Unreconciled</th>
                <th style={{ width: '8rem' }}>To deal with</th>
                <th style={{ width: '11.5rem' }} />
              </tr>
            </thead>
            <tbody>
              {(accounts || []).map((b) => {
                const s = byId.get(b.id);
                const todo = Number(s?.unmatched_lines || 0);

                return (
                  <tr key={b.id}>
                    {pro && <td className="code">{b.account?.code}</td>}
                    <td>
                      <Link href={`/banking/${b.id}`} className="table-link">{b.name}</Link>
                      {b.sort_code && (
                        <>
                          {' '}
                          <span className="code small">
                            {b.sort_code} {b.account_number ? `· ${b.account_number}` : ''}
                          </span>
                        </>
                      )}
                    </td>
                    <td className="muted small">{TYPE_LABELS[b.type] || b.type}</td>
                    <td><Money value={s?.ledger_balance || 0} /></td>
                    <td><Money value={s?.unreconciled_total || 0} blankZero /></td>
                    <td>
                      {todo > 0 ? (
                        <span className="pill pill-caution">{todo} line{todo === 1 ? '' : 's'}</span>
                      ) : (
                        <span className="pill pill-accent">Clear</span>
                      )}
                    </td>
                    <td className="actions">
                      <Link href={`/banking/${b.id}/import`} className="btn btn-secondary btn-sm">
                        Import
                      </Link>
                      <Link href={`/banking/${b.id}`} className="btn btn-open btn-sm">
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

      <p className="hint mt-md">
        Bank feeds are not built yet. For now, download a CSV or Excel statement
        from your bank and import it — the same matching applies either way, and
        a feed will write to exactly the same place when it arrives.
      </p>
    </div>
  );
}

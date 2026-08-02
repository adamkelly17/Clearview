import { requireOrg } from '@/lib/org';
import AgedReport from '@/components/AgedReport';
import { shortDate } from '@/lib/format';

export const dynamic = 'force-dynamic';

export default async function AgedDebtorsPage({ searchParams }) {
  const { supabase, org, features } = await requireOrg();
  const asAt = searchParams?.as_at || new Date().toISOString().slice(0, 10);

  const { data: rows } = await supabase.rpc('aged_analysis', {
    p_organisation_id: org.id,
    p_ledger: 'sales',
    p_as_at: asAt,
  });

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Aged debtors</h1>
          <p>What customers owe as at {shortDate(asAt)}, by how overdue it is.</p>
        </div>
        <form className="row" style={{ gap: '0.5rem' }}>
          <input className="input" type="date" name="as_at" defaultValue={asAt} style={{ width: 'auto' }} />
          <button className="btn btn-secondary" type="submit">Show</button>
        </form>
      </div>

      <div className="card">
        <AgedReport rows={rows || []} pro={features.accountant_mode} showLimit contactBase="/customers" />
      </div>

      <p className="hint mt-md">
        This total agrees with trade debtors on the trial balance. If it ever
        does not, something has written to the control account without a matching
        ledger item.
      </p>
    </div>
  );
}

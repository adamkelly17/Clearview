import { requireOrg } from '@/lib/org';
import { shortDate, MONTHS } from '@/lib/format';
import FeatureToggles from './FeatureToggles';
import PeriodList from './PeriodList';
import YearEndControl from './YearEndControl';

export const dynamic = 'force-dynamic';

export default async function SettingsPage() {
  const { supabase, org, features, years, currentYear, role } = await requireOrg();

  const { data: periods } = await supabase
    .from('period')
    .select('id, period_no, name, start_date, end_date, status')
    .eq('organisation_id', org.id)
    .eq('fiscal_year_id', currentYear?.id || '00000000-0000-0000-0000-000000000000')
    .order('period_no');

  const canEdit = role === 'owner' || role === 'admin';

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>Settings</h1>
          <p>How this business is set up. Everything except the business type can be changed.</p>
        </div>
      </div>

      <div className="card">
        <div className="card-head"><h2>Business</h2></div>
        <table className="table table-flush">
          <tbody>
            <tr className="no-hover"><td className="muted" style={{ width: '14rem' }}>Name</td><td>{org.name}</td></tr>
            <tr className="no-hover"><td className="muted">Type</td><td>{org.entity_type?.name}</td></tr>
            <tr className="no-hover"><td className="muted">Year end</td><td>{org.year_end_day} {MONTHS[org.year_end_month - 1]}</td></tr>
            <tr className="no-hover"><td className="muted">Books start</td><td>{shortDate(org.books_start_date)}</td></tr>
            <tr className="no-hover"><td className="muted">Main currency</td><td className="code">{org.base_currency_code}</td></tr>
            {org.company_number && (
              <tr className="no-hover"><td className="muted">Company number</td><td className="code">{org.company_number}</td></tr>
            )}
            {org.vat_number && (
              <tr className="no-hover"><td className="muted">VAT number</td><td className="code">{org.vat_number}</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card mt-lg">
        <div className="card-head">
          <h2>Features</h2>
          <span className="hint">Switching these on or off never changes anything already recorded</span>
        </div>
        <div className="card-body">
          <FeatureToggles orgId={org.id} initial={features} canEdit={canEdit} />
        </div>
      </div>

      <div className="card mt-lg">
        <div className="card-head">
          <h2>Periods</h2>
          <span className="hint">
            {currentYear ? `Year to ${shortDate(currentYear.end_date)}` : 'No open year'}
          </span>
        </div>
        <PeriodList periods={periods || []} canEdit={canEdit} />
      </div>

      <div className="card mt-lg">
        <div className="card-head">
          <h2>Financial years</h2>
          <YearEndControl year={currentYear} canEdit={canEdit} />
        </div>
        <table className="table table-flush">
          <thead>
            <tr>
              <th>Year</th>
              <th>From</th>
              <th>To</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {years.map((y) => (
              <tr key={y.id}>
                <td>{y.name}</td>
                <td>{shortDate(y.start_date)}</td>
                <td>{shortDate(y.end_date)}</td>
                <td>
                  <span className={`pill ${y.status === 'open' ? 'pill-accent' : ''}`}>
                    {y.status === 'open' ? 'Open' : 'Closed'}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="card-body" style={{ paddingTop: '0.75rem' }}>
          <p className="hint">
            The next year is created automatically when you close this one.
            Changing the year end here adds or removes months from the open
            year and sets the pattern future years will follow.
          </p>
        </div>
      </div>
    </div>
  );
}

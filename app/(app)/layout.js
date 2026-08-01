import { requireOrg } from '@/lib/org';
import NavLink from '@/components/NavLink';
import { shortDate } from '@/lib/format';

export default async function AppLayout({ children }) {
  const { org, features, currentYear } = await requireOrg();
  const pro = features.accountant_mode;

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="sidebar-brand">
          <div className="sidebar-org" title={org.name}>{org.name}</div>
          {currentYear && (
            <div className="sidebar-year">Year to {shortDate(currentYear.end_date)}</div>
          )}
        </div>

        <nav className="sidebar-nav">
          <NavLink href="/dashboard">Overview</NavLink>

          <div className="nav-section">Sales</div>
          <NavLink href="/customers">Customers</NavLink>
          <NavLink href="/invoices">Invoices</NavLink>
          <NavLink href="/money/receipt">Money received</NavLink>

          <div className="nav-section">Purchases</div>
          <NavLink href="/suppliers">Suppliers</NavLink>
          <NavLink href="/bills">Bills</NavLink>
          <NavLink href="/money/payment">Money paid out</NavLink>

          <div className="nav-section">Reports</div>
          <NavLink href="/reports/trial-balance">Trial balance</NavLink>
          <NavLink href="/reports/aged-debtors">Aged debtors</NavLink>
          <NavLink href="/reports/aged-creditors">Aged creditors</NavLink>

          <div className="nav-section">Other</div>
          <NavLink href="/journals">{pro ? 'All journals' : 'All transactions'}</NavLink>
          <NavLink href="/journals/new">{pro ? 'Manual journal' : 'Other transaction'}</NavLink>
          <NavLink href="/accounts">{pro ? 'Chart of accounts' : 'Categories'}</NavLink>
          <NavLink href="/settings">Settings</NavLink>
        </nav>

        <div className="sidebar-foot">
          {pro ? 'Accountant mode' : 'Simple view'}
          {features.vat_enabled && ' · VAT'}
        </div>
      </aside>

      <main className="main">{children}</main>
    </div>
  );
}

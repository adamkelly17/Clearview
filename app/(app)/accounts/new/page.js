import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { loadAccountLookups } from '@/lib/accountLookups';
import AccountForm from '@/components/AccountForm';

export const dynamic = 'force-dynamic';

export default async function NewAccountPage() {
  const { supabase, org, features } = await requireOrg();
  const { types, vatCodes } = await loadAccountLookups(supabase, org.id, features.vat_enabled);
  const pro = features.accountant_mode;

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>Add a {pro ? 'nominal account' : 'category'}</h1>
          <p>
            Somewhere new to file income or costs. The code is suggested from the
            usual range for whatever kind you pick, and you can change it.
          </p>
        </div>
        <Link href="/accounts" className="btn btn-secondary">Cancel</Link>
      </div>

      <AccountForm
        orgId={org.id}
        types={types}
        vatCodes={vatCodes}
        pro={pro}
        currencyCode={org.base_currency_code}
      />
    </div>
  );
}

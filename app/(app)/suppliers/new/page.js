import { requireOrg } from '@/lib/org';
import { loadTradingLookups } from '@/lib/lookups';
import ContactForm from '@/components/ContactForm';

export const dynamic = 'force-dynamic';

export default async function NewSupplierPage() {
  const { supabase, org, features } = await requireOrg();
  const { accounts, vatCodes } = await loadTradingLookups(supabase, org.id, { ledger: 'purchase' });

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>Add a supplier</h1>
          <p>Only the name is needed. The rest saves you typing later.</p>
        </div>
      </div>

      <ContactForm
        orgId={org.id}
        kind="supplier"
        accounts={accounts}
        vatCodes={features.vat_enabled ? vatCodes : []}
        pro={features.accountant_mode}
      />
    </div>
  );
}

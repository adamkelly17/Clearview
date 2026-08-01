import { requireOrg } from '@/lib/org';
import BankAccountForm from './BankAccountForm';

export const dynamic = 'force-dynamic';

export default async function NewBankAccountPage() {
  const { supabase, org, features } = await requireOrg();

  // Bank nominals that do not yet have a bank account attached. Normally
  // none, since a trigger keeps them in step, but it lets someone attach
  // to an existing nominal rather than making a new one.
  const { data: spare } = await supabase
    .from('account')
    .select('id, code, name, friendly_name')
    .eq('organisation_id', org.id)
    .eq('is_bank', true)
    .eq('active', true)
    .order('code');

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>Add a bank account</h1>
          <p>
            This creates a nominal account in the 12xx range and somewhere to
            import statements to.
          </p>
        </div>
      </div>

      <BankAccountForm
        orgId={org.id}
        existingAccounts={spare || []}
        pro={features.accountant_mode}
        currencyCode={org.base_currency_code}
      />
    </div>
  );
}

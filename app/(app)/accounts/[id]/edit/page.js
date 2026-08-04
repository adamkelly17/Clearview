import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireOrg } from '@/lib/org';
import { loadAccountLookups } from '@/lib/accountLookups';
import AccountForm from '@/components/AccountForm';

export const dynamic = 'force-dynamic';

export default async function EditAccountPage({ params }) {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;

  const { data: account } = await supabase
    .from('account')
    .select('*, account_type(name, friendly_name, class, report, report_group)')
    .eq('organisation_id', org.id)
    .eq('id', params.id)
    .maybeSingle();

  if (!account) notFound();

  const [{ types, existing, vatCodes }, { data: usage }] = await Promise.all([
    loadAccountLookups(supabase, org.id, features.vat_enabled),
    supabase.rpc('account_usage', { p_account_id: params.id }),
  ]);

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <div className="eyebrow">
            {pro ? `${account.code} · ` : ''}
            {account.account_type?.report_group}
            {account.is_system ? ' · system' : ''}
          </div>
          <h1>{pro ? account.name : account.friendly_name || account.name}</h1>
          <p>
            {account.is_system
              ? 'Part of the system. The name can be changed but not what it is or where it sits.'
              : 'Renaming is always safe. Moving it somewhere else changes what your reports say.'}
          </p>
        </div>
        <Link href={`/accounts/${params.id}`} className="btn btn-secondary">Cancel</Link>
      </div>

      <AccountForm
        orgId={org.id}
        types={types}
        existing={existing}
        vatCodes={vatCodes}
        pro={pro}
        currencyCode={org.base_currency_code}
        editing={{
          id: account.id,
          name: account.name,
          friendly_name: account.friendly_name,
          description: account.description,
          account_type_code: account.account_type_code,
          code: account.code,
          default_vat_code_id: account.default_vat_code_id,
          active: account.active,
          is_system: account.is_system,
          class: account.account_type?.class,
        }}
        usage={usage}
      />
    </div>
  );
}

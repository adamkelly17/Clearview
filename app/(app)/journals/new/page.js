import { requireOrg } from '@/lib/org';
import EntryForm from './EntryForm';

export const dynamic = 'force-dynamic';

export default async function NewJournalPage() {
  const { supabase, org, features } = await requireOrg();

  // Control accounts are excluded: they belong to the sales, purchase,
  // bank and VAT modules and must never be typed into by hand.
  const { data: accounts } = await supabase
    .from('account')
    .select('id, code, name, friendly_name, account_type_code, is_control, account_type(name, class, report_group)')
    .eq('organisation_id', org.id)
    .eq('active', true)
    .eq('is_control', false)
    .order('code');

  const { data: periods } = await supabase
    .from('period')
    .select('start_date, end_date, status')
    .eq('organisation_id', org.id)
    .eq('status', 'open')
    .order('start_date');

  const open = periods || [];
  const window = open.length
    ? { from: open[0].start_date, to: open[open.length - 1].end_date }
    : null;

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>Record a transaction</h1>
          <p>
            {features.accountant_mode
              ? 'A manual journal. Debits and credits must agree before it can be posted.'
              : 'Every transaction has two sides: where the money came from and where it went. They have to match.'}
          </p>
        </div>
      </div>

      <EntryForm
        orgId={org.id}
        accounts={accounts || []}
        pro={features.accountant_mode}
        currencyCode={org.base_currency_code}
        window={window}
      />
    </div>
  );
}

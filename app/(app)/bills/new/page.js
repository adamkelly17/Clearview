import { requireOrg } from '@/lib/org';
import { loadTradingLookups } from '@/lib/lookups';
import DocumentForm from '@/components/DocumentForm';

export const dynamic = 'force-dynamic';

export default async function NewBillPage({ searchParams }) {
  const { supabase, org, features } = await requireOrg();
  const lookups = await loadTradingLookups(supabase, org.id, { ledger: 'purchase' });

  const isCredit = searchParams?.type === 'credit';

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>{isCredit ? 'Enter a supplier credit note' : 'Enter a bill'}</h1>
          <p>
            {isCredit
              ? 'Reduces what you owe a supplier.'
              : 'Use the number printed on their invoice so the two can be matched up.'}
          </p>
        </div>
      </div>

      <DocumentForm
        orgId={org.id}
        docType={isCredit ? 'PC' : 'PI'}
        contacts={lookups.contacts}
        accounts={lookups.accounts}
        vatCodes={lookups.vatCodes}
        pro={features.accountant_mode}
        vatEnabled={features.vat_enabled}
        currencyCode={org.base_currency_code}
        initialContactId={searchParams?.contact || null}
      />
    </div>
  );
}

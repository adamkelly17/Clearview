import { requireOrg } from '@/lib/org';
import { loadTradingLookups } from '@/lib/lookups';
import DocumentForm from '@/components/DocumentForm';

export const dynamic = 'force-dynamic';

export default async function NewInvoicePage({ searchParams }) {
  const { supabase, org, features } = await requireOrg();
  const lookups = await loadTradingLookups(supabase, org.id, { ledger: 'sales' });

  const isCredit = searchParams?.type === 'credit';

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>{isCredit ? 'Raise a credit note' : 'Raise an invoice'}</h1>
          <p>
            {isCredit
              ? 'Reduces what a customer owes you. Use this rather than changing an invoice that has already gone out.'
              : 'The number is allocated automatically when you record it.'}
          </p>
        </div>
      </div>

      <DocumentForm
        orgId={org.id}
        docType={isCredit ? 'SC' : 'SI'}
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

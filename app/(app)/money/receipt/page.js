import { requireOrg } from '@/lib/org';
import { loadTradingLookups } from '@/lib/lookups';
import PaymentForm from '@/components/PaymentForm';

export const dynamic = 'force-dynamic';

export default async function ReceiptPage({ searchParams }) {
  const { supabase, org, features } = await requireOrg();
  const { contacts, bankAccounts } = await loadTradingLookups(supabase, org.id, { ledger: 'sales' });

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Money received</h1>
          <p>
            Record a payment from a customer and tick off what it pays. Anything
            left over sits on account.
          </p>
        </div>
      </div>

      <PaymentForm
        orgId={org.id}
        ledger="sales"
        contacts={contacts}
        bankAccounts={bankAccounts}
        pro={features.accountant_mode}
        currencyCode={org.base_currency_code}
        initialContactId={searchParams?.contact || null}
      />
    </div>
  );
}

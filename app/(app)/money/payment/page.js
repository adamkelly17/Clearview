import { requireOrg } from '@/lib/org';
import { loadTradingLookups } from '@/lib/lookups';
import PaymentForm from '@/components/PaymentForm';

export const dynamic = 'force-dynamic';

export default async function PaymentPage({ searchParams }) {
  const { supabase, org, features } = await requireOrg();
  const { contacts, bankAccounts } = await loadTradingLookups(supabase, org.id, { ledger: 'purchase' });

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Money paid out</h1>
          <p>Record a payment to a supplier and tick off which bills it settles.</p>
        </div>
      </div>

      <PaymentForm
        orgId={org.id}
        ledger="purchase"
        contacts={contacts}
        bankAccounts={bankAccounts}
        pro={features.accountant_mode}
        currencyCode={org.base_currency_code}
        initialContactId={searchParams?.contact || null}
      />
    </div>
  );
}

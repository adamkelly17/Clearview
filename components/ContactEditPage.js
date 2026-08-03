import Link from 'next/link';
import { notFound } from 'next/navigation';
import { loadTradingLookups } from '@/lib/lookups';
import ContactForm from '@/components/ContactForm';

/** Editing a customer or supplier. Shared, so the two cannot drift. */
export default async function ContactEditPage({ supabase, org, features, contactId, kind }) {
  const { data: contact, error } = await supabase.rpc('contact_for_edit', {
    p_contact_id: contactId,
  });

  if (error || !contact) notFound();

  const isCustomer = kind === 'customer';
  const { accounts, vatCodes } = await loadTradingLookups(supabase, org.id, {
    ledger: isCustomer ? 'sales' : 'purchase',
  });

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <div className="eyebrow">
            {isCustomer ? 'Customer' : 'Supplier'}
            {features.accountant_mode ? ` · ${contact.code}` : ''}
          </div>
          <h1>{contact.name}</h1>
          <p>
            Changing these details affects new documents only. Anything already
            recorded keeps the details it was raised with.
          </p>
        </div>
        <Link
          href={`/${isCustomer ? 'customers' : 'suppliers'}/${contactId}`}
          className="btn btn-secondary"
        >
          Cancel
        </Link>
      </div>

      <ContactForm
        orgId={org.id}
        kind={kind}
        accounts={accounts}
        vatCodes={features.vat_enabled ? vatCodes : []}
        pro={features.accountant_mode}
        editing={contact}
      />
    </div>
  );
}

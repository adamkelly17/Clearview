import Link from 'next/link';
import { notFound } from 'next/navigation';
import { money } from '@/lib/format';
import ContactActivity from '@/components/ContactActivity';

/**
 * Shared by the customer and supplier screens. A customer and a supplier
 * differ in wording and in which buttons make sense — not in anything
 * structural — so keeping one component means the statement can never
 * drift between the two.
 */
export default async function ContactPage({ supabase, org, features, contactId, kind, searchParams }) {
  const isCustomer = kind === 'customer';
  const showAll = searchParams?.view === 'all';
  const pro = features.accountant_mode;

  const { data: contact } = await supabase
    .from('contact')
    .select('*, contact_address(*)')
    .eq('organisation_id', org.id)
    .eq('id', contactId)
    .maybeSingle();

  if (!contact) notFound();

  const { data: rows } = await supabase.rpc('contact_activity', {
    p_organisation_id: org.id,
    p_contact_id: contactId,
    p_outstanding_only: !showAll,
  });

  // Outstanding is always the true figure, whichever view is showing.
  const { data: allRows } = await supabase.rpc('contact_activity', {
    p_organisation_id: org.id,
    p_contact_id: contactId,
    p_outstanding_only: true,
  });

  const outstanding = (allRows || []).reduce(
    (s, r) =>
      s +
      (r.direction === 'debit'
        ? Number(r.outstanding_amount)
        : -Number(r.outstanding_amount)),
    0
  );

  const overdue = (allRows || []).reduce(
    (s, r) => s + (r.days_overdue > 0 && r.direction === (isCustomer ? 'debit' : 'credit')
      ? Number(r.outstanding_amount) : 0),
    0
  );

  const address = (contact.contact_address || [])[0];
  const owed = isCustomer ? outstanding : -outstanding;

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <div className="eyebrow">
            {isCustomer ? 'Customer' : 'Supplier'}
            {pro ? ` · ${contact.code}` : ''}
            {contact.cis_registered ? ' · CIS' : ''}
          </div>
          <h1>{contact.name}</h1>
          <p>
            {[address?.line_1, address?.city, address?.postcode]
              .filter(Boolean)
              .join(', ')}
            {contact.email && address ? ' · ' : ''}
            {contact.email}
          </p>
        </div>
        <div className="btn-row">
          <Link
            href={isCustomer ? '/money/receipt' : '/money/payment'}
            className="btn btn-secondary"
          >
            {isCustomer ? 'Money received' : 'Money paid out'}
          </Link>
          <Link
            href={isCustomer ? '/invoices/new' : '/bills/new'}
            className="btn btn-primary"
          >
            {isCustomer ? 'Raise an invoice' : 'Enter a bill'}
          </Link>
        </div>
      </div>

      <div className="grid grid-4">
        <div className="card"><div className="card-body">
          <div className="eyebrow">{isCustomer ? 'Owes you' : 'You owe'}</div>
          <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(owed, { currency: org.base_currency_code })}
          </div>
        </div></div>

        <div className="card"><div className="card-body">
          <div className="eyebrow">Overdue</div>
          <div
            className="num"
            style={{
              fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem',
              textAlign: 'left',
              color: overdue > 0 ? 'var(--negative)' : 'var(--ink)',
            }}
          >
            {money(overdue, { currency: org.base_currency_code })}
          </div>
        </div></div>

        <div className="card"><div className="card-body">
          <div className="eyebrow">Payment terms</div>
          <div style={{ fontSize: '1.125rem', fontWeight: 600, marginTop: '0.4375rem' }}>
            {contact.payment_terms_days} days
          </div>
        </div></div>

        <div className="card"><div className="card-body">
          <div className="eyebrow">{isCustomer ? 'Credit limit' : 'Contact'}</div>
          {isCustomer ? (
            <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
              {contact.credit_limit != null
                ? money(contact.credit_limit, { currency: org.base_currency_code })
                : '—'}
            </div>
          ) : (
            <div className="small" style={{ marginTop: '0.5rem' }}>
              {contact.phone || contact.email || '—'}
            </div>
          )}
        </div></div>
      </div>

      {isCustomer && contact.credit_limit != null && owed > Number(contact.credit_limit) && (
        <div className="notice notice-caution mt-md">
          This account is over its credit limit of{' '}
          {money(contact.credit_limit, { currency: org.base_currency_code })}.
        </div>
      )}

      <div className="card mt-lg">
        <ContactActivity
          rows={rows || []}
          showAll={showAll}
          currencyCode={org.base_currency_code}
          pro={pro}
        />
      </div>
    </div>
  );
}

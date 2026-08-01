import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireOrg } from '@/lib/org';
import Money from '@/components/Money';
import { money, shortDate } from '@/lib/format';

export const dynamic = 'force-dynamic';

const ITEM_LABELS = {
  invoice: 'Invoice',
  credit_note: 'Credit note',
  payment: 'Payment',
  payment_on_account: 'On account',
  write_off: 'Written off',
  discount: 'Discount',
  opening_balance: 'Opening balance',
  contra: 'Contra',
};

export default async function CustomerPage({ params }) {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;

  const { data: contact } = await supabase
    .from('contact')
    .select('*, contact_address(*)')
    .eq('organisation_id', org.id)
    .eq('id', params.id)
    .maybeSingle();

  if (!contact) notFound();

  const { data: statement } = await supabase.rpc('contact_statement', {
    p_organisation_id: org.id,
    p_contact_id: params.id,
  });

  const rows = statement || [];
  const balance = rows.length ? Number(rows[rows.length - 1].running_balance) : 0;
  const outstanding = rows.reduce(
    (s, r) =>
      s + (r.direction === 'debit' ? Number(r.outstanding_amount) : -Number(r.outstanding_amount)),
    0
  );
  const address = (contact.contact_address || [])[0];

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <div className="eyebrow">{contact.is_customer ? 'Customer' : 'Supplier'}{pro ? ` · ${contact.code}` : ''}</div>
          <h1>{contact.name}</h1>
          <p>
            {[address?.line_1, address?.city, address?.postcode].filter(Boolean).join(', ')}
            {contact.email && (address ? ' · ' : '') }
            {contact.email}
          </p>
        </div>
        <div className="btn-row">
          <Link href="/money/receipt" className="btn btn-secondary">Money received</Link>
          <Link href="/invoices/new" className="btn btn-primary">Raise an invoice</Link>
        </div>
      </div>

      <div className="grid grid-3">
        <div className="card"><div className="card-body">
          <div className="eyebrow">Outstanding</div>
          <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(outstanding, { currency: org.base_currency_code })}
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Payment terms</div>
          <div style={{ fontSize: '1.125rem', fontWeight: 600, marginTop: '0.375rem' }}>
            {contact.payment_terms_days} days
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Credit limit</div>
          <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {contact.credit_limit != null
              ? money(contact.credit_limit, { currency: org.base_currency_code })
              : '—'}
          </div>
        </div></div>
      </div>

      <div className="card mt-lg">
        <div className="card-head">
          <h2>Statement</h2>
          <span className="hint">Every item and every settlement, oldest first</span>
        </div>

        {rows.length === 0 ? (
          <div className="empty" style={{ padding: '2.5rem 1.5rem' }}>
            <p>Nothing recorded against this account yet.</p>
          </div>
        ) : (
          <table className="table table-flush">
            <thead>
              <tr>
                <th style={{ width: '7rem' }}>Date</th>
                <th style={{ width: '8rem' }}>Reference</th>
                <th>Type</th>
                <th style={{ width: '7rem' }}>Due</th>
                <th className="num" style={{ width: '8rem' }}>Debit</th>
                <th className="num" style={{ width: '8rem' }}>Credit</th>
                <th className="num" style={{ width: '8rem' }}>Outstanding</th>
                <th className="num" style={{ width: '8rem' }}>Balance</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.item_id}>
                  <td className="nowrap">{shortDate(r.date)}</td>
                  <td className="code">{r.reference || ''}</td>
                  <td>{ITEM_LABELS[r.item_type] || r.item_type}</td>
                  <td className="nowrap small">{r.due_date ? shortDate(r.due_date) : ''}</td>
                  <td>
                    {r.direction === 'debit' ? <Money value={r.gross_amount} /> : <span className="num" />}
                  </td>
                  <td>
                    {r.direction === 'credit' ? <Money value={r.gross_amount} /> : <span className="num" />}
                  </td>
                  <td><Money value={r.outstanding_amount} blankZero /></td>
                  <td><Money value={r.running_balance} /></td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={6}>Balance</td>
                <td><Money value={outstanding} /></td>
                <td><Money value={balance} /></td>
              </tr>
            </tfoot>
          </table>
        )}
      </div>
    </div>
  );
}

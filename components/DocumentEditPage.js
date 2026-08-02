import Link from 'next/link';
import { notFound } from 'next/navigation';
import { loadTradingLookups } from '@/lib/lookups';
import DocumentForm from '@/components/DocumentForm';
import { money, shortDate } from '@/lib/format';

/**
 * Editing a posted invoice or bill.
 *
 * The document itself is never altered. Saving voids the original,
 * reverses its journal, and posts a replacement carrying the same
 * number — so the customer's copy still matches, while an auditor can
 * see both versions and why one superseded the other.
 */
export default async function DocumentEditPage({
  supabase, org, features, documentId, ledger,
}) {
  const { data: doc, error } = await supabase.rpc('document_for_edit', {
    p_document_id: documentId,
  });

  if (error || !doc) notFound();

  if (doc.status !== 'posted') {
    return (
      <div className="page">
        <div className="page-head">
          <div>
            <h1>This cannot be edited</h1>
            <p>
              {doc.number} is {doc.status === 'void' ? 'voided' : doc.status}. A
              voided document stays on the record but cannot be changed — enter
              a new one instead.
            </p>
          </div>
          <Link href={ledger === 'sales' ? '/invoices' : '/bills'} className="btn btn-primary">
            Back
          </Link>
        </div>
      </div>
    );
  }

  const lookups = await loadTradingLookups(supabase, org.id, { ledger });
  const isSales = ledger === 'sales';

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <div className="eyebrow">Editing {doc.number}</div>
          <h1>Correct this {isSales ? 'invoice' : 'bill'}</h1>
          <p>
            Change anything you need to. The original is kept and marked as
            replaced by this correction, so the audit trail stays intact.
          </p>
        </div>
        <Link href={isSales ? '/invoices' : '/bills'} className="btn btn-secondary">
          Cancel
        </Link>
      </div>

      <div className="notice notice-caution">
        As it stands, {doc.number} is dated {shortDate(doc.date)} for{' '}
        {money(doc.gross_total, { currency: org.base_currency_code })}. Saving
        reverses that out and posts the corrected version in its place.
      </div>

      <DocumentForm
        orgId={org.id}
        docType={doc.doc_type}
        contacts={lookups.contacts}
        accounts={lookups.accounts}
        vatCodes={lookups.vatCodes}
        pro={features.accountant_mode}
        vatEnabled={features.vat_enabled}
        currencyCode={org.base_currency_code}
        editing={doc}
      />
    </div>
  );
}

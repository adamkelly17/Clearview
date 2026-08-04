import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireOrg } from '@/lib/org';
import { loadTradingLookups } from '@/lib/lookups';
import ReviewForm from './ReviewForm';
import ExtractTrigger from '../ExtractTrigger';

export const dynamic = 'force-dynamic';

export default async function CaptureReviewPage({ params }) {
  const { supabase, org, features } = await requireOrg();

  // In case this page is opened straight from a link rather than via the
  // inbox, which is where the sweep usually happens.
  await supabase.rpc('rematch_pending_extractions', { p_organisation_id: org.id });

  const { data: capture } = await supabase
    .from('capture_document')
    .select('*')
    .eq('organisation_id', org.id)
    .eq('id', params.id)
    .maybeSingle();

  if (!capture) notFound();

  const { data: extraction } = await supabase
    .from('capture_extraction')
    .select('*')
    .eq('capture_document_id', capture.id)
    .eq('is_current', true)
    .maybeSingle();

  const { data: extractionLines } = extraction
    ? await supabase
        .from('capture_extraction_line')
        .select('*')
        .eq('capture_extraction_id', extraction.id)
        .order('line_no')
    : { data: [] };

  // Signed URL so the private file can be shown without making the bucket
  // public. Ten minutes is plenty for a review and short enough that a
  // copied link is not a lasting leak.
  const { data: signed } = await supabase.storage
    .from('captures')
    .createSignedUrl(capture.storage_path, 600);

  const lookups = await loadTradingLookups(supabase, org.id, { ledger: 'purchase' });

  let duplicate = null;
  if (extraction?.duplicate_of_document_id) {
    const { data: dup } = await supabase
      .from('document')
      .select('id, number, date, gross_total')
      .eq('id', extraction.duplicate_of_document_id)
      .maybeSingle();
    if (dup) {
      duplicate = {
        ...dup,
        reason: extraction.invoice_number && dup.number
          ? 'same invoice number'
          : 'same amount around the same date',
      };
    }
  }

  if (capture.status === 'approved') {
    return (
      <div className="page">
        <div className="page-head">
          <div>
            <h1>Already posted</h1>
            <p>{capture.file_name} has been approved and is in the ledger.</p>
          </div>
          <Link href="/bills" className="btn btn-primary">See bills</Link>
        </div>
      </div>
    );
  }

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <div className="eyebrow">Review</div>
          <h1>Check this before it posts</h1>
          <p>
            Nothing has reached the ledger yet. What you approve is what gets
            posted, not what was read.
          </p>
        </div>
        <Link href="/capture" className="btn btn-secondary">Back to inbox</Link>
      </div>

      {!extraction ? (
        <div className="card">
          <div className="empty">
            <h3>Not read yet</h3>
            <p>
              {capture.status === 'failed'
                ? `Extraction failed: ${capture.status_detail || 'unknown reason'}`
                : 'This document has not been through extraction.'}
            </p>
            <div style={{ marginTop: '1rem' }}>
              <ExtractTrigger captureId={capture.id} label="Read this document" />
            </div>
          </div>
        </div>
      ) : (
        <ReviewForm
          capture={capture}
          extraction={extraction}
          extractionLines={extractionLines || []}
          fileUrl={signed?.signedUrl || ''}
          suppliers={lookups.contacts}
          accounts={lookups.accounts}
          vatCodes={lookups.vatCodes}
          duplicate={duplicate}
          pro={features.accountant_mode}
          vatEnabled={features.vat_enabled}
          currencyCode={org.base_currency_code}
        />
      )}
    </div>
  );
}

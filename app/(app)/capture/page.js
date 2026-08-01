import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { currentProvider } from '@/lib/extraction';
import Money from '@/components/Money';
import { shortDate } from '@/lib/format';
import ExtractTrigger from './ExtractTrigger';

export const dynamic = 'force-dynamic';

const STATUS = {
  uploaded:   { label: 'Waiting to be read', className: '' },
  extracting: { label: 'Reading',            className: 'pill-caution' },
  extracted:  { label: 'Needs checking',     className: 'pill-caution' },
  failed:     { label: 'Failed',             className: 'pill-negative' },
  approved:   { label: 'Posted',             className: 'pill-accent' },
  rejected:   { label: 'Discarded',          className: '' },
};

export default async function CaptureInboxPage() {
  const { supabase, org } = await requireOrg();

  const { data: captures } = await supabase
    .from('capture_document')
    .select(`
      id, file_name, mime_type, status, status_detail, created_at, ledger,
      capture_extraction ( supplier_name, invoice_number, invoice_date,
        gross_total, overall_confidence, matched_contact_id, match_method,
        duplicate_of_document_id, validation_notes, is_current )
    `)
    .eq('organisation_id', org.id)
    .neq('status', 'rejected')
    .order('created_at', { ascending: false })
    .limit(100);

  const rows = (captures || []).map((c) => ({
    ...c,
    extraction: (c.capture_extraction || []).find((e) => e.is_current) || null,
  }));

  const needsChecking = rows.filter((r) => r.status === 'extracted').length;
  const unread = rows.filter((r) => r.status === 'uploaded' || r.status === 'failed').length;

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Capture inbox</h1>
          <p>
            {needsChecking > 0
              ? `${needsChecking} document${needsChecking === 1 ? '' : 's'} read and waiting for you to check.`
              : 'Invoices you have uploaded, and what has happened to them.'}
          </p>
        </div>
        <Link href="/capture/new" className="btn btn-primary">Upload invoices</Link>
      </div>

      {currentProvider() === 'stub' && (
        <div className="notice notice-caution">
          Stub extraction is switched on, so documents are not actually being
          read. Set <span className="code">EXTRACTION_PROVIDER</span> to switch
          to a real model once you have a processor agreement in place.
        </div>
      )}

      <div className="card">
        {rows.length === 0 ? (
          <div className="empty">
            <h3>Nothing captured yet</h3>
            <p>
              Upload a supplier invoice as a PDF or a photo. It gets read, you
              check it, and it posts as a bill with the original attached.
            </p>
            <Link href="/capture/new" className="btn btn-primary mt-md">
              Upload an invoice
            </Link>
          </div>
        ) : (
          <table className="table table-flush">
            <thead>
              <tr>
                <th style={{ width: '7rem' }}>Added</th>
                <th>File</th>
                <th>Read as</th>
                <th style={{ width: '8rem' }}>Number</th>
                <th className="num" style={{ width: '8rem' }}>Total</th>
                <th style={{ width: '5rem' }}>Read</th>
                <th style={{ width: '11rem' }}>Status</th>
                <th style={{ width: '7rem' }} />
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => {
                const e = c.extraction;
                const status = STATUS[c.status] || STATUS.uploaded;
                const issues = (e?.validation_notes || []).filter((v) => v.severity === 'error').length;
                const dup = Boolean(e?.duplicate_of_document_id);
                const conf = e?.overall_confidence;

                return (
                  <tr key={c.id}>
                    <td className="nowrap small">{shortDate(c.created_at)}</td>
                    <td className="small">{c.file_name}</td>
                    <td>
                      {e?.supplier_name || <span className="muted">—</span>}
                      {e && !e.matched_contact_id && (
                        <> <span className="pill pill-negative">no match</span></>
                      )}
                      {e?.match_method === 'similar_name' && (
                        <> <span className="pill pill-caution">similar</span></>
                      )}
                    </td>
                    <td className="code small">{e?.invoice_number || ''}</td>
                    <td><Money value={e?.gross_total || 0} blankZero /></td>
                    <td>
                      {conf != null && (
                        <span
                          className="confidence-bar"
                          title={`${Math.round(conf * 100)}% average confidence`}
                        >
                          <span
                            className="confidence-fill"
                            style={{
                              width: `${Math.round(conf * 100)}%`,
                              background:
                                conf >= 0.9
                                  ? 'var(--positive)'
                                  : conf >= 0.75
                                  ? 'var(--caution)'
                                  : 'var(--negative)',
                            }}
                          />
                        </span>
                      )}
                    </td>
                    <td>
                      <span className={`pill ${dup ? 'pill-negative' : status.className}`}>
                        {dup ? 'Possible duplicate' : status.label}
                      </span>
                      {issues > 0 && !dup && (
                        <> <span className="pill pill-negative">{issues}</span></>
                      )}
                    </td>
                    <td>
                      {c.status === 'extracted' && (
                        <Link href={`/capture/${c.id}`} className="btn btn-secondary btn-sm">
                          Check
                        </Link>
                      )}
                      {(c.status === 'uploaded' || c.status === 'failed') && (
                        <ExtractTrigger captureId={c.id} label="Read" small />
                      )}
                      {c.status === 'approved' && (
                        <Link href="/bills" className="small">Posted</Link>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>

      {unread > 0 && (
        <p className="hint mt-md">
          {unread} document{unread === 1 ? '' : 's'} not yet read.
        </p>
      )}
    </div>
  );
}

import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { currentProvider } from '@/lib/extraction';
import Money from '@/components/Money';
import { shortDate } from '@/lib/format';
import ExtractTrigger from './ExtractTrigger';
import QueueRunner from './QueueRunner';

export const dynamic = 'force-dynamic';

const STATUS = {
  uploaded:   { label: 'Waiting to be read', className: '' },
  extracting: { label: 'Reading now',        className: 'pill-caution' },
  extracted:  { label: 'Needs checking',     className: 'pill-caution' },
  failed:     { label: 'Failed',             className: 'pill-negative' },
  approved:   { label: 'Posted',             className: 'pill-accent' },
  rejected:   { label: 'Discarded',          className: '' },
};

export default async function CaptureInboxPage({ searchParams }) {
  const { supabase, org } = await requireOrg();
  const view = searchParams?.view === 'archive' ? 'archive' : 'open';

  /* Anything left mid-read by a closed tab goes back in the queue before
     the list is drawn, so a stuck document heals itself rather than
     sitting on "Reading" until someone notices. */
  await supabase.rpc('reclaim_stuck_captures', {
    p_organisation_id: org.id,
    p_older_than: '5 minutes',
  });

  /* A supplier added from one invoice should resolve every other invoice
     waiting from them. Matching used to run once at extraction and never
     again, so the second invoice from a new supplier still offered to add
     them — and you ended up with two. */
  await supabase.rpc('rematch_pending_extractions', { p_organisation_id: org.id });

  const [{ data: queue }, { data: counts }] = await Promise.all([
    supabase.rpc('capture_queue_status', { p_organisation_id: org.id }),
    supabase.rpc('capture_counts', { p_organisation_id: org.id }),
  ]);

  const { data: captures } = await supabase
    .from('capture_document')
    .select(`
      id, file_name, mime_type, status, status_detail, created_at, ledger,
      capture_extraction ( supplier_name, invoice_number, invoice_date,
        gross_total, overall_confidence, matched_contact_id, match_method,
        duplicate_of_document_id, validation_notes, is_current )
    `)
    .eq('organisation_id', org.id)
    .in(
      'status',
      view === 'archive'
        ? ['approved', 'rejected']
        : ['uploaded', 'extracting', 'extracted', 'failed']
    )
    .order('created_at', { ascending: false })
    .limit(200);

  const rows = (captures || []).map((c) => ({
    ...c,
    extraction: (c.capture_extraction || []).find((e) => e.is_current) || null,
  }));

  const needsChecking = rows.filter((r) => r.status === 'extracted').length;

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Capture inbox</h1>
          <p>
            {view === 'archive'
              ? 'Invoices already dealt with. The original document stays attached to whatever it became.'
              : needsChecking > 0
              ? `${needsChecking} document${needsChecking === 1 ? '' : 's'} read and waiting for you to check.`
              : 'Invoices waiting to be read or checked.'}
          </p>
        </div>
        <Link href="/capture/new" className="btn btn-primary">Upload invoices</Link>
      </div>

      {view === 'open' && (
        <QueueRunner
          orgId={org.id}
          waiting={queue?.waiting || 0}
          reading={queue?.reading || 0}
        />
      )}

      {currentProvider() === 'stub' && (
        <div className="notice notice-caution">
          Stub extraction is switched on, so documents are not actually being
          read. Set <span className="code">EXTRACTION_PROVIDER</span> to switch
          to a real model once you have a processor agreement in place.
        </div>
      )}

      <div className="card">
        <div className="card-head">
          <div className="btn-row">
            <Link
              href="/capture"
              className={`btn btn-sm ${view === 'open' ? 'btn-primary' : 'btn-ghost'}`}
            >
              To deal with{Number(counts?.open) ? ` (${counts.open})` : ''}
            </Link>
            <Link
              href="/capture?view=archive"
              className={`btn btn-sm ${view === 'archive' ? 'btn-primary' : 'btn-ghost'}`}
            >
              Archive{Number(counts?.archived) ? ` (${counts.archived})` : ''}
            </Link>
          </div>
          {view === 'archive' && (
            <span className="hint">
              {counts?.posted || 0} posted, {counts?.discarded || 0} discarded
            </span>
          )}
        </div>

        {rows.length === 0 ? (
          <div className="empty">
            {view === 'archive' ? (
              <>
                <h3>Nothing in the archive</h3>
                <p>
                  Invoices you have posted or discarded end up here, with the
                  original document kept alongside.
                </p>
              </>
            ) : (
              <>
                <h3>Nothing to deal with</h3>
                <p>
                  Upload a supplier invoice as a PDF or a photo. It gets read, you
                  check it, and it posts as a bill with the original attached.
                </p>
                <Link href="/capture/new" className="btn btn-primary mt-md">
                  Upload an invoice
                </Link>
              </>
            )}
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
                    <td className="actions">
                      {c.status === 'extracted' && (
                        <Link href={`/capture/${c.id}`} className="btn btn-primary btn-sm">
                          Check it
                        </Link>
                      )}
                      {(c.status === 'uploaded' || c.status === 'failed'
                        || c.status === 'extracting') && (
                        <ExtractTrigger
                          captureId={c.id}
                          label={c.status === 'failed' ? 'Try again' : 'Read'}
                          small
                        />
                      )}
                      {c.status === 'approved' && (
                        <Link href="/bills" className="btn btn-open btn-sm">Posted</Link>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>

      {Number(queue?.failed) > 0 && (
        <p className="hint mt-md">
          {queue.failed} document{Number(queue.failed) === 1 ? '' : 's'} could not be
          read after several attempts. Try again individually, or enter{' '}
          {Number(queue.failed) === 1 ? 'it' : 'them'} by hand.
        </p>
      )}
    </div>
  );
}

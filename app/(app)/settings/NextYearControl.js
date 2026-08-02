'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError, shortDate } from '@/lib/format';

/**
 * Adding the next financial year.
 *
 * Separate from closing the old one, and deliberately so. Adding the year
 * just creates the periods so posting can continue; closing rolls the
 * profit to reserves and locks everything, which happens months later
 * once the accounts are agreed. Businesses trade through the gap.
 */
export default function NextYearControl({ preview, canEdit }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [done, setDone] = useState(null);

  if (!preview?.available || !canEdit) return null;

  async function create() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { data, error } = await supabase.rpc('create_next_fiscal_year', {
      p_organisation_id: preview.organisation_id,
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    setDone(data);
    router.refresh();
  }

  if (done) {
    return (
      <div className="notice notice-info" style={{ margin: '0 1.25rem 1.25rem' }}>
        Financial year {shortDate(done.start_date)} to {shortDate(done.end_date)}{' '}
        created, with {done.periods} monthly periods. You can post into it now.
      </div>
    );
  }

  const overdue = preview.overdue;
  const soon = !overdue && preview.days_remaining <= 60;

  return (
    <div className="card-body" style={{ borderTop: '1px solid var(--line)' }}>
      {error && <div className="notice notice-error">{error}</div>}

      <div className="row row-between" style={{ gap: '1rem', flexWrap: 'wrap' }}>
        <div style={{ flex: 1, minWidth: '18rem' }}>
          <h3 style={{ marginBottom: '0.25rem' }}>Add the next financial year</h3>
          <p className="hint" style={{ margin: 0 }}>
            {shortDate(preview.start_date)} to {shortDate(preview.end_date)} —{' '}
            {preview.periods} monthly periods, running straight on from the
            current year.
          </p>
        </div>
        <button className="btn btn-primary" onClick={create} disabled={busy}>
          {busy ? 'Creating…' : 'Add it'}
        </button>
      </div>

      {(overdue || soon) && (
        <div className={`notice ${overdue ? 'notice-caution' : 'notice-info'}`} style={{ marginTop: '0.875rem', marginBottom: 0 }}>
          {overdue ? (
            <>
              Your last financial year ended on{' '}
              <strong>{shortDate(preview.previous_end)}</strong>. Nothing can be
              posted after that date until the next year exists.
            </>
          ) : (
            <>
              The current year ends in {preview.days_remaining} days. Adding the
              next one now saves being stopped mid-entry later.
            </>
          )}
        </div>
      )}

      <p className="hint" style={{ marginTop: '0.875rem', marginBottom: 0 }}>
        This only creates the periods so you can carry on posting. Closing last
        year — rolling the profit into reserves and locking it — is a separate
        step, and comes later once the accounts are agreed.
      </p>
    </div>
  );
}

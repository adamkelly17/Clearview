'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';

/**
 * The reading queue.
 *
 * Claims one document at a time from the database with SKIP LOCKED, so two
 * tabs cannot grab the same one, and reads it. If you navigate away it
 * stops — but nothing is lost, because every document is already uploaded
 * and its status tells the next run exactly where to carry on.
 *
 * That is the important difference from before. The old version did the
 * uploading and the reading in one client-side loop, so leaving the page
 * meant files it had not reached yet were never uploaded at all.
 *
 * True background processing needs a server-side cron — see
 * `app/api/capture/process/route.js`, which is written and ready but needs
 * a Vercel plan that allows frequent cron jobs.
 */
export default function QueueRunner({ orgId, waiting, reading }) {
  const router = useRouter();
  const [running, setRunning] = useState(false);
  const [donecount, setDone] = useState(0);
  const [failed, setFailed] = useState(0);
  const [error, setError] = useState(null);
  const stop = useRef(false);

  const total = Number(waiting) + Number(reading);

  useEffect(() => {
    if (!running) return;
    const warn = (e) => {
      e.preventDefault();
      e.returnValue = '';
    };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [running]);

  async function run() {
    setRunning(true);
    setError(null);
    setDone(0);
    setFailed(0);
    stop.current = false;

    const supabase = createClient();

    // No fixed count: keep claiming until the queue is empty, so anything
    // uploaded while this is running gets picked up too.
    for (let guard = 0; guard < 500 && !stop.current; guard += 1) {
      const { data: id, error: claimError } = await supabase.rpc('claim_next_capture', {
        p_organisation_id: orgId,
      });

      if (claimError) {
        setError(readableError(claimError));
        break;
      }
      if (!id) break;

      try {
        const res = await fetch('/api/capture/extract', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ capture_id: id }),
        });
        if (!res.ok) {
          const body = await res.json().catch(() => ({}));
          throw new Error(body.error || 'Reading failed');
        }
        setDone((n) => n + 1);
      } catch (e) {
        // One bad document must not stop the rest. The route has already
        // marked it failed, and it can be retried on its own.
        setFailed((n) => n + 1);
      }

      router.refresh();
    }

    setRunning(false);
    router.refresh();
  }

  if (total === 0 && !running && donecount === 0 && failed === 0) return null;

  return (
    <div className={`notice ${running ? 'notice-info' : total > 0 ? 'notice-caution' : 'notice-info'}`}>
      {error && <div style={{ marginBottom: '0.5rem' }}>{error}</div>}

      {running ? (
        <>
          <strong>Reading…</strong> {donecount} done
          {failed > 0 && `, ${failed} failed`}. You can leave this page — anything
          not yet read stays in the queue and picks up where it left off.
          <div className="btn-row" style={{ marginTop: '0.75rem' }}>
            <button
              className="btn btn-secondary btn-sm"
              onClick={() => { stop.current = true; }}
            >
              Stop after this one
            </button>
          </div>
        </>
      ) : total > 0 ? (
        <>
          <strong>
            {total} document{total === 1 ? '' : 's'} waiting to be read.
          </strong>{' '}
          Reading takes a few seconds each.
          {donecount > 0 && ` ${donecount} done so far.`}
          {failed > 0 && ` ${failed} could not be read — retry those individually.`}
          <div className="btn-row" style={{ marginTop: '0.75rem' }}>
            <button className="btn btn-primary btn-sm" onClick={run}>
              Read {total === 1 ? 'it' : 'them all'}
            </button>
          </div>
        </>
      ) : (
        <>
          <strong>Finished.</strong> {donecount} read
          {failed > 0 && `, ${failed} failed`}. Anything needing checking is listed
          below.
        </>
      )}
    </div>
  );
}

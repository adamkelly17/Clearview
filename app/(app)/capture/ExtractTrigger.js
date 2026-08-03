'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';

/** Kicks off extraction for a document that has not been read yet. */
export default function ExtractTrigger({ captureId, label = 'Read it', small = false }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function run() {
    setBusy(true);
    setError(null);

    try {
      // Reset first, so a document stuck on "Reading" can be retried.
      const supabase = createClient();
      await supabase.rpc('retry_capture', { p_capture_id: captureId });

      const res = await fetch('/api/capture/extract', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ capture_id: captureId }),
      });

      const body = await res.json();
      if (!res.ok) throw new Error(body.error || 'Extraction failed');

      router.refresh();
    } catch (e) {
      setError(String(e.message || e));
    } finally {
      setBusy(false);
    }
  }

  if (error) {
    return (
      <span className="small" style={{ color: 'var(--negative)' }}>
        {error}{' '}
        <button className="btn btn-ghost btn-sm" onClick={run}>Try again</button>
      </span>
    );
  }

  return (
    <button
      className={`btn btn-primary ${small ? 'btn-sm' : ''}`}
      onClick={run}
      disabled={busy}
    >
      {busy ? 'Reading…' : label}
    </button>
  );
}

'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError, today } from '@/lib/format';

export default function ReverseButton({ journalId, description }) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function reverse() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc('reverse_journal', {
      p_journal_id: journalId,
      p_date: today(),
      p_reason: `Reversal of ${description}`,
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    setConfirming(false);
    router.refresh();
  }

  if (error) {
    return (
      <span className="small" style={{ color: 'var(--negative)' }}>
        {error}
      </span>
    );
  }

  if (!confirming) {
    return (
      <button className="btn btn-open btn-sm" onClick={() => setConfirming(true)}>
        Reverse
      </button>
    );
  }

  return (
    <span className="row" style={{ gap: '0.375rem' }}>
      <button className="btn btn-danger btn-sm" onClick={reverse} disabled={busy}>
        {busy ? '…' : 'Confirm'}
      </button>
      <button
        className="btn btn-ghost btn-sm"
        onClick={() => setConfirming(false)}
        disabled={busy}
      >
        Cancel
      </button>
    </span>
  );
}

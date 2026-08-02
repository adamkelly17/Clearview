'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { money, readableError } from '@/lib/format';

/**
 * Taking a payment back off an invoice.
 *
 * Nothing in the nominal ledger moves. An allocation only records which
 * payment answers to which invoice — the money moved when the payment was
 * posted, and it stays moved. Both sides simply go back to outstanding.
 */
export default function UnallocateButton({ itemId, allocated }) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function unallocate() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc('unallocate_item', { p_ledger_item_id: itemId });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    setConfirming(false);
    router.refresh();
  }

  if (error) {
    return <span className="small" style={{ color: 'var(--negative)' }}>{error}</span>;
  }

  if (!confirming) {
    return (
      <button className="btn btn-open btn-sm" onClick={() => setConfirming(true)}>
        Unallocate
      </button>
    );
  }

  return (
    <div className="void-panel">
      <div className="small" style={{ fontWeight: 600, marginBottom: '0.375rem' }}>
        Take the payment off?
      </div>
      <p className="hint" style={{ marginBottom: '0.75rem' }}>
        {money(allocated)} will come off this, and the payment goes back to being
        unallocated. No money moves — both just return to outstanding.
      </p>
      <div className="btn-row">
        <button className="btn btn-ghost btn-sm" onClick={() => setConfirming(false)} disabled={busy}>
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-primary btn-sm" onClick={unallocate} disabled={busy}>
          {busy ? 'Working…' : 'Unallocate'}
        </button>
      </div>
    </div>
  );
}

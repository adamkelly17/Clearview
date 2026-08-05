'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';

/**
 * Putting a bank line back in the "to deal with" list.
 *
 * Where a transaction was created from the line, the undo reverses it —
 * both entries stay on the record. Where the line was only matched to
 * something that already existed, the transaction is left alone and only
 * the link is broken.
 *
 * The confirmation says which of those is about to happen, because they
 * are quite different things.
 */
export default function UndoButton({ lineId, createdSomething }) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function undo() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc('undo_statement_line', { p_line_id: lineId });

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
        Undo
      </button>
    );
  }

  return (
    <div className="void-panel">
      <div className="small" style={{ fontWeight: 600, marginBottom: '0.375rem' }}>
        Put this back?
      </div>
      <p className="hint" style={{ marginBottom: '0.75rem' }}>
        {createdSomething
          ? 'The transaction this created will be reversed on the same date, so the month is left as it was. Both entries stay in the audit trail but neither counts as waiting to be reconciled.'
          : 'The transaction it was matched to is left alone — only the link is broken.'}
      </p>
      <div className="btn-row">
        <button className="btn btn-ghost btn-sm" onClick={() => setConfirming(false)} disabled={busy}>
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-primary btn-sm" onClick={undo} disabled={busy}>
          {busy ? 'Undoing…' : 'Undo it'}
        </button>
      </div>
    </div>
  );
}

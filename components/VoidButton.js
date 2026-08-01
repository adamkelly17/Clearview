'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';

const REASONS = [
  'Entered twice',
  'Wrong supplier or customer',
  'Wrong amount',
  'Never actually happened',
  'Other',
];

/**
 * Voiding, not deleting.
 *
 * The document stays. Its journal is reversed, and both entries remain in
 * the transaction list for ever, so anyone auditing the books can see
 * that something was entered and then taken back out.
 */
export default function VoidButton({ documentId, number, label = 'Void' }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState(REASONS[0]);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function confirm() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc('void_document', {
      p_document_id: documentId,
      p_reason: reason === 'Other' ? note.trim() || 'No reason given' : reason,
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    setOpen(false);
    router.refresh();
  }

  if (!open) {
    return (
      <button className="btn btn-ghost btn-sm" onClick={() => setOpen(true)}>
        {label}
      </button>
    );
  }

  return (
    <div className="void-panel">
      <div className="small" style={{ fontWeight: 600, marginBottom: '0.5rem' }}>
        Void {number}?
      </div>

      {error && (
        <div className="notice notice-error" style={{ marginBottom: '0.625rem' }}>
          {error}
        </div>
      )}

      <p className="hint" style={{ marginBottom: '0.625rem' }}>
        This reverses it out of the accounts. Both the original and the
        reversal stay on the record — nothing is deleted.
      </p>

      <select
        className="select"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        style={{ marginBottom: '0.5rem' }}
      >
        {REASONS.map((r) => (
          <option key={r} value={r}>{r}</option>
        ))}
      </select>

      {reason === 'Other' && (
        <input
          className="input"
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="What happened?"
          style={{ marginBottom: '0.5rem' }}
        />
      )}

      <div className="btn-row">
        <button className="btn btn-ghost btn-sm" onClick={() => setOpen(false)} disabled={busy}>
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-danger btn-sm" onClick={confirm} disabled={busy}>
          {busy ? 'Voiding…' : 'Void it'}
        </button>
      </div>
    </div>
  );
}

'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError, shortDate } from '@/lib/format';

/**
 * Changing a financial year end after the books have started.
 *
 * Previews first. Extending is harmless — it adds the missing months.
 * Shortening is not, if anything has been posted into the months that
 * would disappear, so the preview says so before the button is live
 * rather than surfacing it as an error afterwards.
 */
export default function YearEndControl({ year, canEdit }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(year?.end_date || '');
  const [preview, setPreview] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [done, setDone] = useState(null);

  if (!year) return null;

  async function check(newDate) {
    setDate(newDate);
    setPreview(null);
    setError(null);

    if (!newDate || newDate === year.end_date) return;

    const supabase = createClient();
    const { data, error } = await supabase.rpc('preview_year_end_change', {
      p_fiscal_year_id: year.id,
      p_new_end_date: newDate,
    });

    if (error) {
      setError(readableError(error));
      return;
    }
    setPreview(data);
  }

  async function apply() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { data, error } = await supabase.rpc('change_fiscal_year_end', {
      p_fiscal_year_id: year.id,
      p_new_end_date: date,
      p_update_pattern: true,
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    setDone(data);
    setPreview(null);
    router.refresh();
  }

  if (!canEdit) return null;

  if (!open) {
    return (
      <button className="btn btn-open btn-sm" onClick={() => setOpen(true)}>
        Change year end
      </button>
    );
  }

  return (
    <div className="card-body" style={{ borderTop: '1px solid var(--line)' }}>
      <h3 style={{ marginBottom: '0.5rem' }}>Change the year end</h3>
      <p className="hint" style={{ marginBottom: '0.875rem' }}>
        The current year runs from {shortDate(year.start_date)} to{' '}
        {shortDate(year.end_date)}. Extending adds the missing months;
        shortening removes them, provided nothing has been posted into them.
      </p>

      {error && <div className="notice notice-error">{error}</div>}

      {done && (
        <div className="notice notice-info">
          Year end moved to <strong>{shortDate(done.to)}</strong>.
          {done.periods_added > 0 && ` ${done.periods_added} month${done.periods_added === 1 ? '' : 's'} added.`}
          {done.periods_removed > 0 && ` ${done.periods_removed} month${done.periods_removed === 1 ? '' : 's'} removed.`}
          {' '}Future years will follow the new date.
        </div>
      )}

      <label className="field" style={{ maxWidth: '16rem' }}>
        <span className="label">New year end</span>
        <input
          className="input"
          type="date"
          value={date}
          onChange={(e) => check(e.target.value)}
        />
      </label>

      {preview && (
        <div
          className={`notice ${preview.valid ? 'notice-info' : 'notice-error'}`}
        >
          {preview.valid ? (
            <>
              That would {preview.direction} the year to about{' '}
              <strong>{preview.months} months</strong>, split into{' '}
              {preview.periods} periods.
            </>
          ) : (
            preview.message
          )}
        </div>
      )}

      <div className="btn-row">
        <button
          className="btn btn-secondary btn-sm"
          onClick={() => {
            setOpen(false);
            setPreview(null);
            setDone(null);
            setDate(year.end_date);
          }}
          disabled={busy}
        >
          {done ? 'Close' : 'Cancel'}
        </button>
        <div className="spacer" />
        <button
          className="btn btn-primary btn-sm"
          onClick={apply}
          disabled={busy || !preview?.valid}
        >
          {busy ? 'Changing…' : 'Change it'}
        </button>
      </div>
    </div>
  );
}

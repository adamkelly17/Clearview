'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError, shortDate } from '@/lib/format';

const NEXT_STATUS = { open: 'closed', closed: 'open' };

export default function PeriodList({ periods, canEdit }) {
  const router = useRouter();
  const [busy, setBusy] = useState(null);
  const [error, setError] = useState(null);

  async function setStatus(period, status) {
    setBusy(period.id);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase
      .from('period')
      .update({ status })
      .eq('id', period.id);

    setBusy(null);

    if (error) {
      setError(readableError(error));
      return;
    }

    router.refresh();
  }

  return (
    <>
      {error && (
        <div className="card-body" style={{ paddingBottom: 0 }}>
          <div className="notice notice-error">{error}</div>
        </div>
      )}

      <table className="table table-flush">
        <thead>
          <tr>
            <th>Period</th>
            <th>From</th>
            <th>To</th>
            <th>Status</th>
            <th style={{ width: '7rem' }} />
          </tr>
        </thead>
        <tbody>
          {periods.map((p) => (
            <tr key={p.id}>
              <td>{p.name}</td>
              <td>{shortDate(p.start_date)}</td>
              <td>{shortDate(p.end_date)}</td>
              <td>
                <span
                  className={`pill ${
                    p.status === 'open'
                      ? 'pill-accent'
                      : p.status === 'locked'
                      ? 'pill-negative'
                      : ''
                  }`}
                >
                  {p.status === 'open' ? 'Open' : p.status === 'closed' ? 'Closed' : 'Locked'}
                </span>
              </td>
              <td>
                {canEdit && p.status !== 'locked' && (
                  <button
                    className="btn btn-ghost btn-sm"
                    disabled={busy === p.id}
                    onClick={() => setStatus(p, NEXT_STATUS[p.status])}
                  >
                    {p.status === 'open' ? 'Close' : 'Reopen'}
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="card-body" style={{ paddingTop: '0.75rem' }}>
        <p className="hint">
          Closing a period stops anything new being recorded in it. A locked
          period can never be reopened — that happens at year end.
        </p>
      </div>
    </>
  );
}

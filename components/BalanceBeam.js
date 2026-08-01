'use client';

import { money } from '@/lib/format';

/**
 * The balance beam.
 *
 * Two bars grow in from the outside edges in proportion to the money
 * in and the money out. When the two agree they meet in the middle and
 * turn green. When they do not, the gap between them is the error, and
 * it is labelled in plain words rather than "out of balance by".
 *
 * The point is that someone who has never heard of double entry can
 * still see, at a glance, that a transaction is not finished.
 */
export default function BalanceBeam({ debit, credit, pro = false, currencyCode = null }) {
  const d = Number(debit || 0);
  const c = Number(credit || 0);
  const difference = Math.abs(d - c);
  const balanced = difference < 0.005 && d > 0;
  const empty = d === 0 && c === 0;

  const larger = Math.max(d, c, 0.01);
  const leftPct = Math.min(50, (d / larger) * 50);
  const rightPct = Math.min(50, (c / larger) * 50);

  const message = () => {
    if (empty) return 'Enter the two sides of the transaction';
    if (balanced) return 'Balanced and ready to record';
    if (d > c) return pro ? 'More debits than credits' : 'More going out than coming in';
    return pro ? 'More credits than debits' : 'More coming in than going out';
  };

  return (
    <div className={`beam ${balanced ? 'beam-balanced' : ''}`}>
      <div className="beam-figures">
        <div className="beam-side">
          <span className="beam-label">{pro ? 'Debits' : 'Where it went'}</span>
          <span className="beam-value">{money(d, { currency: currencyCode })}</span>
        </div>
        <div className="beam-side beam-side-right">
          <span className="beam-label">{pro ? 'Credits' : 'Where it came from'}</span>
          <span className="beam-value">{money(c, { currency: currencyCode })}</span>
        </div>
      </div>

      <div className="beam-track" role="presentation">
        <div className="beam-fill beam-fill-left" style={{ right: `${100 - leftPct}%` }} />
        <div className="beam-fill beam-fill-right" style={{ left: `${100 - rightPct}%` }} />
      </div>

      <div className="beam-status">
        <span className="beam-message">{message()}</span>
        {!balanced && !empty && (
          <span className="beam-difference">
            {money(difference, { currency: currencyCode })} apart
          </span>
        )}
      </div>
    </div>
  );
}

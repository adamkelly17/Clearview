import { money } from '@/lib/format';

/** A figure in the ledger's monospace, right aligned, quiet when nil. */
export default function Money({ value, blankZero = false, currency = null, className = '' }) {
  const n = Number(value || 0);
  const nil = n === 0;

  if (blankZero && nil) return <span className="num" />;

  return (
    <span className={`num ${nil ? 'num-nil' : ''} ${className}`.trim()}>
      {money(n, { currency })}
    </span>
  );
}

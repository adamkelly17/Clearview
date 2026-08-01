/**
 * Clearview.
 *
 * The mark is a horizon seen through a lens: a circle, cut by a single
 * rule, with the ground below it filled.
 *
 * Two readings, both wanted. It is a clear view — an unobstructed
 * horizon, nothing hidden. And it is a ruled line across a page, which
 * is what a ledger is. The rule sits slightly above centre so the mark
 * has a settled, grounded weight rather than reading as a bisected
 * circle.
 *
 * It survives being 16 pixels wide, which is most of the job.
 */

export function LogoMark({ size = 28, className = '' }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      role="img"
      aria-label="Clearview"
    >
      <circle cx="16" cy="16" r="15" fill="var(--accent, #0B5D4E)" />

      {/* The ground below the horizon, clipped to the circle. */}
      <path
        d="M1 18a15 15 0 0 0 30 0Z"
        fill="var(--paper, #FBFAF9)"
        fillOpacity="0.22"
      />

      {/* The horizon itself. */}
      <rect x="4" y="17" width="24" height="2" rx="1" fill="var(--paper, #FBFAF9)" />

      {/* A second, shorter rule — the page beneath, and it stops the mark
          reading as a single flat line at small sizes. */}
      <rect
        x="9"
        y="11.5"
        width="14"
        height="1.75"
        rx="0.875"
        fill="var(--paper, #FBFAF9)"
        fillOpacity="0.55"
      />
    </svg>
  );
}

export function Wordmark({ size = 28, className = '', showMark = true, subtitle = null }) {
  return (
    <div className={`brand ${className}`.trim()}>
      {showMark && <LogoMark size={size} />}
      <div className="brand-text">
        <span className="brand-name" style={{ fontSize: size * 0.62 }}>
          Clearview
        </span>
        {subtitle && <span className="brand-subtitle">{subtitle}</span>}
      </div>
    </div>
  );
}

export default LogoMark;

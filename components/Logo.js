/* eslint-disable @next/next/no-img-element */

/**
 * The Clearview marks.
 *
 * Plain <img> rather than next/image on purpose: these are small, fixed
 * size, and needed on the very first paint of the sign-in page. Routing
 * a 28px logo through the image optimiser costs a round trip and buys
 * nothing.
 *
 * Both carry transparency, so they sit on paper without a white box
 * around them. The navy mark disappears against a navy panel, so a
 * reversed pair exists for that — pass `reversed`.
 */

export function LogoMark({ size = 28, className = '', reversed = false }) {
  return (
    <img
      src={reversed ? '/clearview-mark-reversed.png' : '/clearview-mark.png'}
      alt=""
      width={size}
      height={size}
      className={className}
      style={{ display: 'block', width: size, height: size }}
    />
  );
}

export function Wordmark({ height = 44, className = '', reversed = false }) {
  return (
    <img
      src={reversed ? '/clearview-logo-reversed.png' : '/clearview-logo.png'}
      alt="Clearview"
      height={height}
      className={className}
      style={{ display: 'block', height, width: 'auto' }}
    />
  );
}

export default LogoMark;

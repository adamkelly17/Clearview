/* eslint-disable @next/next/no-img-element */

/**
 * The Clearview marks.
 *
 * Plain <img> rather than next/image on purpose: these are small, fixed
 * size, and needed on the very first paint of the sign-in page. Routing
 * a 28px logo through the image optimiser costs a round trip and buys
 * nothing.
 *
 * Both files carry transparency, so they sit on paper or on a coloured
 * panel without a white box around them.
 */

export function LogoMark({ size = 28, className = '' }) {
  return (
    <img
      src="/clearview-mark.png"
      alt=""
      width={size}
      height={size}
      className={className}
      style={{ display: 'block', width: size, height: size }}
    />
  );
}

export function Wordmark({ height = 44, className = '' }) {
  return (
    <img
      src="/clearview-logo.png"
      alt="Clearview"
      height={height}
      className={className}
      style={{ display: 'block', height, width: 'auto' }}
    />
  );
}

export default LogoMark;

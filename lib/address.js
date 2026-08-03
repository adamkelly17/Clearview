/**
 * Splitting a printed address into fields.
 *
 * Extraction returns an address as one blob, because that is how it is
 * printed. The contact record wants it in parts. There is no reliable
 * grammar for a UK address, but there are two things that can be relied
 * on: the postcode has a shape, and the country and postcode sit at the
 * end.
 *
 * So the postcode is found by pattern, the country is matched against a
 * short list, and what remains is split on commas with the last piece
 * taken as the town. Anything this gets wrong is visible and editable in
 * the form before it is saved, which is the point of a pre-filled form
 * rather than an automatic one.
 */

// Covers the real UK formats including the London single-digit districts
// and the Girobank oddity.
const POSTCODE =
  /\b(GIR ?0AA|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2})\b/i;

const COUNTRIES = [
  'United Kingdom', 'England', 'Scotland', 'Wales', 'Northern Ireland',
  'Ireland', 'Isle of Man', 'Jersey', 'Guernsey', 'GB', 'UK',
];

/** Counties are dropped rather than guessed at — they are optional anyway. */
export function parseAddress(text) {
  const empty = {
    address_line_1: '', address_line_2: '', city: '', county: '',
    postcode: '', country: '',
  };

  if (!text) return empty;

  // Newlines and commas both separate parts on a printed address.
  let parts = String(text)
    .split(/[\n,]+/)
    .map((p) => p.trim())
    .filter(Boolean);

  if (!parts.length) return empty;

  const result = { ...empty };

  // Country, if the last part is one.
  const last = parts[parts.length - 1];
  const country = COUNTRIES.find((c) => c.toLowerCase() === last.toLowerCase());
  if (country) {
    result.country = country === 'GB' || country === 'UK' ? 'United Kingdom' : country;
    parts = parts.slice(0, -1);
  }

  // Postcode, wherever it appears. Usually the last part, but often
  // tacked onto the town: "Reading RG1 2AA".
  for (let i = parts.length - 1; i >= 0; i -= 1) {
    const match = parts[i].match(POSTCODE);
    if (!match) continue;

    result.postcode = match[0].toUpperCase().replace(/\s+/g, ' ');

    const remainder = parts[i].replace(POSTCODE, '').trim().replace(/[,\s]+$/, '');
    if (remainder) parts[i] = remainder;
    else parts = parts.filter((_, j) => j !== i);
    break;
  }

  if (!parts.length) return result;

  // The last remaining part is the town.
  if (parts.length > 1) {
    result.city = parts[parts.length - 1];
    parts = parts.slice(0, -1);
  }

  result.address_line_1 = parts[0] || '';
  result.address_line_2 = parts.slice(1).join(', ');

  return result;
}

/**
 * A short trading name from a legal one, for the name field.
 *
 * "Decathlon Reading" needs no help, but "Amazon EU S.à r.l., UK Branch"
 * is not what anyone wants to see in a supplier list. Mirrors the
 * normalisation used for matching, but keeps the original casing.
 */
const LEGAL_NOISE = new Set([
  'ltd', 'limited', 'plc', 'llp', 'llc', 'inc', 'incorporated', 'corp',
  'corporation', 'gmbh', 'bv', 'nv', 'ag', 'sarl', 'sa', 'spa', 'srl',
  'pty', 'oy', 'ab', 'as', 'aps', 'kg', 'ug', 'branch',
  'uk', 'gb', 'eu',
]);

/* Multi-token legal forms have to go before tokenising, or "S.à r.l."
   breaks into fragments and leaves "r.l." behind looking like a word. */
const LEGAL_PHRASES = [
  /\bs\.?\s?[àa]\.?\s?r\.?\s?l\.?/gi,   // S.à r.l. and its variants
  /\bs\.?a\.?r\.?l\.?\b/gi,
  /\bg\.?m\.?b\.?h\.?\b/gi,
  /\bp\.?l\.?c\.?\b/gi,
  /\bl\.?l\.?[pc]\.?\b/gi,
];

export function tidyContactName(name) {
  const raw = String(name || '').trim();
  if (!raw) return '';

  // Anything after a comma is usually a qualifier, not the name.
  let head = raw.split(',')[0].trim();

  for (const phrase of LEGAL_PHRASES) head = head.replace(phrase, ' ');
  head = head.replace(/\s+/g, ' ').trim();

  const words = head.split(/\s+/).filter((w, i) => {
    const token = w.replace(/[^A-Za-z]/g, '').toLowerCase();
    // An ampersand carries no letters but is part of the name —
    // "J Smith & Sons" reads wrong without it.
    if (!token) return /^[&+]$/.test(w);
    if (LEGAL_NOISE.has(token)) return false;
    // A single letter at the front is an initial — "K Wells Carpentry"
    // keeps its K. Elsewhere it is a leftover fragment.
    if (token.length === 1) return i === 0;
    return true;
  });

  // If stripping left nothing sensible, keep what was printed.
  return words.length ? words.join(' ') : raw.split(',')[0].trim() || raw;
}

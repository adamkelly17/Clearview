const SYMBOLS = {
  GBP: '£', EUR: '€', USD: '$', AUD: 'A$', CAD: 'C$', CHF: 'CHF',
  JPY: '¥', NZD: 'NZ$', SEK: 'kr', NOK: 'kr', DKK: 'kr',
  PLN: 'zł', ZAR: 'R', INR: '₹', AED: 'AED',
};

export function symbolFor(code) {
  return SYMBOLS[code] || '';
}

/** 1234.5 -> "1,234.50". Blank when nil, so columns of zeroes stay quiet. */
export function money(value, { blankZero = false, currency = null } = {}) {
  const n = Number(value || 0);
  if (blankZero && n === 0) return '';
  const formatted = Math.abs(n).toLocaleString('en-GB', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  const sign = n < 0 ? '-' : '';
  return `${sign}${currency ? symbolFor(currency) : ''}${formatted}`;
}

/** For headline figures: "£12,480.00" */
export function currency(value, code = 'GBP') {
  return money(value, { currency: code });
}

export function shortDate(value) {
  if (!value) return '';
  const d = value instanceof Date ? value : new Date(value);
  return d.toLocaleDateString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  });
}

export function isoDate(value) {
  const d = value instanceof Date ? value : new Date(value);
  return d.toISOString().slice(0, 10);
}

export function today() {
  return isoDate(new Date());
}

/** Turns a Postgres error into something a non-accountant can act on. */
export function readableError(error) {
  if (!error) return null;
  const message = error.message || String(error);

  if (message.includes('does not balance')) {
    return message;
  }
  if (message.includes('maintained automatically')) {
    return message;
  }
  if (message.includes('no accounting period')) {
    return message;
  }
  if (message.includes('duplicate key')) {
    return 'Something with that code or number already exists.';
  }
  if (message.includes('violates row-level security')) {
    return 'You do not have permission to do that.';
  }
  if (message.includes('Failed to fetch')) {
    return 'Could not reach the server. Check your connection and try again.';
  }
  return message;
}

export const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/** Days in a given month, used to keep the year-end day picker honest. */
export function daysInMonth(month) {
  return [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] || 31;
}

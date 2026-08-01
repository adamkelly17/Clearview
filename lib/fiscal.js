/**
 * Financial year arithmetic.
 *
 * These mirror suggest_first_year_end() and the period loop in
 * 0011_fiscal_year.sql. The database is the authority — it recalculates
 * everything on create_organisation() — but the wizard needs to show the
 * user what they are about to get before they commit to it.
 *
 * All dates are handled in UTC to keep them clear of British Summer Time.
 */

export function monthEndDay(year, month) {
  // Day 0 of the following month is the last day of this one.
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** The year end falling in a given calendar year, clamped for short months. */
export function yearEndOn(year, day, month) {
  return new Date(Date.UTC(year, month - 1, Math.min(day, monthEndDay(year, month))));
}

function parseISO(iso) {
  if (!iso) return null;
  const d = new Date(`${iso}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function toISO(date) {
  return date ? date.toISOString().slice(0, 10) : '';
}

/**
 * The suggested end of the first financial year.
 *
 * A newly incorporated company and a business migrating mid-year can give
 * identical inputs and mean different things, so this is a suggestion the
 * user can overrule, not a rule. The one thing we can be confident about
 * is that a first period of under three months is almost never intended.
 */
export function suggestFirstYearEnd(startISO, day, month) {
  const start = parseISO(startISO);
  if (!start) return null;

  let end = yearEndOn(start.getUTCFullYear(), day, month);

  if (end < start) {
    end = yearEndOn(start.getUTCFullYear() + 1, day, month);
  }

  const threeMonthsIn = new Date(start);
  threeMonthsIn.setUTCMonth(threeMonthsIn.getUTCMonth() + 3);

  if (end < threeMonthsIn) {
    end = yearEndOn(end.getUTCFullYear() + 1, day, month);
  }

  return end;
}

/** Approximate length in months, to one decimal place. */
export function monthsBetween(startISO, endISO) {
  const start = parseISO(startISO);
  const end = parseISO(endISO);
  if (!start || !end) return null;
  const days = (end - start) / 86400000;
  return Math.round((days / 30.44) * 10) / 10;
}

/**
 * How many monthly periods the year will be split into. Matches the
 * database loop: periods tile the year exactly, so a year that is not a
 * whole number of calendar months gets a short first period.
 */
export function periodCount(startISO, endISO) {
  const start = parseISO(startISO);
  const end = parseISO(endISO);
  if (!start || !end || end < start) return 0;

  let count = 0;
  let cursor = new Date(start);

  while (cursor <= end && count < 24) {
    count += 1;
    const monthEnd = new Date(
      Date.UTC(cursor.getUTCFullYear(), cursor.getUTCMonth() + 1, 0)
    );
    cursor = new Date(Math.min(monthEnd.getTime(), end.getTime()) + 86400000);
  }

  return count;
}

/** True where the first period is a stub rather than a full month. */
export function hasStubPeriod(startISO) {
  const start = parseISO(startISO);
  return Boolean(start) && start.getUTCDate() !== 1;
}

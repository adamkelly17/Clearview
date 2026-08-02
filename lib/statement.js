import Papa from 'papaparse';
import * as XLSX from 'xlsx';

/**
 * Reading a bank statement file.
 *
 * There is no standard for UK bank statement CSVs. Barclays, HSBC,
 * Lloyds, NatWest, Monzo, Starling and Tide all differ — in column
 * names, in column order, in whether amounts are one signed column or
 * two, and in date format. Some put a preamble above the header row.
 *
 * So this guesses, shows the guess, and lets the user correct it. It does
 * not try to be clever enough to skip that step, because being wrong
 * about which column is the amount is not a recoverable error.
 */

/* Header names seen in the wild, lowercased. Order matters — the first
   match wins, so the more specific patterns come first. */
const PATTERNS = {
  date: ['date', 'transaction date', 'txn date', 'posting date', 'value date', 'completed date'],
  description: [
    'description', 'details', 'transaction description', 'narrative',
    'reference', 'memo', 'name', 'payee', 'transaction',
  ],
  amount: ['amount', 'value', 'transaction amount', 'signed amount'],
  moneyIn: ['money in', 'paid in', 'credit', 'credit amount', 'received', 'in'],
  moneyOut: ['money out', 'paid out', 'debit', 'debit amount', 'withdrawn', 'out'],
  balance: ['balance', 'running balance', 'closing balance', 'account balance'],
};

function normalise(header) {
  return String(header || '').toLowerCase().trim().replace(/[_-]+/g, ' ').replace(/\s+/g, ' ');
}

function findColumn(headers, candidates) {
  const cleaned = headers.map(normalise);

  // Exact match first, so "Amount" is not beaten by "Amount in USD".
  for (const candidate of candidates) {
    const i = cleaned.indexOf(candidate);
    if (i !== -1) return headers[i];
  }
  for (const candidate of candidates) {
    const i = cleaned.findIndex((h) => h.includes(candidate));
    if (i !== -1) return headers[i];
  }
  return null;
}

/**
 * Some banks put a few lines of account detail above the real header.
 * The header is the first row where several cells look like column names.
 */
function findHeaderRow(rows) {
  const wanted = [...PATTERNS.date, ...PATTERNS.amount, ...PATTERNS.moneyIn, ...PATTERNS.description];

  for (let i = 0; i < Math.min(rows.length, 15); i += 1) {
    const cells = (rows[i] || []).map(normalise).filter(Boolean);
    if (cells.length < 2) continue;
    const hits = cells.filter((c) => wanted.some((w) => c.includes(w))).length;
    if (hits >= 2) return i;
  }
  return 0;
}

export async function readStatementFile(file) {
  const name = file.name.toLowerCase();
  let rows;

  if (name.endsWith('.xlsx') || name.endsWith('.xls')) {
    const buffer = await file.arrayBuffer();
    const workbook = XLSX.read(buffer, { cellDates: false, raw: false });
    const sheet = workbook.Sheets[workbook.SheetNames[0]];
    rows = XLSX.utils.sheet_to_json(sheet, { header: 1, blankrows: false, defval: '' });
  } else {
    const text = await file.text();
    const parsed = Papa.parse(text, { skipEmptyLines: 'greedy' });
    rows = parsed.data;
  }

  if (!rows || rows.length < 2) {
    throw new Error('That file has no rows in it.');
  }

  const headerIndex = findHeaderRow(rows);
  const headers = (rows[headerIndex] || []).map((h) => String(h).trim());
  const body = rows.slice(headerIndex + 1).filter((r) => r.some((c) => String(c).trim() !== ''));

  const records = body.map((row) => {
    const record = {};
    headers.forEach((h, i) => {
      record[h || `Column ${i + 1}`] = row[i] == null ? '' : String(row[i]).trim();
    });
    return record;
  });

  const usableHeaders = headers.map((h, i) => h || `Column ${i + 1}`);

  const mapping = {
    date: findColumn(usableHeaders, PATTERNS.date),
    description: findColumn(usableHeaders, PATTERNS.description),
    amount: findColumn(usableHeaders, PATTERNS.amount),
    moneyIn: findColumn(usableHeaders, PATTERNS.moneyIn),
    moneyOut: findColumn(usableHeaders, PATTERNS.moneyOut),
    balance: findColumn(usableHeaders, PATTERNS.balance),
    dateFormat: 'dmy',
    // Two-column layouts are common enough that detecting them matters.
    amountMode: null,
  };

  mapping.amountMode = mapping.amount ? 'single' : (mapping.moneyIn || mapping.moneyOut) ? 'split' : 'single';

  // If a single amount column exists but is never negative while a
  // separate out column also exists, the split layout is the real one.
  if (mapping.amountMode === 'single' && mapping.amount && (mapping.moneyIn || mapping.moneyOut)) {
    const anyNegative = records.some((r) => String(r[mapping.amount]).includes('-'));
    if (!anyNegative) mapping.amountMode = 'split';
  }

  mapping.dateFormat = guessDateFormat(records, mapping.date);

  return { headers: usableHeaders, records, mapping, headerIndex };
}

/**
 * British or American dates.
 *
 * 04/03/2026 is 4 March here and 3 April in a US export. Getting it wrong
 * silently shifts transactions between months, so if the file contains any
 * value with a first part above 12 that settles it. Otherwise assume
 * British and let the user override — the preview shows the result.
 */
export function guessDateFormat(records, dateColumn) {
  if (!dateColumn) return 'dmy';

  let sawHighFirst = false;
  let sawHighSecond = false;

  for (const record of records.slice(0, 200)) {
    const match = String(record[dateColumn] || '').match(/^(\d{1,2})\D(\d{1,2})\D(\d{2,4})/);
    if (!match) continue;
    if (Number(match[1]) > 12) sawHighFirst = true;
    if (Number(match[2]) > 12) sawHighSecond = true;
  }

  if (sawHighFirst) return 'dmy';
  if (sawHighSecond) return 'mdy';
  return 'dmy';
}

export function parseDate(value, format = 'dmy') {
  if (!value) return null;
  const s = String(value).trim();

  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);

  // Excel serial numbers, which appear when a sheet had real dates in it.
  if (/^\d{5}$/.test(s)) {
    const serial = Number(s);
    const ms = (serial - 25569) * 86400000;
    return new Date(ms).toISOString().slice(0, 10);
  }

  const numeric = s.match(/^(\d{1,2})\D(\d{1,2})\D(\d{2,4})/);
  if (numeric) {
    const [, a, b, y] = numeric;
    const day = format === 'mdy' ? b : a;
    const month = format === 'mdy' ? a : b;
    const year = y.length === 2 ? `20${y}` : y;
    return `${year}-${month.padStart(2, '0')}-${day.padStart(2, '0')}`;
  }

  // "12 May 2026" and similar.
  const parsed = new Date(s);
  if (!Number.isNaN(parsed.getTime())) return parsed.toISOString().slice(0, 10);

  return null;
}

export function parseAmount(value) {
  if (value == null || value === '') return null;

  let s = String(value).trim();

  // Accountancy style negatives: (123.45)
  const bracketed = /^\((.*)\)$/.test(s);
  if (bracketed) s = s.replace(/[()]/g, '');

  // Strip currency symbols, thousands separators and stray spaces.
  s = s.replace(/[£$€,\s]/g, '');

  if (s === '' || s === '-') return null;

  const n = Number(s);
  if (!Number.isFinite(n)) return null;

  return bracketed ? -Math.abs(n) : n;
}

/**
 * Turns raw records plus a mapping into rows ready for import_statement().
 * Returns the good rows and the bad ones separately — a row that cannot be
 * read is worth showing rather than dropping.
 */
export function buildImportRows(records, mapping) {
  const rows = [];
  const problems = [];

  records.forEach((record, index) => {
    const date = parseDate(record[mapping.date], mapping.dateFormat);

    let amount = null;
    if (mapping.amountMode === 'split') {
      const inAmount = mapping.moneyIn ? parseAmount(record[mapping.moneyIn]) : null;
      const outAmount = mapping.moneyOut ? parseAmount(record[mapping.moneyOut]) : null;
      if (inAmount) amount = Math.abs(inAmount);
      else if (outAmount) amount = -Math.abs(outAmount);
    } else {
      amount = mapping.amount ? parseAmount(record[mapping.amount]) : null;
    }

    const description = mapping.description ? String(record[mapping.description] || '').trim() : '';

    if (!date) {
      problems.push({ row: index + 1, reason: 'The date could not be read', record });
      return;
    }
    if (amount == null) {
      problems.push({ row: index + 1, reason: 'The amount could not be read', record });
      return;
    }
    if (amount === 0) {
      problems.push({ row: index + 1, reason: 'Zero amount, nothing to reconcile', record });
      return;
    }

    rows.push({
      date,
      description: description || 'No description',
      reference: null,
      amount,
      balance: mapping.balance ? parseAmount(record[mapping.balance]) : null,
      raw: record,
    });
  });

  return { rows, problems };
}

/**
 * A starting pattern for a rule, from a bank description.
 *
 * Mirrors suggest_rule_pattern() in 0016_bank_rules.sql. Kept in JS as
 * well because the reconciliation screen needs one per line, and a round
 * trip per row to compute a string would be absurd.
 *
 * Bank descriptions are a stable name followed by a volatile tail —
 * card numbers, dates, payment references. "EDF ENERGY DD 4471" has to
 * suggest "EDF ENERGY" or the rule will never fire again.
 */
const NOISE = new Set([
  'DD', 'SO', 'BP', 'BAC', 'BACS', 'CHQ', 'CHEQUE', 'TFR', 'TRF', 'FP', 'FPI',
  'FPO', 'CRD', 'CARD', 'POS', 'ATM', 'DEB', 'CR', 'DR', 'PMT', 'PAYMENT',
  'REF', 'TX', 'TXN', 'VIS', 'MC', 'DIRECT', 'DEBIT', 'STANDING', 'ORDER',
  'FASTER', 'ONLINE', 'PMTS', 'TO', 'FROM', 'AT', 'VIA', 'THE', 'PURCHASE',
  'TRANSFER',
]);

export function suggestRulePattern(description) {
  const clean = String(description || '').replace(/\s+/g, ' ').trim();
  if (!clean) return '';

  const out = [];

  for (const word of clean.split(' ')) {
    if (/[0-9]/.test(word) || word.length <= 1) break;

    const token = word.replace(/[^A-Za-z]/g, '').toUpperCase();

    if (NOISE.has(token)) {
      // Leading markers are skipped so the real name is still found.
      // Once the name has started, a marker means it has finished.
      if (out.length === 0) continue;
      break;
    }

    out.push(word);
    if (out.length >= 4) break;
  }

  return out.length ? out.join(' ') : clean.slice(0, 18);
}

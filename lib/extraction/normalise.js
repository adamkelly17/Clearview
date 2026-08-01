/**
 * Turns a provider's result into rows for capture_extraction and
 * capture_extraction_line.
 *
 * Two jobs, both about not trusting the input:
 *
 *   1. Coerce types. A model may return "1,284.50" or "£1284.50" where a
 *      number was asked for, and a null where a number was promised.
 *   2. Never invent. If a figure is missing it stays null so validation
 *      can flag it, rather than being quietly derived from the others.
 *      A plausible wrong number is worse than a visible gap.
 */

function toNumber(value) {
  if (value == null || value === '') return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  const cleaned = String(value).replace(/[^0-9.\-]/g, '');
  if (cleaned === '' || cleaned === '-' || cleaned === '.') return null;
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

function round2(value) {
  const n = toNumber(value);
  return n == null ? null : Math.round(n * 100) / 100;
}

function toDate(value) {
  if (!value) return null;
  const s = String(value).trim();
  // Already ISO
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  // British DD/MM/YYYY — the ordering that catches people out
  const uk = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})$/);
  if (uk) {
    const [, d, m, y] = uk;
    const year = y.length === 2 ? `20${y}` : y;
    return `${year}-${m.padStart(2, '0')}-${d.padStart(2, '0')}`;
  }
  const parsed = new Date(s);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString().slice(0, 10);
}

function trim(value, max = 500) {
  if (value == null) return null;
  const s = String(value).trim();
  return s === '' ? null : s.slice(0, max);
}

export function normaliseExtraction(result) {
  const supplier = result.supplier || {};
  const invoice = result.invoice || {};
  const totals = result.totals || {};

  const header = {
    provider: result.provider,
    model: result.model,
    duration_ms: result.duration_ms ?? null,

    supplier_name: trim(supplier.name, 200),
    supplier_vat_number: trim(supplier.vat_number, 40),
    supplier_address: trim(supplier.address, 400),

    invoice_number: trim(invoice.number, 60),
    invoice_date: toDate(invoice.date),
    due_date: toDate(invoice.due_date),
    currency_code: trim(invoice.currency_code, 3) || 'GBP',

    net_total: round2(totals.net),
    vat_total: round2(totals.vat),
    gross_total: round2(totals.gross),

    field_confidence: result.confidence || {},
    overall_confidence: result.overall_confidence ?? null,
    raw_response: {
      notes: result.notes || [],
      reverse_charge: Boolean(result.reverse_charge),
      provider_raw: result.raw ?? null,
    },
  };

  const lines = (result.lines || [])
    .map((l, i) => ({
      line_no: i + 1,
      description: trim(l.description, 300) || 'Item',
      quantity: toNumber(l.quantity) ?? 1,
      unit_price: toNumber(l.unit_price),
      net_amount: round2(l.net_amount),
      vat_rate: toNumber(l.vat_rate),
      vat_amount: round2(l.vat_amount),
      confidence: toNumber(l.confidence),
    }))
    .filter((l) => l.net_amount != null || l.unit_price != null);

  return { header, lines, reverseCharge: Boolean(result.reverse_charge) };
}

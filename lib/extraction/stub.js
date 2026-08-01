/**
 * The stub extraction provider.
 *
 * Returns hand-written results with the same shape a real vision model
 * produces, so the whole capture flow — upload, match, validate, review,
 * approve, post — can be built and tested without an API account and
 * without any client document leaving the machine.
 *
 * The fixtures are chosen deliberately. Between them they cover the cases
 * that actually break invoice capture in the UK:
 *
 *   clean      a straightforward standard-rate invoice
 *   mixed      standard and zero rate on one document
 *   reverse    CIS domestic reverse charge, no VAT, notice wording
 *   broken     lines that do not sum to the header
 *   sparse     a photographed till receipt with no line detail
 *   unknown    a supplier not on file
 *
 * `broken` is the important one. You cannot reliably make a real model
 * misread something on demand, but you absolutely need to know what the
 * review screen does when extraction is wrong — that is the case the
 * whole design exists to catch.
 */

const FIXTURES = {
  clean: {
    supplier: {
      name: 'Timber Supplies Ltd',
      vat_number: 'GB 412 5567 21',
      address: 'Unit 7, Fishponds Road, Wokingham, RG41 2QN',
    },
    invoice: { number: 'TS-24188', date: 12, due: 42, currency_code: 'GBP' },
    totals: { net: 1284.5, vat: 256.9, gross: 1541.4 },
    lines: [
      { description: 'Oak board 20mm, 2.4m', quantity: 14, unit_price: 62.5, net_amount: 875, vat_rate: 20, vat_amount: 175 },
      { description: 'Softwood batten 38x63', quantity: 30, unit_price: 8.15, net_amount: 244.5, vat_rate: 20, vat_amount: 48.9 },
      { description: 'Delivery', quantity: 1, unit_price: 165, net_amount: 165, vat_rate: 20, vat_amount: 33 },
    ],
    confidence: {
      supplier_name: 0.99, supplier_vat_number: 0.97, invoice_number: 0.98,
      invoice_date: 0.98, net_total: 0.99, vat_total: 0.99, gross_total: 0.99,
    },
  },

  mixed: {
    supplier: {
      name: 'Hadley Print & Signage',
      vat_number: 'GB 227 8890 04',
      address: '14 Barkham Road, Wokingham, RG41 2RJ',
    },
    invoice: { number: 'HP/9921', date: 8, due: 38, currency_code: 'GBP' },
    totals: { net: 940.0, vat: 118.0, gross: 1058.0 },
    lines: [
      { description: 'Site boards, printed', quantity: 4, unit_price: 147.5, net_amount: 590, vat_rate: 20, vat_amount: 118 },
      { description: 'Printed brochures (zero rated)', quantity: 500, unit_price: 0.7, net_amount: 350, vat_rate: 0, vat_amount: 0 },
    ],
    confidence: {
      supplier_name: 0.98, supplier_vat_number: 0.94, invoice_number: 0.91,
      invoice_date: 0.97, net_total: 0.98, vat_total: 0.79, gross_total: 0.98,
    },
    notes: ['Two VAT rates on one document — the split is worth checking by eye.'],
  },

  reverse: {
    supplier: {
      name: 'K Wells Carpentry',
      vat_number: 'GB 561 2234 78',
      address: '3 Sandy Lane, Crowthorne, RG45 6PS',
    },
    invoice: { number: 'KW-0442', date: 5, due: 19, currency_code: 'GBP' },
    totals: { net: 3250.0, vat: 0, gross: 3250.0 },
    lines: [
      { description: 'First fix carpentry, plots 3–7', quantity: 1, unit_price: 2600, net_amount: 2600, vat_rate: 20, vat_amount: 0 },
      { description: 'Second fix, plot 3', quantity: 1, unit_price: 650, net_amount: 650, vat_rate: 20, vat_amount: 0 },
    ],
    confidence: {
      supplier_name: 0.97, supplier_vat_number: 0.95, invoice_number: 0.96,
      invoice_date: 0.98, net_total: 0.98, vat_total: 0.88, gross_total: 0.98,
    },
    reverse_charge: true,
    notes: [
      'The document states "Domestic reverse charge: customer to account for VAT to HMRC". No VAT has been charged.',
      'CIS labour appears to be included — check whether a deduction is due.',
    ],
  },

  // Lines total 1,180 but the header says 1,240. A real transposition.
  broken: {
    supplier: {
      name: 'Ashridge Plant Hire',
      vat_number: 'GB 774 1120 63',
      address: 'Bracknell Road, Bracknell, RG12 9YS',
    },
    invoice: { number: 'APH 31007', date: 15, due: 45, currency_code: 'GBP' },
    totals: { net: 1240.0, vat: 248.0, gross: 1488.0 },
    lines: [
      { description: 'Excavator hire, 3 weeks', quantity: 3, unit_price: 340, net_amount: 1020, vat_rate: 20, vat_amount: 204 },
      { description: 'Breaker attachment', quantity: 1, unit_price: 160, net_amount: 160, vat_rate: 20, vat_amount: 32 },
    ],
    confidence: {
      supplier_name: 0.96, supplier_vat_number: 0.92, invoice_number: 0.84,
      invoice_date: 0.95, net_total: 0.71, vat_total: 0.73, gross_total: 0.9,
    },
    notes: ['Part of this invoice was faint. The line detail may be incomplete.'],
  },

  sparse: {
    supplier: { name: 'Wokingham Motor Factors', vat_number: null, address: null },
    invoice: { number: '884213', date: 2, due: 2, currency_code: 'GBP' },
    totals: { net: 47.49, vat: 9.5, gross: 56.99 },
    lines: [],
    confidence: {
      supplier_name: 0.88, supplier_vat_number: 0, invoice_number: 0.72,
      invoice_date: 0.81, net_total: 0.9, vat_total: 0.9, gross_total: 0.94,
    },
    notes: ['Photographed receipt. No itemised detail was legible.'],
  },

  unknown: {
    supplier: {
      name: 'Pennington Scaffolding Services',
      vat_number: 'GB 903 4471 15',
      address: 'Nine Mile Ride, Finchampstead, RG40 3NX',
    },
    invoice: { number: 'PS-7734', date: 20, due: 50, currency_code: 'GBP' },
    totals: { net: 2150.0, vat: 430.0, gross: 2580.0 },
    lines: [
      { description: 'Scaffold erection and 4 week hire', quantity: 1, unit_price: 1850, net_amount: 1850, vat_rate: 20, vat_amount: 370 },
      { description: 'Dismantle', quantity: 1, unit_price: 300, net_amount: 300, vat_rate: 20, vat_amount: 60 },
    ],
    confidence: {
      supplier_name: 0.98, supplier_vat_number: 0.96, invoice_number: 0.97,
      invoice_date: 0.97, net_total: 0.98, vat_total: 0.98, gross_total: 0.99,
    },
  },
};

export const FIXTURE_NAMES = Object.keys(FIXTURES);

/**
 * Which fixture to return.
 *
 * A filename containing a fixture name wins, so you can test a specific
 * case by naming the file. Otherwise it is chosen from a hash of the
 * filename, which means the same file always gives the same result —
 * important, because a stub that returns something different each time
 * makes the review screen impossible to reason about.
 */
function chooseFixture(fileName = '') {
  const lower = fileName.toLowerCase();

  for (const name of FIXTURE_NAMES) {
    if (lower.includes(name)) return name;
  }

  let hash = 0;
  for (let i = 0; i < fileName.length; i += 1) {
    hash = (hash * 31 + fileName.charCodeAt(i)) % 100000;
  }
  return FIXTURE_NAMES[hash % FIXTURE_NAMES.length];
}

function isoDaysAgo(days) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

function isoDaysFrom(base, days) {
  const d = new Date(`${base}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export async function extractWithStub({ fileName }) {
  const started = Date.now();
  const key = chooseFixture(fileName || '');
  const f = FIXTURES[key];

  // A short delay so the interface's loading state is real rather than
  // theoretical — a flow that never shows a spinner in development will
  // show an ugly one in production.
  await new Promise((resolve) => setTimeout(resolve, 600));

  const invoiceDate = isoDaysAgo(f.invoice.date);

  const confidences = Object.values(f.confidence);
  const overall = confidences.reduce((a, b) => a + b, 0) / confidences.length;

  return {
    provider: 'stub',
    model: `fixtures-v1/${key}`,
    duration_ms: Date.now() - started,

    supplier: f.supplier,
    invoice: {
      number: f.invoice.number,
      date: invoiceDate,
      due_date: isoDaysFrom(invoiceDate, f.invoice.due - f.invoice.date),
      currency_code: f.invoice.currency_code,
    },
    totals: f.totals,
    lines: f.lines,

    reverse_charge: Boolean(f.reverse_charge),
    confidence: f.confidence,
    overall_confidence: Math.round(overall * 1000) / 1000,
    notes: f.notes || [],

    raw: { fixture: key, note: 'Stub provider. No document was read.' },
  };
}

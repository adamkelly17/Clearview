/**
 * Extraction using a vision model.
 *
 * NOT ACTIVE BY DEFAULT. Set EXTRACTION_PROVIDER=claude and provide
 * ANTHROPIC_API_KEY to switch it on.
 *
 * Read this before you do:
 *
 * Turning this on means client financial documents leave your
 * infrastructure and go to a third party. For an accountancy practice
 * that needs a data processing agreement in place first, and a check on
 * the provider's retention terms — zero retention is generally available
 * on request but should be confirmed in writing rather than assumed. If
 * you sell this, the provider becomes a named sub-processor you have to
 * disclose to your customers.
 *
 * The interface is deliberately narrow — one function, one return shape —
 * so swapping to Textract, Document AI or Mindee means writing one file
 * and changing one environment variable. Nothing downstream knows or
 * cares which one read the document.
 */

function buildSystemPrompt(codingOptions) {
  const coding = (codingOptions || []).length
    ? `

CATEGORIES
Suggest which category each line should be coded to, as "account_code".
Choose from this list only — if nothing fits, leave account_code null
rather than inventing a code.

${codingOptions.map((a) => `  ${a.code}  ${a.name}${a.report_group ? `  (${a.report_group})` : ''}`).join('\n')}

Code on what was actually bought, not on who sold it. A tape measure from
a general retailer is tools or consumables, not "general purchases".`
    : '';

  return SYSTEM_PROMPT + coding;
}

const SYSTEM_PROMPT = `You extract data from UK purchase invoices and receipts.

Return ONLY a JSON object, no preamble, no markdown fences. Use this shape:

{
  "supplier": { "name": string, "vat_number": string|null, "address": string|null },
  "invoice": { "number": string|null, "date": "YYYY-MM-DD"|null, "due_date": "YYYY-MM-DD"|null, "currency_code": string },
  "totals": { "net": number|null, "vat": number|null, "gross": number|null },
  "lines": [ { "description": string, "quantity": number, "unit_price": number, "net_amount": number, "vat_rate": number, "vat_amount": number, "account_code": string|null } ],
  "reverse_charge": boolean,
  "confidence": { "<field>": number between 0 and 1 },
  "notes": [ string ]
}

Rules:
- Dates are British: 04/03/2026 is 4 March 2026, not 3 April.
- Report figures exactly as printed. Do NOT correct arithmetic that does
  not add up, and do NOT infer a missing total. Leave it null and say so
  in notes. A wrong figure that looks plausible is worse than a gap.
- If the document says "domestic reverse charge", "reverse charge applies"
  or "customer to account for VAT", set reverse_charge true. VAT charged
  will be zero; still record the rate that would apply on each line.
- vat_rate is the percentage as a number: 20, 5 or 0.
- Set confidence honestly. Low confidence on a faint or ambiguous field is
  useful; uniform high confidence is not.
- If a field is genuinely absent, use null rather than guessing.
- Note anything a bookkeeper should look at: mixed VAT rates, a CIS
  deduction, a credit note rather than an invoice, a statement rather than
  an invoice, or more than one invoice on the same file.`;

export async function extractWithClaude({ fileBuffer, mimeType, fileName, codingOptions }) {
  const started = Date.now();
  const apiKey = process.env.ANTHROPIC_API_KEY;

  if (!apiKey) {
    throw new Error(
      'ANTHROPIC_API_KEY is not set. Either add it, or set EXTRACTION_PROVIDER=stub.'
    );
  }

  const base64 = Buffer.from(fileBuffer).toString('base64');
  const isPdf = mimeType === 'application/pdf';

  const content = [
    isPdf
      ? { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: base64 } }
      : { type: 'image', source: { type: 'base64', media_type: mimeType, data: base64 } },
    { type: 'text', text: `Extract this document. Filename: ${fileName}` },
  ];

  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: process.env.EXTRACTION_MODEL || 'claude-sonnet-4-6',
      max_tokens: 4000,
      system: buildSystemPrompt(codingOptions),
      messages: [{ role: 'user', content }],
    }),
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`Extraction failed (${response.status}): ${detail.slice(0, 400)}`);
  }

  const data = await response.json();

  const text = (data.content || [])
    .filter((b) => b.type === 'text')
    .map((b) => b.text)
    .join('')
    .replace(/```json|```/g, '')
    .trim();

  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error('The model did not return usable JSON. Try again or enter this one by hand.');
  }

  const confidence = parsed.confidence || {};
  const values = Object.values(confidence).filter((v) => typeof v === 'number');
  const overall = values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;

  return {
    provider: 'claude',
    model: data.model || 'claude',
    duration_ms: Date.now() - started,

    supplier: parsed.supplier || {},
    invoice: parsed.invoice || {},
    totals: parsed.totals || {},
    lines: Array.isArray(parsed.lines) ? parsed.lines : [],

    reverse_charge: Boolean(parsed.reverse_charge),
    confidence,
    overall_confidence: overall == null ? null : Math.round(overall * 1000) / 1000,
    notes: Array.isArray(parsed.notes) ? parsed.notes : [],

    raw: { usage: data.usage, stop_reason: data.stop_reason },
  };
}

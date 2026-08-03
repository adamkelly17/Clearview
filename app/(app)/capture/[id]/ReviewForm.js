'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { money, readableError, shortDate } from '@/lib/format';
import QuickContactModal from '@/components/QuickContactModal';

/**
 * The review screen.
 *
 * Original document on the left, what was read on the right, editable.
 * Nothing here has touched the ledger — approving is what calls
 * post_document(), and it posts what is on screen rather than what the
 * model said.
 *
 * Confidence is shown per field, but only where it is low. A row of green
 * ticks trains people to stop looking, which defeats the point; a marker
 * on the two fields that are shaky sends the eye exactly where it should
 * go.
 */

function Flag({ confidence }) {
  if (confidence == null || confidence >= 0.9) return null;
  const low = confidence < 0.75;
  return (
    <span
      className={`pill ${low ? 'pill-negative' : 'pill-caution'}`}
      title={`The model was ${Math.round(confidence * 100)}% confident of this`}
      style={{ marginLeft: '0.4375rem' }}
    >
      check
    </span>
  );
}

const blankLine = () => ({
  key: Math.random().toString(36).slice(2),
  description: '',
  quantity: '1',
  unit_price: '',
  account_id: '',
  vat_code_id: '',
});

export default function ReviewForm({
  capture,
  extraction,
  extractionLines,
  fileUrl,
  suppliers,
  accounts,
  vatCodes,
  duplicate,
  pro,
  vatEnabled,
  currencyCode,
}) {
  const router = useRouter();
  const conf = extraction?.field_confidence || {};
  const notes = extraction?.raw_response?.notes || [];
  const validation = extraction?.validation_notes || [];

  const [contactId, setContactId] = useState(extraction?.matched_contact_id || '');
  const [number, setNumber] = useState(extraction?.invoice_number || '');
  const [date, setDate] = useState(extraction?.invoice_date || '');
  /* Plenty of invoices carry no due date — a card purchase is already
     paid. Falling back to the invoice date is right far more often than
     leaving it blank, and it is still editable. */
  const [dueDate, setDueDate] = useState(
    extraction?.due_date || extraction?.invoice_date || ''
  );
  const [lines, setLines] = useState(() => {
    if (extractionLines.length) {
      return extractionLines.map((l) => {
        const qty = Number(l.quantity) || 1;
        const net = Number(l.net_amount) || 0;
        const vat = Number(l.vat_amount) || 0;

        /* A business that is not VAT registered cannot reclaim the VAT,
           so the whole £8.25 is the cost — not £6.87 with £1.38 sitting
           somewhere it can never be recovered from. Registered
           businesses post the net and reclaim the rest. */
        const amount = vatEnabled ? net : net + vat;
        const unit = qty ? amount / qty : amount;

        return {
          key: l.id,
          description: l.description || '',
          quantity: String(qty),
          unit_price: unit ? String(Math.round(unit * 100) / 100) : '',
          account_id: l.suggested_account_id || '',
          vat_code_id: vatEnabled ? l.suggested_vat_code_id || '' : '',
          confidence: l.confidence,
        };
      });
    }

    // Nothing itemised — start from the invoice total so a receipt with
    // no legible detail is still one field away from being posted.
    const fallback = vatEnabled ? extraction?.net_total : extraction?.gross_total;

    return [
      {
        ...blankLine(),
        description: extraction?.supplier_name ? 'Purchase' : '',
        unit_price: fallback != null ? String(fallback) : '',
      },
    ];
  });

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [dupAcknowledged, setDupAcknowledged] = useState(false);
  const [addingContact, setAddingContact] = useState(false);

  /* A supplier created from the dialog is held here as well as being
     selected, so it appears in the dropdown immediately. router.refresh()
     will fold it into the real list a moment later, but the reviewer
     should not have to wait — or lose the corrections already made. */
  const [newSuppliers, setNewSuppliers] = useState([]);
  const allSuppliers = [...suppliers, ...newSuppliers];

  const grouped = useMemo(() => {
    const groups = new Map();
    for (const a of accounts) {
      const g = a.account_type?.report_group || 'Other';
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(a);
    }
    return [...groups.entries()];
  }, [accounts]);

  const totals = useMemo(() => {
    let net = 0;
    let vat = 0;
    for (const l of lines) {
      const lineNet =
        Math.round((Number(l.quantity) || 0) * (Number(l.unit_price) || 0) * 100) / 100;
      const code = vatEnabled ? vatCodes.find((v) => v.id === l.vat_code_id) : null;
      if (code && !code.is_reverse_charge) {
        vat += Math.round(lineNet * Number(code.rate || 0)) / 100;
      }
      net += lineNet;
    }
    net = Math.round(net * 100) / 100;
    vat = Math.round(vat * 100) / 100;
    return { net, vat, gross: Math.round((net + vat) * 100) / 100 };
  }, [lines, vatCodes, vatEnabled]);

  /* Does what is on screen still agree with the document? */
  const stated = extraction?.gross_total == null ? null : Number(extraction.gross_total);
  const drift = stated == null ? null : Math.round((totals.gross - stated) * 100) / 100;
  const driftMatters = drift != null && Math.abs(drift) > 0.02;

  const update = (key, patch) =>
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  const addLine = () =>
    setLines((ls) => [
      ...ls,
      { ...blankLine(), account_id: ls[ls.length - 1]?.account_id || '', vat_code_id: ls[ls.length - 1]?.vat_code_id || '' },
    ]);
  const removeLine = (key) =>
    setLines((ls) => (ls.length <= 1 ? ls : ls.filter((l) => l.key !== key)));

  const filled = lines.filter((l) => l.account_id && Number(l.unit_price));
  const blockedByDuplicate = Boolean(duplicate) && !dupAcknowledged;
  const ready =
    contactId && number.trim() && date && filled.length > 0 && !blockedByDuplicate;

  async function approve() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc('approve_capture', {
      p_capture_id: capture.id,
      p_config: {
        doc_type: capture.ledger === 'purchase' ? 'PI' : 'SI',
        contact_id: contactId,
        date,
        due_date: dueDate || null,
        number: number.trim(),
        their_reference: number.trim(),
        notes: `Captured from ${capture.file_name}`,
        lines: filled.map((l) => ({
          description: l.description || 'Item',
          quantity: Number(l.quantity) || 1,
          unit_price: Number(l.unit_price) || 0,
          account_id: l.account_id,
          vat_code_id: l.vat_code_id || null,
        })),
      },
    });

    setBusy(false);
    if (error) {
      setError(readableError(error));
      return;
    }

    router.push('/capture');
    router.refresh();
  }

  async function reject() {
    setBusy(true);
    const supabase = createClient();
    const { error } = await supabase.rpc('reject_capture', {
      p_capture_id: capture.id,
      p_reason: 'Discarded during review',
    });
    setBusy(false);
    if (error) {
      setError(readableError(error));
      return;
    }
    router.push('/capture');
    router.refresh();
  }

  const errors = validation.filter((v) => v.severity === 'error');
  const warnings = validation.filter((v) => v.severity === 'warning');

  return (
    <div className="review">
      <QuickContactModal
        open={addingContact}
        onClose={() => setAddingContact(false)}
        onCreated={({ id, name }) => {
          setNewSuppliers((list) => [...list, { id, name, code: null }]);
          setContactId(id);
          setAddingContact(false);
          router.refresh();
        }}
        orgId={capture.organisation_id}
        kind={capture.ledger === 'purchase' ? 'supplier' : 'customer'}
        extraction={extraction}
        accounts={accounts}
        vatCodes={vatCodes}
        pro={pro}
      />

      {/* ---------------- Original ---------------- */}
      <div className="review-doc">
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-head">
            <h2>The document</h2>
            <a href={fileUrl} target="_blank" rel="noreferrer" className="small">
              Open full size
            </a>
          </div>
          {capture.mime_type === 'application/pdf' ? (
            <object data={fileUrl} type="application/pdf" className="review-frame">
              <p className="card-body hint">
                Your browser will not show the PDF inline.{' '}
                <a href={fileUrl} target="_blank" rel="noreferrer">Open it here</a>.
              </p>
            </object>
          ) : (
            /* eslint-disable-next-line @next/next/no-img-element */
            <img src={fileUrl} alt={capture.file_name} className="review-image" />
          )}
        </div>

        <p className="hint mt-md">
          {capture.file_name}
          {extraction && (
            <>
              {' · read by '}
              <span className="code">{extraction.model}</span>
              {extraction.overall_confidence != null &&
                ` · ${Math.round(extraction.overall_confidence * 100)}% average confidence`}
            </>
          )}
        </p>
      </div>

      {/* ---------------- What was read ---------------- */}
      <div className="review-fields">
        {error && <div className="notice notice-error">{error}</div>}

        {duplicate && (
          <div className="notice notice-error">
            <strong>This looks like a duplicate.</strong> {duplicate.number} dated{' '}
            {shortDate(duplicate.date)} for{' '}
            {money(duplicate.gross_total, { currency: currencyCode })} is already
            posted against this supplier — {duplicate.reason}.
            <div className="btn-row" style={{ marginTop: '0.75rem' }}>
              <button className="btn btn-secondary btn-sm" onClick={reject} disabled={busy}>
                Discard this one
              </button>
              <button
                className="btn btn-ghost btn-sm"
                onClick={() => setDupAcknowledged(true)}
              >
                It is genuinely different, carry on
              </button>
            </div>
          </div>
        )}

        {errors.map((v, i) => (
          <div className="notice notice-error" key={`e${i}`}>{v.message}</div>
        ))}
        {warnings.map((v, i) => (
          <div className="notice notice-caution" key={`w${i}`}>{v.message}</div>
        ))}
        {notes.map((n, i) => (
          <div className="notice notice-info" key={`n${i}`}>{n}</div>
        ))}

        <div className="card">
          <div className="card-head"><h2>Supplier and reference</h2></div>
          <div className="card-body">
            <label className="field">
              <span className="label">
                Supplier
                <Flag confidence={conf.supplier_name} />
              </span>
              <select
                className="select"
                value={contactId}
                onChange={(e) => setContactId(e.target.value)}
              >
                <option value="">Choose…</option>
                {allSuppliers.map((s) => (
                  <option key={s.id} value={s.id}>
                    {pro && s.code ? `${s.code} — ${s.name}` : s.name}
                  </option>
                ))}
              </select>
              {extraction?.supplier_name && (
                <span className="hint" style={{ display: 'block', marginTop: '0.375rem' }}>
                  Read as <strong>{extraction.supplier_name}</strong>
                  {extraction.supplier_vat_number && (
                    <> · VAT <span className="code">{extraction.supplier_vat_number}</span></>
                  )}
                  {extraction.match_method === 'similar_name' && ' — matched on a similar name'}
                  {extraction.match_method === 'vat_number' && ' — matched on VAT number'}
                  {!extraction.matched_contact_id && !contactId && (
                    <>
                      {' — no match on file. '}
                      <button
                        type="button"
                        className="link-button"
                        onClick={() => setAddingContact(true)}
                      >
                        Add them
                      </button>
                    </>
                  )}
                </span>
              )}
            </label>

            <div className="grid grid-3" style={{ marginBottom: 0 }}>
              <label className="field" style={{ marginBottom: 0 }}>
                <span className="label">
                  Their invoice number
                  <Flag confidence={conf.invoice_number} />
                </span>
                <input
                  className="input code"
                  value={number}
                  onChange={(e) => setNumber(e.target.value)}
                />
              </label>

              <label className="field" style={{ marginBottom: 0 }}>
                <span className="label">
                  Date
                  <Flag confidence={conf.invoice_date} />
                </span>
                <input
                  className="input"
                  type="date"
                  value={date}
                  onChange={(e) => setDate(e.target.value)}
                />
              </label>

              <label className="field" style={{ marginBottom: 0 }}>
                <span className="label">Due</span>
                <input
                  className="input"
                  type="date"
                  value={dueDate}
                  onChange={(e) => setDueDate(e.target.value)}
                />
              </label>
            </div>
          </div>
        </div>

        <div className="card mt-md">
          <div className="card-head">
            <h2>Lines</h2>
            <button className="btn btn-secondary btn-sm" onClick={addLine}>Add a line</button>
          </div>
          <div className="card-body">
            <table className="entry-grid">
              <thead>
                <tr>
                  <th>Description</th>
                  <th className="num" style={{ width: '4rem' }}>Qty</th>
                  <th className="num" style={{ width: '6rem' }}>Price</th>
                  <th style={{ width: '24%' }}>{pro ? 'Account' : 'Category'}</th>
                  {vatEnabled && <th style={{ width: '18%' }}>VAT</th>}
                  <th style={{ width: '2rem' }} />
                </tr>
              </thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.key}>
                    <td>
                      <input
                        className="input"
                        value={l.description}
                        onChange={(e) => update(l.key, { description: e.target.value })}
                      />
                    </td>
                    <td>
                      <input
                        className="input num"
                        inputMode="decimal"
                        value={l.quantity}
                        onChange={(e) => update(l.key, { quantity: e.target.value })}
                      />
                    </td>
                    <td>
                      <input
                        className="input num"
                        inputMode="decimal"
                        value={l.unit_price}
                        onChange={(e) => update(l.key, { unit_price: e.target.value })}
                      />
                    </td>
                    <td>
                      <select
                        className="select"
                        value={l.account_id}
                        onChange={(e) => update(l.key, { account_id: e.target.value })}
                      >
                        <option value="">Choose…</option>
                        {grouped.map(([group, items]) => (
                          <optgroup key={group} label={group}>
                            {items.map((a) => (
                              <option key={a.id} value={a.id}>
                                {pro ? `${a.code} — ${a.name}` : a.friendly_name || a.name}
                              </option>
                            ))}
                          </optgroup>
                        ))}
                      </select>
                    </td>
                    {vatEnabled && (
                      <td>
                        <select
                          className="select"
                          value={l.vat_code_id}
                          onChange={(e) => update(l.key, { vat_code_id: e.target.value })}
                        >
                          <option value="">No VAT</option>
                          {vatCodes.map((v) => (
                            <option key={v.id} value={v.id}>
                              {pro ? `${v.code} ${v.rate}%` : v.friendly_name}
                            </option>
                          ))}
                        </select>
                      </td>
                    )}
                    <td>
                      <button
                        className="entry-remove"
                        onClick={() => removeLine(l.key)}
                        disabled={lines.length <= 1}
                        aria-label="Remove this line"
                      >
                        ×
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        {/* The screen's real job: what you are about to post, set against
            what the document actually says. Anyone can check two numbers
            match; nobody can check a number they cannot see. */}
        <div className="card mt-md">
          <div className="card-head">
            <h2>Does this agree with the document?</h2>
          </div>
          <table className="table table-flush">
            <thead>
              <tr>
                <th />
                <th className="num" style={{ width: '9rem' }}>You are posting</th>
                <th className="num" style={{ width: '9rem' }}>The document says</th>
              </tr>
            </thead>
            <tbody>
              {vatEnabled && (
                <>
                  <tr className="no-hover">
                    <td className="muted">Before VAT</td>
                    <td><span className="num">{money(totals.net)}</span></td>
                    <td>
                      <span className={extraction?.net_total == null ? 'num num-nil' : 'num'}>
                        {extraction?.net_total == null ? 'not read' : money(extraction.net_total)}
                      </span>
                    </td>
                  </tr>
                  <tr className="no-hover">
                    <td className="muted">
                      VAT
                      <Flag confidence={conf.vat_total} />
                    </td>
                    <td><span className="num">{money(totals.vat)}</span></td>
                    <td>
                      <span className={extraction?.vat_total == null ? 'num num-nil' : 'num'}>
                        {extraction?.vat_total == null ? 'not read' : money(extraction.vat_total)}
                      </span>
                    </td>
                  </tr>
                </>
              )}
            </tbody>
            <tfoot>
              <tr>
                <td>{vatEnabled ? 'Total' : 'Total cost'}</td>
                <td>
                  <span className={`num ${driftMatters ? 'num-negative' : ''}`}>
                    {money(totals.gross, { currency: currencyCode })}
                  </span>
                </td>
                <td>
                  <span className="num">
                    {stated == null ? '—' : money(stated, { currency: currencyCode })}
                  </span>
                </td>
              </tr>
            </tfoot>
          </table>

          <div className="card-body" style={{ paddingTop: '0.75rem' }}>
            <p className="hint" style={{ margin: 0 }}>
              {vatEnabled ? (
                <>These two should match. If they do not, a line is missing or a VAT rate is wrong.</>
              ) : (
                <>
                  You are not VAT registered, so the whole amount including VAT is
                  your cost — there is nothing to reclaim. These two figures should
                  match.
                </>
              )}
            </p>
          </div>
        </div>

        {driftMatters && (
          <div className="notice notice-caution mt-md">
            What you are about to post is {money(Math.abs(drift), { currency: currencyCode })}{' '}
            {drift > 0 ? 'more' : 'less'} than the total on the document. That is fine
            if you have deliberately changed something — otherwise a line is
            probably missing or a rate is wrong.
          </div>
        )}

        <div className="btn-row mt-md">
          <button className="btn btn-danger" onClick={reject} disabled={busy}>
            Discard
          </button>
          <div className="spacer" />
          <button className="btn btn-primary" onClick={approve} disabled={!ready || busy}>
            {busy ? 'Posting…' : 'Approve and post'}
          </button>
        </div>

        {!ready && !blockedByDuplicate && (
          <p className="hint mt-md">
            {!contactId
              ? 'Choose the supplier before this can be posted.'
              : !number.trim()
              ? 'An invoice number is needed so the bill can be matched later.'
              : !date
              ? 'Enter the invoice date.'
              : 'Every line needs a category and a price.'}
          </p>
        )}
      </div>
    </div>
  );
}

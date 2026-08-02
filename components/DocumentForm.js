'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { money, readableError, today } from '@/lib/format';

/**
 * One form for all four document types.
 *
 *   SI sales invoice   SC sales credit note
 *   PI purchase bill   PC purchase credit note
 *
 * The totals shown here are only a preview. Every figure is
 * recalculated in the database when the document is posted, so the
 * browser's arithmetic is never what ends up in the ledger.
 */

const CONFIG = {
  SI: { title: 'invoice', party: 'Customer', ledger: 'sales', numbered: false },
  SC: { title: 'credit note', party: 'Customer', ledger: 'sales', numbered: false },
  PI: { title: 'bill', party: 'Supplier', ledger: 'purchase', numbered: true },
  PC: { title: 'credit note', party: 'Supplier', ledger: 'purchase', numbered: true },
};

const blankLine = () => ({
  key: Math.random().toString(36).slice(2),
  description: '',
  quantity: '1',
  unit_price: '',
  discount_percent: '',
  account_id: '',
  vat_code_id: '',
});

export default function DocumentForm({
  orgId,
  docType,
  contacts,
  accounts,
  vatCodes,
  pro,
  vatEnabled,
  currencyCode,
  /* When present, the form is editing rather than creating. Saving
     voids the original and posts a replacement — see replace_document(). */
  editing = null,
}) {
  const router = useRouter();
  const cfg = CONFIG[docType];
  const isEdit = Boolean(editing);

  /* Only ever default a VAT code when the business is actually VAT
     registered. Previously the column was hidden but the default code was
     still applied, so a 20.00 bill posted as 20.00 net plus 4.00 VAT. */
  const defaultVat = vatEnabled
    ? vatCodes.find((v) => (cfg.ledger === 'sales' ? v.is_default_sales : v.is_default_purchase))
    : null;

  const usableVatCodes = vatEnabled ? vatCodes : [];

  const [contactId, setContactId] = useState(editing?.contact_id || '');
  const [date, setDate] = useState(editing?.date || today());
  const [dueDate, setDueDate] = useState(editing?.due_date || '');
  const [number, setNumber] = useState(editing?.number || '');
  const [theirRef, setTheirRef] = useState(editing?.their_reference || '');
  const [notes, setNotes] = useState(editing?.notes || '');
  const [reason, setReason] = useState('');
  const [lines, setLines] = useState(() => {
    if (editing?.lines?.length) {
      return editing.lines.map((l) => ({
        key: Math.random().toString(36).slice(2),
        description: l.description || '',
        quantity: String(l.quantity ?? 1),
        unit_price: String(l.unit_price ?? ''),
        discount_percent: l.discount_percent ? String(l.discount_percent) : '',
        account_id: l.account_id || '',
        vat_code_id: vatEnabled ? l.vat_code_id || '' : '',
      }));
    }
    return [{ ...blankLine(), vat_code_id: defaultVat?.id || '' }];
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const contact = contacts.find((c) => c.id === contactId);

  /* Picking a contact fills in their terms and usual category. */
  function pickContact(id) {
    setContactId(id);
    const c = contacts.find((x) => x.id === id);
    if (!c) return;

    if (c.payment_terms_days != null && date) {
      const d = new Date(date);
      d.setDate(d.getDate() + c.payment_terms_days);
      setDueDate(d.toISOString().slice(0, 10));
    }

    setLines((ls) =>
      ls.map((l) => ({
        ...l,
        account_id: l.account_id || c.default_account_id || '',
        vat_code_id: vatEnabled
          ? l.vat_code_id || c.default_vat_code_id || defaultVat?.id || ''
          : '',
      }))
    );
  }

  const grouped = useMemo(() => {
    const groups = new Map();
    for (const a of accounts) {
      const g = a.account_type?.report_group || 'Other';
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(a);
    }
    return [...groups.entries()];
  }, [accounts]);

  /* Preview arithmetic, mirroring calculate_document_line(). */
  const totals = useMemo(() => {
    let net = 0;
    let vat = 0;
    let notional = 0;

    for (const l of lines) {
      const lineNet =
        Math.round(
          (Number(l.quantity) || 0) *
            (Number(l.unit_price) || 0) *
            (1 - (Number(l.discount_percent) || 0) / 100) *
            100
        ) / 100;

      const code = usableVatCodes.find((v) => v.id === l.vat_code_id);
      const rate = Number(code?.rate || 0);

      if (code?.is_reverse_charge) {
        if (cfg.ledger === 'purchase') {
          notional += Math.round(lineNet * rate) / 100;
        }
      } else {
        vat += Math.round(lineNet * rate) / 100;
      }

      net += lineNet;
    }

    net = Math.round(net * 100) / 100;
    vat = Math.round(vat * 100) / 100;
    notional = Math.round(notional * 100) / 100;

    return { net, vat, notional, gross: Math.round((net + vat) * 100) / 100 };
  }, [lines, usableVatCodes, cfg.ledger]);

  const hasReverseCharge = lines.some(
    (l) => usableVatCodes.find((v) => v.id === l.vat_code_id)?.is_reverse_charge
  );

  const filled = lines.filter((l) => l.account_id && Number(l.unit_price));
  const ready =
    contactId && date && filled.length > 0 && (!(cfg.numbered || isEdit) || number.trim());

  const update = (key, patch) =>
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const addLine = () =>
    setLines((ls) => [
      ...ls,
      {
        ...blankLine(),
        vat_code_id: ls[ls.length - 1]?.vat_code_id || defaultVat?.id || '',
        account_id: ls[ls.length - 1]?.account_id || '',
      },
    ]);

  const removeLine = (key) =>
    setLines((ls) => (ls.length <= 1 ? ls : ls.filter((l) => l.key !== key)));

  async function post() {
    setBusy(true);
    setError(null);

    const supabase = createClient();

    const config = {
      organisation_id: orgId,
      doc_type: docType,
      contact_id: contactId,
      date,
      due_date: dueDate || null,
      // When editing, the number is always editable so a correction can
      // keep the number the customer already has.
      number: cfg.numbered || isEdit ? number.trim() || null : null,
      their_reference: theirRef.trim() || null,
      notes: notes.trim() || null,
      lines: filled.map((l) => ({
        description: l.description || 'Item',
        quantity: Number(l.quantity) || 1,
        unit_price: Number(l.unit_price) || 0,
        discount_percent: Number(l.discount_percent) || 0,
        account_id: l.account_id,
        vat_code_id: vatEnabled ? l.vat_code_id || null : null,
      })),
    };

    const { data, error } = isEdit
      ? await supabase.rpc('replace_document', {
          p_document_id: editing.id,
          p_config: config,
          p_reason: reason.trim() || null,
        })
      : await supabase.rpc('post_document', { p_config: config });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    // An edit that no longer fits the payment against it leaves money on
    // account. That has to be said, not slipped past on a redirect.
    if (isEdit && Number(data?.left_on_account) > 0) {
      setOutcome(data);
      router.refresh();
      return;
    }

    router.push(cfg.ledger === 'sales' ? '/invoices' : '/bills');
    router.refresh();
  }

  const noContacts = contacts.length === 0;

  if (noContacts) {
    return (
      <div className="card">
        <div className="empty">
          <h3>No {cfg.party.toLowerCase()}s yet</h3>
          <p>
            Add {cfg.party === 'Customer' ? 'a customer' : 'a supplier'} first and
            they will appear here.
          </p>
          <a
            href={cfg.ledger === 'sales' ? '/customers/new' : '/suppliers/new'}
            className="btn btn-primary mt-md"
          >
            Add {cfg.party === 'Customer' ? 'a customer' : 'a supplier'}
          </a>
        </div>
      </div>
    );
  }

  return (
    <>
      {error && <div className="notice notice-error">{error}</div>}

      {outcome && (
        <div className="notice notice-caution">
          <strong>Saved as {outcome.new_number}.</strong>{' '}
          {money(outcome.payments_reapplied, { currency: currencyCode })} of the
          payment has been put back against it, and{' '}
          <strong>{money(outcome.left_on_account, { currency: currencyCode })}</strong>{' '}
          no longer fits — it is now sitting on account as a credit.
          <div className="btn-row" style={{ marginTop: '0.75rem' }}>
            <a
              href={cfg.ledger === 'sales' ? '/invoices' : '/bills'}
              className="btn btn-primary btn-sm"
            >
              Done
            </a>
          </div>
        </div>
      )}

      <div className="card">
        <div className="card-body">
          <div className="grid grid-3">
            <label className="field">
              <span className="label">{cfg.party}</span>
              <select
                className="select"
                value={contactId}
                onChange={(e) => pickContact(e.target.value)}
              >
                <option value="">Choose…</option>
                {contacts.map((c) => (
                  <option key={c.id} value={c.id}>
                    {pro ? `${c.code} — ${c.name}` : c.name}
                  </option>
                ))}
              </select>
            </label>

            <label className="field">
              <span className="label">Date</span>
              <input
                className="input"
                type="date"
                value={date}
                onChange={(e) => setDate(e.target.value)}
              />
            </label>

            <label className="field">
              <span className="label">
                Due <span className="muted">(optional)</span>
              </span>
              <input
                className="input"
                type="date"
                value={dueDate}
                onChange={(e) => setDueDate(e.target.value)}
              />
            </label>
          </div>

          <div className="grid grid-2" style={{ marginBottom: 0 }}>
            {(cfg.numbered || isEdit) && (
              <label className="field" style={{ marginBottom: 0 }}>
                <span className="label">
                  {cfg.numbered ? `Their ${cfg.title} number` : `${cfg.title} number`}
                </span>
                <input
                  className="input code"
                  value={number}
                  onChange={(e) => setNumber(e.target.value)}
                  placeholder="TS-9910"
                />
              </label>
            )}

            <label className="field" style={{ marginBottom: 0 }}>
              <span className="label">
                {cfg.numbered ? 'Your reference' : 'Their reference'}{' '}
                <span className="muted">(optional)</span>
              </span>
              <input
                className="input"
                value={theirRef}
                onChange={(e) => setTheirRef(e.target.value)}
                placeholder={cfg.numbered ? 'Job 214' : 'Their purchase order'}
              />
            </label>
          </div>

          {contact?.credit_limit != null && cfg.ledger === 'sales' && (
            <p className="hint" style={{ marginTop: '0.875rem' }}>
              Credit limit {money(contact.credit_limit, { currency: currencyCode })}.
            </p>
          )}

          {contact?.on_hold && (
            <div className="notice notice-caution" style={{ marginTop: '0.875rem', marginBottom: 0 }}>
              This account is on hold.
            </div>
          )}
        </div>
      </div>

      <div className="card mt-md">
        <div className="card-head">
          <h2>Lines</h2>
          <button className="btn btn-secondary btn-sm" onClick={addLine}>
            Add a line
          </button>
        </div>
        <div className="card-body">
          <table className="entry-grid">
            <thead>
              <tr>
                <th style={{ minWidth: '10rem' }}>Description</th>
                <th className="num" style={{ width: '4.5rem' }}>Qty</th>
                <th className="num" style={{ width: '6.5rem' }}>Price</th>
                <th className="num" style={{ width: '4.5rem' }}>Disc %</th>
                <th style={{ width: '20%' }}>{pro ? 'Account' : 'Category'}</th>
                {vatEnabled && <th style={{ width: '15%' }}>VAT</th>}
                <th className="num" style={{ width: '6.5rem' }}>Net</th>
                <th style={{ width: '2rem' }} />
              </tr>
            </thead>
            <tbody>
              {lines.map((l) => {
                const lineNet =
                  Math.round(
                    (Number(l.quantity) || 0) *
                      (Number(l.unit_price) || 0) *
                      (1 - (Number(l.discount_percent) || 0) / 100) *
                      100
                  ) / 100;

                return (
                  <tr key={l.key}>
                    <td>
                      <input
                        className="input"
                        value={l.description}
                        onChange={(e) => update(l.key, { description: e.target.value })}
                        placeholder="What was it for?"
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
                        placeholder="0.00"
                      />
                    </td>
                    <td>
                      <input
                        className="input num"
                        inputMode="decimal"
                        value={l.discount_percent}
                        onChange={(e) => update(l.key, { discount_percent: e.target.value })}
                        placeholder="0"
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
                          {usableVatCodes.map((v) => (
                            <option key={v.id} value={v.id}>
                              {pro ? `${v.code} ${v.rate}%` : v.friendly_name}
                            </option>
                          ))}
                        </select>
                      </td>
                    )}
                    <td className="num" style={{ paddingRight: '0.75rem', paddingTop: '0.5rem' }}>
                      <span className={lineNet ? 'num' : 'num num-nil'}>
                        {money(lineNet)}
                      </span>
                    </td>
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
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      <div className="grid grid-2 mt-md">
        <div className="card">
          <div className="card-body">
            <label className="field" style={{ marginBottom: 0 }}>
              <span className="label">
                Notes <span className="muted">(optional)</span>
              </span>
              <textarea
                className="textarea"
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="Shown on the document"
              />
            </label>
          </div>
        </div>

        <div className="card">
          <table className="table table-flush">
            <tbody>
              <tr className="no-hover">
                <td className="muted">Net</td>
                <td><span className="num">{money(totals.net, { currency: currencyCode })}</span></td>
              </tr>
              {vatEnabled && (
                <tr className="no-hover">
                  <td className="muted">VAT</td>
                  <td><span className="num">{money(totals.vat, { currency: currencyCode })}</span></td>
                </tr>
              )}
            </tbody>
            <tfoot>
              <tr>
                <td>Total</td>
                <td>
                  <span className="num" style={{ fontSize: '1.0625rem' }}>
                    {money(totals.gross, { currency: currencyCode })}
                  </span>
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
      </div>

      {hasReverseCharge && (
        <div className="notice notice-caution mt-md">
          {cfg.ledger === 'sales' ? (
            <>
              Reverse charge applies, so no VAT is charged on this{' '}
              {cfg.title}. Add a note telling the customer they must account for
              the VAT themselves.
            </>
          ) : (
            <>
              Reverse charge applies. No VAT is on the {cfg.title}, but{' '}
              {money(totals.notional, { currency: currencyCode })} of notional VAT
              will be posted to both the input and output VAT accounts, so it
              appears in boxes 1 and 4 of your return and nets to nil.
            </>
          )}
        </div>
      )}

      {isEdit && (
        <div className="card mt-md">
          <div className="card-body">
            <label className="field" style={{ marginBottom: 0 }}>
              <span className="label">
                Why is it changing? <span className="muted">(optional)</span>
              </span>
              <input
                className="input"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder="Wrong price agreed"
              />
              <span className="hint" style={{ display: 'block', marginTop: '0.375rem' }}>
                Recorded against the original, which stays in the audit trail
                marked as replaced by this one.
              </span>
            </label>
          </div>
        </div>
      )}

      <div className="btn-row mt-md">
        <button className="btn btn-secondary" onClick={() => router.back()} disabled={busy}>
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-primary" onClick={post} disabled={!ready || busy}>
          {busy
            ? 'Saving…'
            : isEdit
            ? 'Save the correction'
            : `Record this ${cfg.title}`}
        </button>
      </div>

      {!ready && (
        <p className="hint mt-md">
          {!contactId
            ? `Choose a ${cfg.party.toLowerCase()} to continue.`
            : (cfg.numbered || isEdit) && !number.trim()
            ? `Enter their ${cfg.title} number so you can match it up later.`
            : 'Add at least one line with a price and a category.'}
        </p>
      )}
    </>
  );
}

'use client';

import { useEffect, useRef, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';
import { parseAddress, tidyContactName } from '@/lib/address';

/**
 * Adding a supplier without leaving the review screen.
 *
 * The link used to open the full form in a new tab, which meant retyping
 * the name, the VAT number and the address that were already on screen —
 * and coming back to a page that had no idea a supplier had been created.
 *
 * Everything here is pre-filled from what was read off the document. The
 * name is tidied of its legal form and the address is split into fields,
 * because both arrive as printed rather than as data. Both are visibly
 * editable before saving, which is the point of pre-filling rather than
 * doing it silently.
 */
export default function QuickContactModal({
  open, onClose, onCreated, orgId, kind, extraction, accounts, vatCodes, pro,
}) {
  const isCustomer = kind === 'customer';
  const firstField = useRef(null);

  const [form, setForm] = useState(() => {
    const address = parseAddress(extraction?.supplier_address);
    return {
      name: tidyContactName(extraction?.supplier_name) || '',
      vat_number: extraction?.supplier_vat_number || '',
      payment_terms_days: 30,
      default_account_id: '',
      default_vat_code_id: '',
      ...address,
    };
  });

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const set = (patch) => setForm((f) => ({ ...f, ...patch }));

  useEffect(() => {
    if (!open) return;

    const esc = (e) => {
      if (e.key === 'Escape' && !busy) onClose();
    };
    document.addEventListener('keydown', esc);

    // Focus the name, since that is the one field that might need fixing.
    const t = setTimeout(() => firstField.current?.focus(), 40);

    // Stop the page behind scrolling while the dialog is up.
    const overflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    return () => {
      document.removeEventListener('keydown', esc);
      clearTimeout(t);
      document.body.style.overflow = overflow;
    };
  }, [open, busy, onClose]);

  if (!open) return null;

  async function save() {
    if (!form.name.trim()) {
      setError('Give them a name.');
      return;
    }

    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { data: id, error: saveError } = await supabase.rpc('create_contact', {
      p_config: {
        organisation_id: orgId,
        name: form.name.trim(),
        is_customer: isCustomer,
        is_supplier: !isCustomer,
        vat_number: form.vat_number.trim() || null,
        payment_terms_days: Number(form.payment_terms_days) || 30,
        default_account_id: form.default_account_id || null,
        default_vat_code_id: form.default_vat_code_id || null,
        address_line_1: form.address_line_1,
        address_line_2: form.address_line_2,
        city: form.city,
        postcode: form.postcode,
        country: form.country || null,
      },
    });

    setBusy(false);

    if (saveError) {
      setError(readableError(saveError));
      return;
    }

    // Handed straight back so the review screen can select it without a
    // reload — the reviewer keeps everything they had already corrected.
    onCreated({ id, name: form.name.trim() });
  }

  return (
    <div
      className="modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget && !busy) onClose();
      }}
    >
      <div className="modal" role="dialog" aria-modal="true" aria-label={`Add a ${kind}`}>
        <div className="modal-head">
          <div>
            <h2>Add {isCustomer ? 'a customer' : 'a supplier'}</h2>
            <p className="hint" style={{ margin: '0.25rem 0 0' }}>
              Filled in from the document. Change anything that looks wrong.
            </p>
          </div>
          <button className="modal-close" onClick={onClose} disabled={busy} aria-label="Close">
            ×
          </button>
        </div>

        <div className="modal-body">
          {error && <div className="notice notice-error">{error}</div>}

          <div className="grid grid-2">
            <label className="field">
              <span className="label">Name</span>
              <input
                ref={firstField}
                className="input"
                value={form.name}
                onChange={(e) => set({ name: e.target.value })}
              />
              {extraction?.supplier_name
                && tidyContactName(extraction.supplier_name) !== extraction.supplier_name && (
                <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                  The document says “{extraction.supplier_name}”.
                </span>
              )}
            </label>

            <label className="field">
              <span className="label">
                VAT number <span className="muted">(optional)</span>
              </span>
              <input
                className="input code"
                value={form.vat_number}
                onChange={(e) => set({ vat_number: e.target.value })}
              />
              <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                Worth keeping — their next invoice will match on this exactly.
              </span>
            </label>
          </div>

          <div className="grid grid-2">
            <label className="field">
              <span className="label">Address</span>
              <input
                className="input"
                value={form.address_line_1}
                onChange={(e) => set({ address_line_1: e.target.value })}
                placeholder="Street"
              />
            </label>

            <label className="field">
              <span className="label">
                Second line <span className="muted">(optional)</span>
              </span>
              <input
                className="input"
                value={form.address_line_2}
                onChange={(e) => set({ address_line_2: e.target.value })}
              />
            </label>

            <label className="field">
              <span className="label">Town</span>
              <input
                className="input"
                value={form.city}
                onChange={(e) => set({ city: e.target.value })}
              />
            </label>

            <label className="field">
              <span className="label">Postcode</span>
              <input
                className="input code"
                value={form.postcode}
                onChange={(e) => set({ postcode: e.target.value })}
              />
            </label>
          </div>

          <div className="grid grid-3">
            <label className="field" style={{ marginBottom: 0 }}>
              <span className="label">
                {isCustomer ? 'Days to pay you' : 'Days to pay them'}
              </span>
              <input
                className="input num"
                type="number"
                min="0"
                value={form.payment_terms_days}
                onChange={(e) => set({ payment_terms_days: e.target.value })}
              />
            </label>

            <label className="field" style={{ marginBottom: 0 }}>
              <span className="label">
                Usual {pro ? 'account' : 'category'} <span className="muted">(optional)</span>
              </span>
              <select
                className="select"
                value={form.default_account_id}
                onChange={(e) => set({ default_account_id: e.target.value })}
              >
                <option value="">No default</option>
                {accounts.map((a) => (
                  <option key={a.id} value={a.id}>
                    {pro ? `${a.code} — ${a.name}` : a.friendly_name || a.name}
                  </option>
                ))}
              </select>
            </label>

            {vatCodes.length > 0 && (
              <label className="field" style={{ marginBottom: 0 }}>
                <span className="label">
                  Usual VAT <span className="muted">(optional)</span>
                </span>
                <select
                  className="select"
                  value={form.default_vat_code_id}
                  onChange={(e) => set({ default_vat_code_id: e.target.value })}
                >
                  <option value="">No default</option>
                  {vatCodes.map((v) => (
                    <option key={v.id} value={v.id}>
                      {pro ? `${v.code} ${v.rate}%` : v.friendly_name}
                    </option>
                  ))}
                </select>
              </label>
            )}
          </div>
        </div>

        <div className="modal-foot">
          <button className="btn btn-secondary" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <div className="spacer" />
          <button className="btn btn-primary" onClick={save} disabled={busy}>
            {busy ? 'Saving…' : `Add and use ${isCustomer ? 'customer' : 'supplier'}`}
          </button>
        </div>
      </div>
    </div>
  );
}

'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';

/**
 * One form for customers and suppliers. The `kind` prop changes the
 * wording and which flag is set; everything else is identical, because
 * a great many businesses buy from the people they sell to.
 */
export default function ContactForm({ orgId, kind, accounts, vatCodes, pro }) {
  const router = useRouter();
  const isCustomer = kind === 'customer';

  const [form, setForm] = useState({
    name: '',
    contact_name: '',
    email: '',
    phone: '',
    payment_terms_days: isCustomer ? 30 : 30,
    credit_limit: '',
    address_line_1: '',
    address_line_2: '',
    city: '',
    postcode: '',
    vat_number: '',
    default_account_id: '',
    default_vat_code_id: '',
    cis_registered: false,
    cis_deduction_rate: '20',
    notes: '',
    also_the_other: false,
  });

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const set = (patch) => setForm((f) => ({ ...f, ...patch }));

  async function save() {
    if (!form.name.trim()) {
      setError('Enter a name.');
      return;
    }

    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc('create_contact', {
      p_config: {
        organisation_id: orgId,
        name: form.name.trim(),
        is_customer: isCustomer || form.also_the_other,
        is_supplier: !isCustomer || form.also_the_other,
        contact_name: form.contact_name,
        email: form.email,
        phone: form.phone,
        payment_terms_days: Number(form.payment_terms_days) || 30,
        credit_limit: form.credit_limit || null,
        address_line_1: form.address_line_1,
        address_line_2: form.address_line_2,
        city: form.city,
        postcode: form.postcode,
        vat_number: form.vat_number,
        default_account_id: form.default_account_id || null,
        default_vat_code_id: form.default_vat_code_id || null,
        cis_registered: form.cis_registered,
        cis_deduction_rate: form.cis_registered ? form.cis_deduction_rate : null,
        notes: form.notes,
      },
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    router.push(isCustomer ? '/customers' : '/suppliers');
    router.refresh();
  }

  return (
    <>
      {error && <div className="notice notice-error">{error}</div>}

      <div className="card">
        <div className="card-head">
          <h2>Details</h2>
        </div>
        <div className="card-body">
          <div className="grid grid-2">
            <label className="field">
              <span className="label">Name</span>
              <input
                className="input"
                autoFocus
                value={form.name}
                onChange={(e) => set({ name: e.target.value })}
                placeholder={isCustomer ? 'Hartley Developments' : 'Timber Supplies Ltd'}
              />
            </label>

            <label className="field">
              <span className="label">
                Person to contact <span className="muted">(optional)</span>
              </span>
              <input
                className="input"
                value={form.contact_name}
                onChange={(e) => set({ contact_name: e.target.value })}
              />
            </label>

            <label className="field">
              <span className="label">Email</span>
              <input
                className="input"
                type="email"
                value={form.email}
                onChange={(e) => set({ email: e.target.value })}
              />
            </label>

            <label className="field">
              <span className="label">Phone</span>
              <input
                className="input"
                value={form.phone}
                onChange={(e) => set({ phone: e.target.value })}
              />
            </label>
          </div>

          <div className="grid grid-2">
            <label className="field">
              <span className="label">Address</span>
              <input
                className="input"
                value={form.address_line_1}
                onChange={(e) => set({ address_line_1: e.target.value })}
                placeholder="Unit 4, Elm Trading Estate"
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
                placeholder="RG40 1AB"
              />
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
            </label>
          </div>
        </div>
      </div>

      <div className="card mt-lg">
        <div className="card-head">
          <h2>Terms and defaults</h2>
          <span className="hint">Filled in automatically on new {isCustomer ? 'invoices' : 'bills'}</span>
        </div>
        <div className="card-body">
          <div className="grid grid-2">
            <label className="field">
              <span className="label">
                {isCustomer ? 'Days to pay you' : 'Days you have to pay'}
              </span>
              <input
                className="input num"
                type="number"
                min="0"
                style={{ maxWidth: '8rem' }}
                value={form.payment_terms_days}
                onChange={(e) => set({ payment_terms_days: e.target.value })}
              />
            </label>

            {isCustomer && (
              <label className="field">
                <span className="label">
                  Credit limit <span className="muted">(optional)</span>
                </span>
                <input
                  className="input num"
                  inputMode="decimal"
                  style={{ maxWidth: '10rem' }}
                  value={form.credit_limit}
                  onChange={(e) => set({ credit_limit: e.target.value })}
                  placeholder="0.00"
                />
              </label>
            )}
          </div>

          <div className="grid grid-2">
            <label className="field">
              <span className="label">
                Usual {pro ? 'nominal account' : 'category'}
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
              <label className="field">
                <span className="label">Usual VAT treatment</span>
                <select
                  className="select"
                  value={form.default_vat_code_id}
                  onChange={(e) => set({ default_vat_code_id: e.target.value })}
                >
                  <option value="">No default</option>
                  {vatCodes.map((v) => (
                    <option key={v.id} value={v.id}>
                      {pro ? `${v.code} — ${v.name}` : v.friendly_name}
                    </option>
                  ))}
                </select>
              </label>
            )}
          </div>

          {!isCustomer && (
            <>
              <div className="toggle-row">
                <div className="toggle-copy">
                  <div className="toggle-title">Registered under CIS</div>
                  <div className="toggle-desc">
                    For subcontractors in construction. Records the deduction
                    rate against the supplier.
                  </div>
                </div>
                <button
                  type="button"
                  role="switch"
                  aria-checked={form.cis_registered}
                  aria-label="Registered under CIS"
                  className={`switch ${form.cis_registered ? 'switch-on' : ''}`}
                  onClick={() => set({ cis_registered: !form.cis_registered })}
                />
              </div>

              {form.cis_registered && (
                <label className="field" style={{ marginTop: '1rem' }}>
                  <span className="label">Deduction rate</span>
                  <select
                    className="select"
                    style={{ maxWidth: '14rem' }}
                    value={form.cis_deduction_rate}
                    onChange={(e) => set({ cis_deduction_rate: e.target.value })}
                  >
                    <option value="0">0% — gross payment status</option>
                    <option value="20">20% — registered</option>
                    <option value="30">30% — not registered</option>
                  </select>
                </label>
              )}
            </>
          )}

          <div className="toggle-row">
            <div className="toggle-copy">
              <div className="toggle-title">
                We also {isCustomer ? 'buy from' : 'sell to'} them
              </div>
              <div className="toggle-desc">
                Keeps one record instead of two, so the address and terms never
                drift apart.
              </div>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={form.also_the_other}
              aria-label="Also the other kind"
              className={`switch ${form.also_the_other ? 'switch-on' : ''}`}
              onClick={() => set({ also_the_other: !form.also_the_other })}
            />
          </div>

          <label className="field" style={{ marginTop: '1rem', marginBottom: 0 }}>
            <span className="label">
              Notes <span className="muted">(optional)</span>
            </span>
            <textarea
              className="textarea"
              value={form.notes}
              onChange={(e) => set({ notes: e.target.value })}
            />
          </label>
        </div>
      </div>

      <div className="btn-row mt-lg">
        <button
          className="btn btn-secondary"
          onClick={() => router.back()}
          disabled={busy}
        >
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-primary" onClick={save} disabled={busy}>
          {busy ? 'Saving…' : `Save ${isCustomer ? 'customer' : 'supplier'}`}
        </button>
      </div>
    </>
  );
}

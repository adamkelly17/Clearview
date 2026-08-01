'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError, today } from '@/lib/format';

const TYPES = [
  { code: 'current', title: 'Current account', desc: 'Day to day banking.' },
  { code: 'savings', title: 'Savings', desc: 'Money set aside.' },
  { code: 'credit_card', title: 'Credit card', desc: 'A balance you owe rather than hold.' },
  { code: 'cash', title: 'Cash', desc: 'Petty cash or a till.' },
  { code: 'loan', title: 'Loan', desc: 'Sits under long term liabilities.' },
];

export default function BankAccountForm({ orgId, existingAccounts, pro, currencyCode }) {
  const router = useRouter();
  const [form, setForm] = useState({
    name: '',
    type: 'current',
    sort_code: '',
    account_number: '',
    opening_balance: '',
    opening_date: today(),
    account_id: '',
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const set = (patch) => setForm((f) => ({ ...f, ...patch }));

  async function save() {
    if (!form.name.trim()) {
      setError('Give the account a name.');
      return;
    }

    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { data, error } = await supabase.rpc('create_bank_account', {
      p_config: {
        organisation_id: orgId,
        name: form.name.trim(),
        type: form.type,
        sort_code: form.sort_code || null,
        account_number: form.account_number || null,
        opening_balance: form.opening_balance || 0,
        opening_date: form.opening_balance ? form.opening_date : null,
        account_id: form.account_id || null,
      },
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    router.push(`/banking/${data}`);
    router.refresh();
  }

  return (
    <>
      {error && <div className="notice notice-error">{error}</div>}

      <div className="card">
        <div className="card-body">
          <label className="field">
            <span className="label">Name</span>
            <input
              className="input"
              autoFocus
              value={form.name}
              onChange={(e) => set({ name: e.target.value })}
              placeholder="Barclays Business Current"
            />
          </label>

          <span className="label">Type</span>
          <div className="choice-list">
            {TYPES.map((t) => (
              <button
                key={t.code}
                type="button"
                className={`choice ${form.type === t.code ? 'choice-selected' : ''}`}
                onClick={() => set({ type: t.code })}
              >
                <div>
                  <div className="choice-title">{t.title}</div>
                  <div className="choice-desc">{t.desc}</div>
                </div>
              </button>
            ))}
          </div>

          <div className="grid grid-2 mt-lg">
            <label className="field">
              <span className="label">Sort code <span className="muted">(optional)</span></span>
              <input
                className="input code"
                value={form.sort_code}
                onChange={(e) => set({ sort_code: e.target.value })}
                placeholder="20-45-67"
              />
            </label>

            <label className="field">
              <span className="label">Account number <span className="muted">(optional)</span></span>
              <input
                className="input code"
                value={form.account_number}
                onChange={(e) => set({ account_number: e.target.value })}
                placeholder="12345678"
              />
            </label>
          </div>
        </div>
      </div>

      <div className="card mt-lg">
        <div className="card-head">
          <h2>Opening balance</h2>
          <span className="hint">Only if you are starting mid-way through</span>
        </div>
        <div className="card-body">
          <div className="grid grid-2">
            <label className="field">
              <span className="label">Balance</span>
              <input
                className="input num"
                inputMode="decimal"
                value={form.opening_balance}
                onChange={(e) => set({ opening_balance: e.target.value })}
                placeholder="0.00"
              />
              <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                Negative if overdrawn, or for a credit card balance you owe.
              </span>
            </label>

            <label className="field">
              <span className="label">As at</span>
              <input
                className="input"
                type="date"
                value={form.opening_date}
                onChange={(e) => set({ opening_date: e.target.value })}
                disabled={!form.opening_balance}
              />
            </label>
          </div>

          {pro && existingAccounts.length > 0 && (
            <label className="field" style={{ marginBottom: 0 }}>
              <span className="label">
                Use an existing nominal instead of creating one
              </span>
              <select
                className="select"
                value={form.account_id}
                onChange={(e) => set({ account_id: e.target.value })}
              >
                <option value="">Create a new nominal in the 12xx range</option>
                {existingAccounts.map((a) => (
                  <option key={a.id} value={a.id}>{a.code} — {a.name}</option>
                ))}
              </select>
            </label>
          )}
        </div>
      </div>

      <div className="btn-row mt-lg">
        <button className="btn btn-secondary" onClick={() => router.back()} disabled={busy}>
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-primary" onClick={save} disabled={busy}>
          {busy ? 'Saving…' : 'Add the account'}
        </button>
      </div>
    </>
  );
}

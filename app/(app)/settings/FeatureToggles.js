'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';

const TOGGLES = [
  {
    key: 'vat_enabled',
    title: 'VAT registered',
    desc: 'Adds VAT to invoices and bills and keeps a running VAT return.',
  },
  {
    key: 'holds_stock',
    title: 'The business holds stock',
    desc: 'Turns on the stock accounts and the year-end stock adjustments.',
  },
  {
    key: 'stock_control_enabled',
    title: 'Track stock in Ledger',
    desc: 'Counts quantities in and out and values what is left.',
    requires: 'holds_stock',
  },
  {
    key: 'multicurrency_enabled',
    title: 'Use other currencies',
    desc: 'Lets you invoice and pay in a currency other than your main one.',
  },
  {
    key: 'departments_enabled',
    title: 'Departments',
    desc: 'Splits income and costs by department or cost centre.',
  },
  {
    key: 'accountant_mode',
    title: 'Accountant mode',
    desc: 'Shows nominal codes, journals, and debit and credit columns.',
  },
];

export default function FeatureToggles({ orgId, initial, canEdit }) {
  const router = useRouter();
  const [state, setState] = useState(initial);
  const [error, setError] = useState(null);
  const [saving, setSaving] = useState(null);

  async function toggle(key, value) {
    if (!canEdit) return;

    const patch = { [key]: value };

    // Turning off stock also turns off stock tracking.
    if (key === 'holds_stock' && !value) patch.stock_control_enabled = false;
    // Accountant mode and code visibility move together.
    if (key === 'accountant_mode') patch.show_nominal_codes = value;

    const previous = state;
    setState({ ...state, ...patch });
    setSaving(key);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase
      .from('organisation_feature')
      .update({ ...patch, updated_at: new Date().toISOString() })
      .eq('organisation_id', orgId);

    setSaving(null);

    if (error) {
      setState(previous);
      setError(readableError(error));
      return;
    }

    router.refresh();
  }

  return (
    <>
      {error && <div className="notice notice-error">{error}</div>}
      {!canEdit && (
        <div className="notice notice-caution">
          Only an owner or admin can change these.
        </div>
      )}

      {TOGGLES.map((t) => {
        const blocked = t.requires && !state[t.requires];
        return (
          <div className="toggle-row" key={t.key} style={blocked ? { opacity: 0.5 } : undefined}>
            <div className="toggle-copy">
              <div className="toggle-title">{t.title}</div>
              <div className="toggle-desc">{t.desc}</div>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={Boolean(state[t.key])}
              aria-label={t.title}
              disabled={!canEdit || blocked || saving === t.key}
              className={`switch ${state[t.key] ? 'switch-on' : ''}`}
              onClick={() => toggle(t.key, !state[t.key])}
            />
          </div>
        );
      })}

      {state.vat_enabled && (
        <p className="hint mt-md">
          VAT scheme: <strong>{state.vat_scheme}</strong>, filed{' '}
          <strong>{state.vat_return_frequency}</strong>. Changing the scheme
          arrives with the VAT phase.
        </p>
      )}
    </>
  );
}

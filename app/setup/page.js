'use client';

import { useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { MONTHS, daysInMonth, readableError, shortDate } from '@/lib/format';
import {
  suggestFirstYearEnd,
  toISO,
  monthsBetween,
  periodCount,
  hasStubPeriod,
} from '@/lib/fiscal';

/* ---------------------------------------------------------------------
   Every question here is one the software genuinely cannot answer for
   itself. Everything else has a default and lives in Settings.
   ------------------------------------------------------------------ */

const ENTITY_TYPES = [
  { code: 'sole_trader', title: 'Sole trader', desc: 'You work for yourself and the business is you.' },
  { code: 'partnership', title: 'Partnership', desc: 'Two or more people in business together.' },
  { code: 'limited_company', title: 'Limited company', desc: 'Registered at Companies House with its own legal identity.' },
  { code: 'llp', title: 'Limited liability partnership', desc: 'A partnership registered at Companies House.' },
  { code: 'charity', title: 'Charity or not-for-profit', desc: 'Funds are held for a purpose rather than an owner.' },
];

const VAT_SCHEMES = [
  { code: 'standard', title: 'Standard', desc: 'VAT is due when you raise or receive an invoice. The usual choice.' },
  { code: 'cash', title: 'Cash accounting', desc: 'VAT is due when money actually moves. Helps if customers pay slowly.' },
  { code: 'flat_rate', title: 'Flat rate', desc: 'You pay a fixed percentage of turnover instead of the usual calculation.' },
];

const STEPS = ['Business', 'Year', 'VAT', 'Stock', 'Currency', 'Finish'];

function Toggle({ on, onChange, label }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      className={`switch ${on ? 'switch-on' : ''}`}
      onClick={() => onChange(!on)}
    />
  );
}

export default function SetupPage() {
  const router = useRouter();
  const [step, setStep] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [currencies, setCurrencies] = useState([]);

  const now = new Date();

  const [form, setForm] = useState({
    name: '',
    entity_type_code: '',
    company_number: '',
    vat_number: '',
    postcode: '',

    year_end_day: 31,
    year_end_month: 3,
    books_start_date: `${now.getFullYear()}-04-01`,
    first_year_end_date: '',

    vat_enabled: false,
    vat_scheme: 'standard',
    vat_return_frequency: 'quarterly',
    flat_rate_percent: '',
    vat_registered_from: '',

    holds_stock: false,
    stock_control_enabled: false,
    stock_valuation: 'fifo',

    multicurrency_enabled: false,
    base_currency_code: 'GBP',

    accountant_mode: false,
  });

  const set = (patch) => setForm((f) => ({ ...f, ...patch }));

  useEffect(() => {
    const supabase = createClient();
    supabase
      .from('currency')
      .select('code, name, symbol')
      .order('sort_order')
      .then(({ data }) => setCurrencies(data || []));
  }, []);

  const isCompany = form.entity_type_code === 'limited_company' || form.entity_type_code === 'llp';

  /* The suggested first year end. A newly incorporated company and a
     business migrating mid-year can give identical inputs and mean
     different things, so this is a starting point, not a rule. */
  const suggestedEnd = useMemo(
    () => toISO(suggestFirstYearEnd(form.books_start_date, form.year_end_day, form.year_end_month)),
    [form.books_start_date, form.year_end_day, form.year_end_month]
  );

  const firstYearEnd = form.first_year_end_date || suggestedEnd;
  const overridden = Boolean(form.first_year_end_date) && form.first_year_end_date !== suggestedEnd;
  const yearMonths = monthsBetween(form.books_start_date, firstYearEnd);
  const periods = periodCount(form.books_start_date, firstYearEnd);
  const stub = hasStubPeriod(form.books_start_date);

  const yearTooLong = yearMonths != null && yearMonths > 18.5;
  const yearBackwards = Boolean(firstYearEnd) && firstYearEnd <= form.books_start_date;

  const canContinue = () => {
    if (step === 0) return form.name.trim().length > 1 && form.entity_type_code;
    if (step === 1) {
      return (
        Boolean(form.books_start_date) &&
        Boolean(firstYearEnd) &&
        !yearTooLong &&
        !yearBackwards
      );
    }
    return true;
  };

  async function create() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const payload = {
      ...form,
      first_year_end_date: firstYearEnd,
      flat_rate_percent: form.vat_scheme === 'flat_rate' ? form.flat_rate_percent || null : null,
      vat_registered_from: form.vat_registered_from || null,
      stock_control_enabled: form.holds_stock ? form.stock_control_enabled : false,
    };

    const { error } = await supabase.rpc('create_organisation', { p_config: payload });

    if (error) {
      setBusy(false);
      setError(readableError(error));
      return;
    }

    router.push('/dashboard');
    router.refresh();
  }

  return (
    <div className="setup">
      <div className="setup-inner">
        <div className="auth-mark">Ledger</div>

        <div className="setup-steps" role="progressbar" aria-valuenow={step + 1} aria-valuemin={1} aria-valuemax={STEPS.length}>
          {STEPS.map((s, i) => (
            <div key={s} className={`setup-step ${i <= step ? 'setup-step-done' : ''}`} />
          ))}
        </div>

        {error && <div className="notice notice-error">{error}</div>}

        {/* ---------------------------------------------------------- */}
        {step === 0 && (
          <>
            <h1>What are we setting up?</h1>
            <p className="hint mt-md" style={{ marginBottom: '1.5rem' }}>
              This decides how your accounts are laid out, so it is worth
              getting right. You can change the details later, but not the
              type.
            </p>

            <label className="field">
              <span className="label">Business name</span>
              <input
                className="input"
                autoFocus
                value={form.name}
                onChange={(e) => set({ name: e.target.value })}
                placeholder="Acme Joinery Ltd"
              />
            </label>

            <span className="label">Type of business</span>
            <div className="choice-list">
              {ENTITY_TYPES.map((t) => (
                <button
                  key={t.code}
                  type="button"
                  className={`choice ${form.entity_type_code === t.code ? 'choice-selected' : ''}`}
                  onClick={() => set({ entity_type_code: t.code })}
                >
                  <div>
                    <div className="choice-title">{t.title}</div>
                    <div className="choice-desc">{t.desc}</div>
                  </div>
                </button>
              ))}
            </div>

            {isCompany && (
              <label className="field mt-lg">
                <span className="label">Company number <span className="muted">(optional)</span></span>
                <input
                  className="input code"
                  value={form.company_number}
                  onChange={(e) => set({ company_number: e.target.value })}
                  placeholder="12345678"
                />
              </label>
            )}
          </>
        )}

        {/* ---------------------------------------------------------- */}
        {step === 1 && (
          <>
            <h1>When does your financial year end?</h1>
            <p className="hint mt-md" style={{ marginBottom: '1.5rem' }}>
              {isCompany
                ? 'For a company this is usually the last day of the month you were incorporated in. It is on your Companies House record.'
                : 'Most sole traders and partnerships use 5 April or 31 March.'}
            </p>

            <div className="grid grid-2">
              <label className="field">
                <span className="label">Day</span>
                <select
                  className="select"
                  value={form.year_end_day}
                  onChange={(e) => set({ year_end_day: Number(e.target.value) })}
                >
                  {Array.from({ length: daysInMonth(form.year_end_month) }, (_, i) => i + 1).map((d) => (
                    <option key={d} value={d}>{d}</option>
                  ))}
                </select>
              </label>

              <label className="field">
                <span className="label">Month</span>
                <select
                  className="select"
                  value={form.year_end_month}
                  onChange={(e) => {
                    const m = Number(e.target.value);
                    set({ year_end_month: m, year_end_day: Math.min(form.year_end_day, daysInMonth(m)) });
                  }}
                >
                  {MONTHS.map((m, i) => (
                    <option key={m} value={i + 1}>{m}</option>
                  ))}
                </select>
              </label>
            </div>

            <label className="field">
              <span className="label">First day you want to keep books from</span>
              <input
                className="input"
                type="date"
                value={form.books_start_date}
                onChange={(e) => set({ books_start_date: e.target.value })}
              />
              <span className="hint" style={{ display: 'block', marginTop: '0.375rem' }}>
                Nothing can be entered before this date. If you are moving from
                another system, use the day after your last set of accounts.
              </span>
            </label>

            <label className="field">
              <span className="label">Your first year ends</span>
              <div className="row" style={{ gap: '0.625rem' }}>
                <input
                  className="input"
                  type="date"
                  style={{ width: 'auto' }}
                  value={firstYearEnd}
                  onChange={(e) => set({ first_year_end_date: e.target.value })}
                />
                {overridden && (
                  <button
                    className="btn btn-ghost btn-sm"
                    onClick={() => set({ first_year_end_date: '' })}
                  >
                    Use suggested
                  </button>
                )}
              </div>
              <span className="hint" style={{ display: 'block', marginTop: '0.375rem' }}>
                {isCompany
                  ? 'A first period is often longer than a year. Companies House sets it to the end of the month your first anniversary falls in, and allows up to eighteen months.'
                  : 'Only the first year can be an odd length. Every year after this one runs to the date above.'}
              </span>
            </label>

            {yearBackwards ? (
              <div className="notice notice-error">
                The year end has to be after the day your books start.
              </div>
            ) : yearTooLong ? (
              <div className="notice notice-error">
                That is about {yearMonths} months. A financial year cannot run
                for longer than eighteen months, so this needs shortening.
              </div>
            ) : firstYearEnd ? (
              <div className="notice notice-info">
                Your first year runs from{' '}
                <strong>{shortDate(form.books_start_date)}</strong> to{' '}
                <strong>{shortDate(firstYearEnd)}</strong> — about{' '}
                <strong>{yearMonths} months</strong>, split into {periods}{' '}
                periods.
                {stub && (
                  <>
                    {' '}
                    The first one is a part month, which keeps the stub before
                    you started trading separate from the full months after it.
                  </>
                )}
                {' '}Later years will run to {form.year_end_day}{' '}
                {MONTHS[form.year_end_month - 1]}.
              </div>
            ) : null}
          </>
        )}

        {/* ---------------------------------------------------------- */}
        {step === 2 && (
          <>
            <h1>Are you VAT registered?</h1>
            <p className="hint mt-md" style={{ marginBottom: '1.25rem' }}>
              If you are not, leave this off. You can switch it on the day you
              register and nothing you have already entered will change.
            </p>

            <div className="card">
              <div className="card-body">
                <div className="toggle-row">
                  <div className="toggle-copy">
                    <div className="toggle-title">VAT registered</div>
                    <div className="toggle-desc">
                      Adds VAT to invoices and bills, and keeps a running VAT
                      return.
                    </div>
                  </div>
                  <Toggle on={form.vat_enabled} onChange={(v) => set({ vat_enabled: v })} label="VAT registered" />
                </div>
              </div>
            </div>

            {form.vat_enabled && (
              <div className="mt-lg">
                <label className="field">
                  <span className="label">VAT number</span>
                  <input
                    className="input code"
                    value={form.vat_number}
                    onChange={(e) => set({ vat_number: e.target.value })}
                    placeholder="GB123456789"
                  />
                </label>

                <span className="label">Which scheme are you on?</span>
                <div className="choice-list">
                  {VAT_SCHEMES.map((s) => (
                    <button
                      key={s.code}
                      type="button"
                      className={`choice ${form.vat_scheme === s.code ? 'choice-selected' : ''}`}
                      onClick={() => set({ vat_scheme: s.code })}
                    >
                      <div>
                        <div className="choice-title">{s.title}</div>
                        <div className="choice-desc">{s.desc}</div>
                      </div>
                    </button>
                  ))}
                </div>

                {form.vat_scheme === 'flat_rate' && (
                  <label className="field mt-lg">
                    <span className="label">Your flat rate percentage</span>
                    <input
                      className="input num"
                      type="number"
                      step="0.1"
                      style={{ maxWidth: '9rem' }}
                      value={form.flat_rate_percent}
                      onChange={(e) => set({ flat_rate_percent: e.target.value })}
                      placeholder="14.5"
                    />
                  </label>
                )}

                <label className="field mt-lg">
                  <span className="label">How often do you file?</span>
                  <select
                    className="select"
                    style={{ maxWidth: '16rem' }}
                    value={form.vat_return_frequency}
                    onChange={(e) => set({ vat_return_frequency: e.target.value })}
                  >
                    <option value="quarterly">Every three months</option>
                    <option value="monthly">Every month</option>
                    <option value="annual">Once a year</option>
                  </select>
                </label>

                <div className="notice notice-caution">
                  Ledger works out your VAT return figures. Filing them with
                  HMRC through Making Tax Digital is not built yet, so submit
                  the numbers through your existing route.
                </div>
              </div>
            )}
          </>
        )}

        {/* ---------------------------------------------------------- */}
        {step === 3 && (
          <>
            <h1>Do you hold stock?</h1>
            <p className="hint mt-md" style={{ marginBottom: '1.25rem' }}>
              Stock means goods you buy or make and hold on to until you sell
              them. If you only sell your time, the answer is no.
            </p>

            <div className="card">
              <div className="card-body">
                <div className="toggle-row">
                  <div className="toggle-copy">
                    <div className="toggle-title">The business holds stock</div>
                    <div className="toggle-desc">
                      Turns on the stock nominal accounts and the opening and
                      closing stock adjustments at year end.
                    </div>
                  </div>
                  <Toggle on={form.holds_stock} onChange={(v) => set({ holds_stock: v, stock_control_enabled: v ? form.stock_control_enabled : false })} label="Holds stock" />
                </div>

                {form.holds_stock && (
                  <>
                    <div className="toggle-row">
                      <div className="toggle-copy">
                        <div className="toggle-title">Track stock in Ledger</div>
                        <div className="toggle-desc">
                          Counts quantities in and out and values what is left.
                          Leave this off if you count stock once a year and
                          enter the figure by hand.
                        </div>
                      </div>
                      <Toggle
                        on={form.stock_control_enabled}
                        onChange={(v) => set({ stock_control_enabled: v })}
                        label="Track stock in Ledger"
                      />
                    </div>

                    {form.stock_control_enabled && (
                      <label className="field" style={{ marginTop: '1rem', marginBottom: 0 }}>
                        <span className="label">How should stock be valued?</span>
                        <select
                          className="select"
                          style={{ maxWidth: '20rem' }}
                          value={form.stock_valuation}
                          onChange={(e) => set({ stock_valuation: e.target.value })}
                        >
                          <option value="fifo">First in, first out</option>
                          <option value="average">Average cost</option>
                        </select>
                      </label>
                    )}
                  </>
                )}
              </div>
            </div>
          </>
        )}

        {/* ---------------------------------------------------------- */}
        {step === 4 && (
          <>
            <h1>Do you deal in other currencies?</h1>
            <p className="hint mt-md" style={{ marginBottom: '1.25rem' }}>
              Your accounts are always kept in one main currency. Switch this
              on if you also invoice or buy in another.
            </p>

            <label className="field">
              <span className="label">Main currency</span>
              <select
                className="select"
                style={{ maxWidth: '20rem' }}
                value={form.base_currency_code}
                onChange={(e) => set({ base_currency_code: e.target.value })}
              >
                {currencies.map((c) => (
                  <option key={c.code} value={c.code}>
                    {c.code} — {c.name}
                  </option>
                ))}
              </select>
            </label>

            <div className="card mt-md">
              <div className="card-body">
                <div className="toggle-row">
                  <div className="toggle-copy">
                    <div className="toggle-title">Use other currencies too</div>
                    <div className="toggle-desc">
                      Lets you raise invoices and record payments in another
                      currency. Can be switched on later without affecting
                      anything already entered.
                    </div>
                  </div>
                  <Toggle
                    on={form.multicurrency_enabled}
                    onChange={(v) => set({ multicurrency_enabled: v })}
                    label="Use other currencies"
                  />
                </div>

                <div className="toggle-row">
                  <div className="toggle-copy">
                    <div className="toggle-title">Accountant mode</div>
                    <div className="toggle-desc">
                      Shows nominal codes, journals and debit and credit
                      columns. Leave off for a plainer view.
                    </div>
                  </div>
                  <Toggle
                    on={form.accountant_mode}
                    onChange={(v) => set({ accountant_mode: v })}
                    label="Accountant mode"
                  />
                </div>
              </div>
            </div>
          </>
        )}

        {/* ---------------------------------------------------------- */}
        {step === 5 && (
          <>
            <h1>Ready to go</h1>
            <p className="hint mt-md" style={{ marginBottom: '1.25rem' }}>
              Check this over. Everything except the business type can be
              changed afterwards in Settings.
            </p>

            <div className="card">
              <table className="table table-flush">
                <tbody>
                  <tr className="no-hover"><td className="muted">Business</td><td><strong>{form.name}</strong></td></tr>
                  <tr className="no-hover"><td className="muted">Type</td><td>{ENTITY_TYPES.find((t) => t.code === form.entity_type_code)?.title}</td></tr>
                  <tr className="no-hover"><td className="muted">Year end</td><td>{form.year_end_day} {MONTHS[form.year_end_month - 1]}</td></tr>
                  <tr className="no-hover"><td className="muted">First year</td><td>{shortDate(form.books_start_date)} to {firstYearEnd ? shortDate(firstYearEnd) : ''} <span className="muted">({periods} periods)</span></td></tr>
                  <tr className="no-hover"><td className="muted">VAT</td><td>{form.vat_enabled ? `Registered, ${VAT_SCHEMES.find((s) => s.code === form.vat_scheme)?.title.toLowerCase()} scheme` : 'Not registered'}</td></tr>
                  <tr className="no-hover"><td className="muted">Stock</td><td>{form.holds_stock ? (form.stock_control_enabled ? 'Held and tracked' : 'Held, counted by hand') : 'None'}</td></tr>
                  <tr className="no-hover"><td className="muted">Currency</td><td>{form.base_currency_code}{form.multicurrency_enabled ? ', others allowed' : ''}</td></tr>
                </tbody>
              </table>
            </div>

            <p className="hint mt-md">
              Setting up creates your chart of accounts, your VAT codes and{' '}
              {periods} monthly periods for the first year.
            </p>
          </>
        )}

        {/* ---------------------------------------------------------- */}
        <div className="btn-row mt-lg">
          {step > 0 && (
            <button className="btn btn-secondary" onClick={() => setStep(step - 1)} disabled={busy}>
              Back
            </button>
          )}
          <div className="spacer" />
          {step < STEPS.length - 1 ? (
            <button className="btn btn-primary" onClick={() => setStep(step + 1)} disabled={!canContinue()}>
              Continue
            </button>
          ) : (
            <button className="btn btn-primary" onClick={create} disabled={busy}>
              {busy ? 'Setting up…' : 'Create my accounts'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

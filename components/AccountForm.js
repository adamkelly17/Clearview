'use client';

import { useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { money, readableError, shortDate } from '@/lib/format';

/**
 * Adding or changing a category.
 *
 * The code is suggested from the conventional range for whichever kind is
 * chosen, and re-suggested if the kind changes — but it stays editable,
 * because anyone arriving from another system will have their own scheme
 * and being told what their codes must be is infuriating.
 *
 * When editing, the usage of the account is fetched first so the warnings
 * are about this account rather than generic. An account with three
 * hundred transactions against it deserves a different tone from one
 * created two minutes ago.
 */
export default function AccountForm({
  orgId, types, existing = [], vatCodes, pro, currencyCode,
  editing = null, usage = null,
}) {
  const router = useRouter();
  const isEdit = Boolean(editing);

  const [form, setForm] = useState({
    name: editing?.name || '',
    friendly_name: editing?.friendly_name || '',
    description: editing?.description || '',
    account_type_code: editing?.account_type_code || 'overhead',
    code: editing?.code || '',
    default_vat_code_id: editing?.default_vat_code_id || '',
    active: editing?.active ?? true,
  });

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const set = (patch) => setForm((f) => ({ ...f, ...patch }));

  const chosen = useMemo(
    () => types.find((t) => t.code === form.account_type_code),
    [types, form.account_type_code]
  );

  /* Everything already sitting in the range for the chosen kind, so a code
     can be picked with its neighbours in view. Choosing 7302 because the
     other vehicle costs are at 7300–7304 is the whole point of a coded
     chart, and impossible to do blind. */
  const inRange = useMemo(() => {
    if (!chosen?.code_range_start) return [];

    const start = chosen.code_range_start;
    const end = chosen.code_range_end;

    return existing
      .filter((a) => {
        const n = Number(a.code);
        return Number.isFinite(n) && n >= start && n <= end;
      })
      .sort((a, b) => Number(a.code) - Number(b.code));
  }, [existing, chosen]);

  /* The first handful of free codes in the range, offered as one click
     each. More than a handful is noise. */
  const freeCodes = useMemo(() => {
    if (!chosen?.code_range_start) return [];

    const taken = new Set(existing.map((a) => a.code));
    const out = [];

    for (let n = chosen.code_range_start; n <= chosen.code_range_end && out.length < 8; n += 1) {
      const code = String(n).padStart(4, '0');
      if (!taken.has(code)) out.push(code);
    }
    return out;
  }, [existing, chosen]);

  /* Live clash check, so a duplicate is caught while typing rather than on
     submit. The account being edited does not clash with itself. */
  const clash = useMemo(() => {
    const code = form.code.trim();
    if (!code) return null;
    return existing.find((a) => a.code === code && a.id !== editing?.id) || null;
  }, [existing, form.code, editing]);

  /* Fill in a code whenever the kind changes, but only on a new account
     and only where codes are on show. Renumbering a live account is a
     decision rather than a default, and with accountant mode off the
     database assigns one on save — see assign_account_code(). */
  useEffect(() => {
    if (!pro || isEdit) return undefined;

    let cancelled = false;

    createClient()
      .rpc('suggest_account_code', {
        p_organisation_id: orgId,
        p_account_type_code: form.account_type_code,
      })
      .then(({ data }) => {
        if (!cancelled && data) setForm((f) => ({ ...f, code: data }));
      });

    return () => { cancelled = true; };
  }, [form.account_type_code, orgId, isEdit, pro]);

  const used = Number(usage?.transactions || 0) > 0;
  const classChanged =
    isEdit && chosen && editing.class && chosen.class !== editing.class;

  const ready =
    form.name.trim()
    && form.account_type_code
    && (!pro || form.code.trim())
    && !clash;

  async function save() {
    setBusy(true);
    setError(null);

    const supabase = createClient();
    const payload = {
      ...(isEdit ? { id: editing.id } : { organisation_id: orgId }),
      name: form.name.trim(),
      friendly_name: form.friendly_name.trim() || null,
      description: form.description.trim() || null,
      account_type_code: form.account_type_code,
      // Omitted entirely when codes are hidden, so the database assigns
      // one atomically rather than the browser guessing.
      ...(pro || isEdit ? { code: form.code.trim() } : {}),
      default_vat_code_id: form.default_vat_code_id || null,
      active: form.active,
    };

    const { data, error: saveError } = isEdit
      ? await supabase.rpc('update_account', { p_config: payload })
      : await supabase.rpc('create_account', { p_config: payload });

    setBusy(false);

    if (saveError) {
      setError(readableError(saveError));
      return;
    }

    router.push(`/accounts/${isEdit ? editing.id : data}`);
    router.refresh();
  }

  async function remove() {
    setBusy(true);
    setError(null);

    const { error: delError } = await createClient().rpc('delete_account', {
      p_account_id: editing.id,
    });

    setBusy(false);

    if (delError) {
      setError(readableError(delError));
      setConfirmDelete(false);
      return;
    }

    router.push('/accounts');
    router.refresh();
  }

  // Grouped so the select reads like a chart of accounts.
  const grouped = useMemo(() => {
    const g = new Map();
    for (const t of types) {
      const key = `${t.report === 'balance_sheet' ? 'Balance sheet' : 'Profit and loss'} · ${t.report_group}`;
      if (!g.has(key)) g.set(key, []);
      g.get(key).push(t);
    }
    return [...g.entries()];
  }, [types]);

  return (
    <>
      {error && <div className="notice notice-error">{error}</div>}

      {isEdit && used && (
        <div className="notice notice-caution">
          This has <strong>{usage.transactions} transaction
          {usage.transactions === 1 ? '' : 's'}</strong> against it
          {usage.first_used && <> since {shortDate(usage.first_used)}</>}, with a
          balance of {money(usage.balance, { currency: currencyCode })}. Renaming
          it is safe. Moving it to a different part of the accounts will change
          what your reports have always said, so only do that if it was filed
          wrongly to begin with.
        </div>
      )}

      <div className="card">
        <div className="card-head"><h2>What is it?</h2></div>
        <div className="card-body">
          <div className="grid grid-2">
            <label className="field">
              <span className="label">Name</span>
              <input
                className="input"
                autoFocus={!isEdit}
                value={form.name}
                onChange={(e) => set({ name: e.target.value })}
                placeholder="Van hire"
              />
              {pro && (
                <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                  As it will appear on the trial balance and reports.
                </span>
              )}
            </label>

            <label className="field">
              <span className="label">
                Plain-English name <span className="muted">(optional)</span>
              </span>
              <input
                className="input"
                value={form.friendly_name}
                onChange={(e) => set({ friendly_name: e.target.value })}
                placeholder={form.name || 'Van hire'}
              />
              <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                Shown when accountant mode is off. Left blank, the name above is
                used.
              </span>
            </label>
          </div>

          <div className={pro ? 'grid grid-2' : ''}>
            <label className="field">
              <span className="label">What kind of category</span>
              <select
                className="select"
                value={form.account_type_code}
                onChange={(e) => set({ account_type_code: e.target.value })}
                disabled={isEdit && editing.is_system}
              >
                {grouped.map(([group, items]) => (
                  <optgroup key={group} label={group}>
                    {items.map((t) => (
                      <option key={t.code} value={t.code}>
                        {pro ? t.name : t.friendly_name}
                      </option>
                    ))}
                  </optgroup>
                ))}
              </select>
              {chosen && (
                <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                  Appears under <strong>{chosen.report_group}</strong> on the{' '}
                  {chosen.report === 'balance_sheet' ? 'balance sheet' : 'profit and loss'}.
                </span>
              )}
            </label>

            {pro ? (
              <label className="field">
                <span className="label">Code</span>
                <input
                  className="input code"
                  value={form.code}
                  onChange={(e) => set({ code: e.target.value })}
                  disabled={isEdit && editing.is_system}
                  aria-invalid={Boolean(clash)}
                />
                {clash ? (
                  <span
                    className="hint"
                    style={{ display: 'block', marginTop: '0.3125rem', color: 'var(--negative)' }}
                  >
                    {clash.code} is already <strong>{clash.name}</strong>. Pick another.
                  </span>
                ) : (
                  <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                    {chosen?.range_hint
                      ? `${chosen.range_hint} is the usual range for this kind.`
                      : 'Any code not already in use.'}
                  </span>
                )}
              </label>
            ) : null}
          </div>

          {pro && chosen?.code_range_start && (
            <div className="code-map">
              <div className="code-map-head">
                <span className="eyebrow">
                  Already in {chosen.range_hint}
                </span>
                {freeCodes.length > 0 && (
                  <span className="hint">
                    Free:{' '}
                    {freeCodes.map((c, i) => (
                      <span key={c}>
                        {i > 0 && ' '}
                        <button
                          type="button"
                          className="code-chip"
                          onClick={() => set({ code: c })}
                        >
                          {c}
                        </button>
                      </span>
                    ))}
                  </span>
                )}
              </div>

              {inRange.length === 0 ? (
                <p className="hint" style={{ margin: 0 }}>
                  Nothing in this range yet.
                </p>
              ) : (
                <ul className="code-list">
                  {inRange.map((a) => (
                    <li
                      key={a.id}
                      className={a.code === form.code.trim() ? 'code-list-clash' : undefined}
                    >
                      <span className="code">{a.code}</span>
                      <span className="code-name">
                        {a.name}
                        {a.is_system && <span className="pill">auto</span>}
                        {!a.active && <span className="pill">off</span>}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}

          {classChanged && (
            <div className="notice notice-error">
              That moves this from {editing.class} to {chosen.class}, which are
              different kinds of thing altogether. It will be refused if the
              account has ever been used — move the balance with a journal
              instead.
            </div>
          )}

          {vatCodes.length > 0 && (
            <label className="field">
              <span className="label">
                Usual VAT treatment <span className="muted">(optional)</span>
              </span>
              <select
                className="select"
                style={{ maxWidth: '22rem' }}
                value={form.default_vat_code_id}
                onChange={(e) => set({ default_vat_code_id: e.target.value })}
              >
                <option value="">No default</option>
                {vatCodes.map((v) => (
                  <option key={v.id} value={v.id}>
                    {pro ? `${v.code} — ${v.name} (${v.rate}%)` : v.friendly_name}
                  </option>
                ))}
              </select>
              <span className="hint" style={{ display: 'block', marginTop: '0.3125rem' }}>
                Filled in automatically when this category is picked on an invoice
                or a bill.
              </span>
            </label>
          )}

          <label className="field" style={{ marginBottom: 0 }}>
            <span className="label">
              Note <span className="muted">(optional)</span>
            </span>
            <input
              className="input"
              value={form.description}
              onChange={(e) => set({ description: e.target.value })}
              placeholder="What belongs in here, and what does not"
            />
          </label>
        </div>
      </div>

      {isEdit && !editing.is_system && (
        <div className="card mt-lg">
          <div className="card-body">
            <div className="toggle-row">
              <div className="toggle-copy">
                <div className="toggle-title">In use</div>
                <div className="toggle-desc">
                  Switch off to take it out of the pickers. Everything already
                  posted to it stays exactly as it is, and it keeps appearing on
                  reports while it has a balance.
                </div>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={form.active}
                aria-label="In use"
                className={`switch ${form.active ? 'switch-on' : ''}`}
                onClick={() => set({ active: !form.active })}
              />
            </div>

            {usage?.can_delete ? (
              <div style={{ marginTop: '1rem' }}>
                {confirmDelete ? (
                  <div className="notice notice-error" style={{ marginBottom: 0 }}>
                    <strong>Remove {form.code} for good?</strong> Nothing has ever
                    been posted to it, so there is no history to lose.
                    <div className="btn-row" style={{ marginTop: '0.75rem' }}>
                      <button
                        className="btn btn-secondary btn-sm"
                        onClick={() => setConfirmDelete(false)}
                        disabled={busy}
                      >
                        Keep it
                      </button>
                      <div className="spacer" />
                      <button className="btn btn-danger btn-sm" onClick={remove} disabled={busy}>
                        {busy ? 'Removing…' : 'Remove it'}
                      </button>
                    </div>
                  </div>
                ) : (
                  <>
                    <button
                      className="btn btn-danger btn-sm"
                      onClick={() => setConfirmDelete(true)}
                    >
                      Remove this category
                    </button>
                    <p className="hint" style={{ marginTop: '0.5rem', marginBottom: 0 }}>
                      Possible only because nothing has ever been posted to it.
                    </p>
                  </>
                )}
              </div>
            ) : (
              <p className="hint" style={{ marginTop: '1rem', marginBottom: 0 }}>
                This cannot be removed —{' '}
                {Number(usage?.transactions) > 0
                  ? `${usage.transactions} transaction${usage.transactions === 1 ? '' : 's'} have been posted to it`
                  : Number(usage?.contacts_defaulting_to_it) > 0
                  ? 'a customer or supplier uses it as their default'
                  : Number(usage?.bank_rules) > 0
                  ? 'a bank rule codes to it'
                  : editing.is_system
                  ? 'it is part of the system'
                  : 'something still points at it'}
                . Switch it off instead.
              </p>
            )}
          </div>
        </div>
      )}

      <div className="btn-row mt-lg">
        <button className="btn btn-secondary" onClick={() => router.back()} disabled={busy}>
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-primary" onClick={save} disabled={!ready || busy}>
          {busy ? 'Saving…' : isEdit ? 'Save changes' : 'Add the category'}
        </button>
      </div>

      {!ready && (
        <p className="hint mt-md">
          {!form.name.trim()
            ? 'Give it a name to continue.'
            : clash
            ? `Code ${clash.code} is already taken by ${clash.name}.`
            : 'A code is needed.'}
        </p>
      )}
    </>
  );
}

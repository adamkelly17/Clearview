'use client';

import { useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { money, readableError, shortDate, today } from '@/lib/format';

/**
 * Recording money in or out, and deciding what it pays off.
 *
 * The allocation grid is the part that earns its keep: pick a contact
 * and their outstanding items appear, with a running figure showing how
 * much of the payment is still unaccounted for. Anything left over sits
 * on account rather than being forced somewhere it does not belong.
 */
export default function PaymentForm({ orgId, ledger, contacts, bankAccounts, pro, currencyCode }) {
  const router = useRouter();
  const isSales = ledger === 'sales';

  const [contactId, setContactId] = useState('');
  const [bankId, setBankId] = useState(bankAccounts[0]?.id || '');
  const [date, setDate] = useState(today());
  const [amount, setAmount] = useState('');
  const [reference, setReference] = useState('');
  const [items, setItems] = useState([]);
  const [alloc, setAlloc] = useState({});
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  /* Outstanding items for the chosen contact. */
  useEffect(() => {
    if (!contactId) {
      setItems([]);
      setAlloc({});
      return;
    }

    setLoading(true);
    const supabase = createClient();

    supabase
      .from('ledger_item_outstanding')
      .select('id, date, due_date, reference, item_type, direction, gross_amount, outstanding_amount, days_overdue')
      .eq('organisation_id', orgId)
      .eq('contact_id', contactId)
      .eq('ledger', ledger)
      .eq('direction', isSales ? 'debit' : 'credit')
      .gt('outstanding_amount', 0)
      .order('due_date', { nullsFirst: false })
      .then(({ data, error }) => {
        setLoading(false);
        if (error) {
          setError(readableError(error));
          return;
        }
        setItems(data || []);
        setAlloc({});
      });
  }, [contactId, orgId, ledger, isSales]);

  const paymentAmount = Math.round((Number(amount) || 0) * 100) / 100;

  const allocated = useMemo(
    () =>
      Math.round(
        Object.values(alloc).reduce((s, v) => s + (Number(v) || 0), 0) * 100
      ) / 100,
    [alloc]
  );

  const unallocated = Math.round((paymentAmount - allocated) * 100) / 100;
  const overAllocated = allocated > paymentAmount + 0.001;

  /* Spread the payment across the oldest items first. */
  function allocateOldestFirst() {
    let remaining = paymentAmount;
    const next = {};

    for (const item of items) {
      if (remaining <= 0) break;
      const take = Math.min(remaining, Number(item.outstanding_amount));
      next[item.id] = take.toFixed(2);
      remaining = Math.round((remaining - take) * 100) / 100;
    }

    setAlloc(next);
  }

  function payInFull(item) {
    setAlloc((a) => ({ ...a, [item.id]: Number(item.outstanding_amount).toFixed(2) }));
  }

  async function post() {
    setBusy(true);
    setError(null);

    const allocations = Object.entries(alloc)
      .filter(([, v]) => Number(v) > 0)
      .map(([item_id, v]) => ({ item_id, amount: Number(v) }));

    const supabase = createClient();
    const { error } = await supabase.rpc('post_payment', {
      p_config: {
        organisation_id: orgId,
        ledger,
        contact_id: contactId,
        bank_account_id: bankId,
        date,
        amount: paymentAmount,
        reference: reference.trim() || null,
        ...(allocations.length ? { allocations } : {}),
      },
    });

    setBusy(false);

    if (error) {
      setError(readableError(error));
      return;
    }

    router.push(isSales ? '/customers' : '/suppliers');
    router.refresh();
  }

  const ready = contactId && bankId && paymentAmount > 0 && !overAllocated;

  if (bankAccounts.length === 0) {
    return (
      <div className="card">
        <div className="empty">
          <h3>No bank account set up</h3>
          <p>
            The chart of accounts includes a current account, savings, petty cash
            and a credit card. One of them needs to exist before money can move.
          </p>
        </div>
      </div>
    );
  }

  return (
    <>
      {error && <div className="notice notice-error">{error}</div>}

      <div className="card">
        <div className="card-body">
          <div className="grid grid-4">
            <label className="field">
              <span className="label">{isSales ? 'Customer' : 'Supplier'}</span>
              <select
                className="select"
                value={contactId}
                onChange={(e) => setContactId(e.target.value)}
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
              <span className="label">{isSales ? 'Paid into' : 'Paid from'}</span>
              <select
                className="select"
                value={bankId}
                onChange={(e) => setBankId(e.target.value)}
              >
                {bankAccounts.map((b) => (
                  <option key={b.id} value={b.id}>
                    {pro ? `${b.code} — ${b.name}` : b.friendly_name || b.name}
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
              <span className="label">Amount</span>
              <input
                className="input num"
                inputMode="decimal"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                placeholder="0.00"
              />
            </label>
          </div>

          <label className="field" style={{ maxWidth: '18rem', marginBottom: 0 }}>
            <span className="label">
              Reference <span className="muted">(optional)</span>
            </span>
            <input
              className="input"
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="BACS 0602"
            />
          </label>
        </div>
      </div>

      {contactId && (
        <div className="card mt-md">
          <div className="card-head">
            <h2>What does this pay off?</h2>
            {items.length > 0 && paymentAmount > 0 && (
              <button className="btn btn-secondary btn-sm" onClick={allocateOldestFirst}>
                Oldest first
              </button>
            )}
          </div>

          {loading ? (
            <div className="card-body">
              <p className="hint">Looking up what is outstanding…</p>
            </div>
          ) : items.length === 0 ? (
            <div className="empty" style={{ padding: '2.25rem 1.5rem' }}>
              <p>
                Nothing outstanding for this {isSales ? 'customer' : 'supplier'}.
                The payment will sit on account until there is something to match
                it against.
              </p>
            </div>
          ) : (
            <table className="table table-flush">
              <thead>
                <tr>
                  <th style={{ width: '7rem' }}>Date</th>
                  <th>Reference</th>
                  <th style={{ width: '7rem' }}>Due</th>
                  <th className="num" style={{ width: '8rem' }}>Outstanding</th>
                  <th className="num" style={{ width: '8.5rem' }}>Pay</th>
                  <th style={{ width: '5rem' }} />
                </tr>
              </thead>
              <tbody>
                {items.map((item) => (
                  <tr key={item.id}>
                    <td className="nowrap">{shortDate(item.date)}</td>
                    <td className="code">{item.reference || item.item_type}</td>
                    <td className="nowrap">
                      {item.due_date ? shortDate(item.due_date) : ''}
                      {item.days_overdue > 0 && (
                        <>
                          {' '}
                          <span className="pill pill-negative">
                            {item.days_overdue}d
                          </span>
                        </>
                      )}
                    </td>
                    <td>
                      <span className="num">{money(item.outstanding_amount)}</span>
                    </td>
                    <td>
                      <input
                        className="input num"
                        inputMode="decimal"
                        style={{ padding: '0.3125rem 0.5rem' }}
                        value={alloc[item.id] || ''}
                        onChange={(e) =>
                          setAlloc((a) => ({ ...a, [item.id]: e.target.value }))
                        }
                        placeholder="0.00"
                      />
                    </td>
                    <td>
                      <button className="btn btn-ghost btn-sm" onClick={() => payInFull(item)}>
                        All
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan={3}>Allocated</td>
                  <td />
                  <td>
                    <span className="num">{money(allocated)}</span>
                  </td>
                  <td />
                </tr>
              </tfoot>
            </table>
          )}
        </div>
      )}

      {paymentAmount > 0 && (
        <div className={`notice mt-md ${overAllocated ? 'notice-error' : unallocated > 0 ? 'notice-caution' : 'notice-info'}`}>
          {overAllocated ? (
            <>
              You have allocated {money(allocated, { currency: currencyCode })} but the
              payment is only {money(paymentAmount, { currency: currencyCode })}. Reduce
              one of the lines.
            </>
          ) : unallocated > 0 ? (
            <>
              {money(unallocated, { currency: currencyCode })} of this payment is not
              allocated to anything. It will sit on account and can be matched
              later.
            </>
          ) : (
            <>Fully allocated.</>
          )}
        </div>
      )}

      <div className="btn-row mt-md">
        <button className="btn btn-secondary" onClick={() => router.back()} disabled={busy}>
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-primary" onClick={post} disabled={!ready || busy}>
          {busy ? 'Recording…' : isSales ? 'Record the receipt' : 'Record the payment'}
        </button>
      </div>
    </>
  );
}

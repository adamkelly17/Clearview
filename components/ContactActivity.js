'use client';

import { useRouter, usePathname, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import Money from '@/components/Money';
import { money, shortDate } from '@/lib/format';

const ITEM_LABELS = {
  invoice: 'Invoice',
  credit_note: 'Credit note',
  payment: 'Payment',
  payment_on_account: 'On account',
  write_off: 'Written off',
  discount: 'Discount',
  opening_balance: 'Opening balance',
  contra: 'Void',
};

/**
 * A contact's activity.
 *
 * Defaults to what is still unpaid, because that is the question being
 * asked nearly every time the screen is opened. The toggle switches to
 * the full statement, which is where settled items, voided documents and
 * their replacements appear.
 *
 * The running balance only shows in the full view. A running balance over
 * a filtered list is worse than none at all — it looks authoritative and
 * is wrong.
 */
export default function ContactActivity({ rows, showAll, currencyCode, pro }) {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();

  function toggle(next) {
    const q = new URLSearchParams(params.toString());
    if (next) q.set('view', 'all');
    else q.delete('view');
    router.push(`${pathname}${q.toString() ? `?${q}` : ''}`);
  }

  const total = rows.reduce(
    (sum, r) =>
      sum +
      (r.direction === 'debit'
        ? Number(r.outstanding_amount)
        : -Number(r.outstanding_amount)),
    0
  );

  const closing = rows.length ? Number(rows[rows.length - 1].running_balance) : 0;

  return (
    <>
      <div className="card-head">
        <h2>{showAll ? 'All transactions' : 'Outstanding'}</h2>
        <label className="row" style={{ gap: '0.5rem', cursor: 'pointer' }}>
          <input
            type="checkbox"
            checked={showAll}
            onChange={(e) => toggle(e.target.checked)}
          />
          <span className="small">Show everything, including settled and voided</span>
        </label>
      </div>

      {rows.length === 0 ? (
        <div className="empty" style={{ padding: '2.5rem 1.5rem' }}>
          <p>
            {showAll
              ? 'Nothing recorded against this account yet.'
              : 'Nothing outstanding. Tick the box above to see settled items.'}
          </p>
        </div>
      ) : (
        <table className="table table-flush">
          <thead>
            <tr>
              <th style={{ width: '7rem' }}>Date</th>
              <th style={{ width: '8rem' }}>Reference</th>
              <th>Type</th>
              <th style={{ width: '8rem' }}>Due</th>
              <th className="num" style={{ width: '8rem' }}>Amount</th>
              <th className="num" style={{ width: '8rem' }}>Outstanding</th>
              {showAll && <th className="num" style={{ width: '8rem' }}>Balance</th>}
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const voided = r.document_status === 'void';
              const overdue =
                !voided && Number(r.outstanding_amount) > 0 && r.days_overdue > 0;

              return (
                <tr key={r.item_id} className={voided ? 'row-voided' : undefined}>
                  <td className="nowrap">{shortDate(r.date)}</td>
                  <td className="code">{r.reference || ''}</td>
                  <td>
                    {ITEM_LABELS[r.item_type] || r.item_type}
                    {voided && (
                      <>
                        {' '}
                        <span className="pill pill-negative">
                          {r.replaced_by ? `Replaced by ${r.replaced_by}` : 'Voided'}
                        </span>
                      </>
                    )}
                    {!voided && r.settlement_status === 'part_settled' && (
                      <> <span className="pill pill-caution">Part paid</span></>
                    )}
                    {!voided && r.settlement_status === 'settled' && (
                      <> <span className="pill pill-accent">Settled</span></>
                    )}
                  </td>
                  <td className="nowrap small">
                    {r.due_date ? shortDate(r.due_date) : ''}
                    {overdue && (
                      <> <span className="pill pill-negative">{r.days_overdue}d</span></>
                    )}
                  </td>
                  <td>
                    <span
                      className={`num ${r.direction === 'credit' ? 'num-positive' : ''}`}
                    >
                      {r.direction === 'credit' ? '−' : ''}
                      {money(r.gross_amount)}
                    </span>
                  </td>
                  <td><Money value={r.outstanding_amount} blankZero /></td>
                  {showAll && <td><Money value={r.running_balance} /></td>}
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr>
              <td colSpan={showAll ? 5 : 5}>
                {showAll ? 'Closing balance' : 'Total outstanding'}
              </td>
              <td>
                <Money value={showAll ? closing : total} />
              </td>
              {showAll && <td><Money value={closing} /></td>}
            </tr>
          </tfoot>
        </table>
      )}
    </>
  );
}

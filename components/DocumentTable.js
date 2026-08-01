import Link from 'next/link';
import Money from '@/components/Money';
import VoidButton from '@/components/VoidButton';
import { shortDate } from '@/lib/format';

const STATUS = {
  settled: { label: 'Paid', className: 'pill-accent' },
  part_settled: { label: 'Part paid', className: 'pill-caution' },
  outstanding: { label: 'Outstanding', className: '' },
};

/** Shared list for invoices, credit notes and bills. */
export default function DocumentTable({ rows, pro, emptyTitle, emptyBody, newHref, newLabel }) {
  if (rows.length === 0) {
    return (
      <div className="empty">
        <h3>{emptyTitle}</h3>
        <p>{emptyBody}</p>
        <Link href={newHref} className="btn btn-primary mt-md">{newLabel}</Link>
      </div>
    );
  }

  return (
    <table className="table table-flush">
      <thead>
        <tr>
          <th style={{ width: '7rem' }}>Date</th>
          <th style={{ width: '9rem' }}>Number</th>
          <th>Name</th>
          <th style={{ width: '7rem' }}>Due</th>
          <th className="num" style={{ width: '8rem' }}>Total</th>
          <th className="num" style={{ width: '8rem' }}>Outstanding</th>
          <th style={{ width: '7.5rem' }}>Status</th>
          <th style={{ width: '5rem', position: 'relative' }} />
        </tr>
      </thead>
      <tbody>
        {rows.map((d) => {
          const item = d.ledger_item;
          const status = STATUS[d.settlement_status] || STATUS.outstanding;
          const voided = d.status === 'void';
          const overdue =
            !voided &&
            d.settlement_status !== 'settled' &&
            d.due_date &&
            new Date(d.due_date) < new Date();

          return (
            <tr key={d.id} className={voided ? 'row-voided' : undefined}>
              <td className="nowrap">{shortDate(d.date)}</td>
              <td className="code">{d.number}</td>
              <td>
                {d.contact?.name}
                {d.doc_type === 'SC' || d.doc_type === 'PC' ? (
                  <> <span className="pill">Credit note</span></>
                ) : null}
              </td>
              <td className="nowrap small">
                {d.due_date ? shortDate(d.due_date) : ''}
              </td>
              <td><Money value={d.gross_total} /></td>
              <td><Money value={voided ? 0 : d.outstanding_amount || 0} blankZero /></td>
              <td>
                {voided ? (
                  <span className="pill pill-negative" title={d.void_reason || 'Voided'}>
                    Voided
                  </span>
                ) : (
                  <span className={`pill ${overdue ? 'pill-negative' : status.className}`}>
                    {overdue ? 'Overdue' : status.label}
                  </span>
                )}
              </td>
              <td style={{ position: 'relative' }}>
                {!voided && d.settlement_status === 'outstanding' && (
                  <VoidButton documentId={d.id} number={d.number} />
                )}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

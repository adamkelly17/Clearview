import Money from '@/components/Money';

const COLUMNS = [
  ['current_amount', 'Current'],
  ['days_30', '1–30 days'],
  ['days_60', '31–60 days'],
  ['days_90', '61–90 days'],
  ['older', 'Over 90 days'],
];

/**
 * Standard 30/60/90 ageing, measured from the due date. Unallocated
 * credit notes and payments on account show as negatives in the current
 * column, so the total always agrees with the control account.
 */
export default function AgedReport({ rows, pro, showLimit = false }) {
  if (rows.length === 0) {
    return (
      <div className="empty">
        <h3>Nothing outstanding</h3>
        <p>Everything is settled. This report fills up when something is unpaid.</p>
      </div>
    );
  }

  const totals = COLUMNS.reduce((acc, [key]) => {
    acc[key] = rows.reduce((s, r) => s + Number(r[key] || 0), 0);
    return acc;
  }, {});
  const grand = rows.reduce((s, r) => s + Number(r.total || 0), 0);

  return (
    <table className="table table-flush">
      <thead>
        <tr>
          {pro && <th style={{ width: '5rem' }}>Code</th>}
          <th>Name</th>
          {COLUMNS.map(([key, label]) => (
            <th key={key} className="num">{label}</th>
          ))}
          <th className="num">Total</th>
          {showLimit && <th style={{ width: '7rem' }}>Limit</th>}
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => {
          const overLimit =
            showLimit && r.credit_limit != null && Number(r.total) > Number(r.credit_limit);

          return (
            <tr key={r.contact_id}>
              {pro && <td className="code">{r.contact_code}</td>}
              <td>
                {r.contact_name}
                {r.oldest_due && new Date(r.oldest_due) < new Date() && (
                  <> <span className="pill pill-negative">Overdue</span></>
                )}
              </td>
              {COLUMNS.map(([key]) => (
                <td key={key}><Money value={r[key]} blankZero /></td>
              ))}
              <td><Money value={r.total} /></td>
              {showLimit && (
                <td>
                  {r.credit_limit != null && (
                    <span className={overLimit ? 'pill pill-negative' : 'pill'}>
                      {overLimit ? 'Over limit' : <Money value={r.credit_limit} />}
                    </span>
                  )}
                </td>
              )}
            </tr>
          );
        })}
      </tbody>
      <tfoot>
        <tr>
          <td colSpan={pro ? 2 : 1}>Total</td>
          {COLUMNS.map(([key]) => (
            <td key={key}><Money value={totals[key]} blankZero /></td>
          ))}
          <td><Money value={grand} /></td>
          {showLimit && <td />}
        </tr>
      </tfoot>
    </table>
  );
}

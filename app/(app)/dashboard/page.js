import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import { money, shortDate } from '@/lib/format';
import Money from '@/components/Money';

export const dynamic = 'force-dynamic';

/**
 * The overview.
 *
 * Three panels, each answering a question an owner actually asks: is the
 * work worth doing, can the bank figure be trusted, and can I afford
 * this. Everything else belongs on a report.
 *
 * The profit figures are laid out as a chain rather than as separate
 * cards, because sales, cost of sales and overheads are not independent
 * facts — the whole point is what each one leaves behind.
 */
export default async function DashboardPage() {
  const { supabase, org, features, currentYear } = await requireOrg();
  const ccy = org.base_currency_code;

  const from = currentYear?.start_date || `${new Date().getFullYear()}-01-01`;
  const to = currentYear?.end_date || new Date().toISOString().slice(0, 10);

  const [
    { data: pl }, { data: bank }, { data: wc },
    { data: recent }, { count: journalCount }, { data: nextYear },
  ] = await Promise.all([
    supabase.rpc('profit_summary', { p_organisation_id: org.id, p_from: from, p_to: to }),
    supabase.rpc('bank_summary', { p_organisation_id: org.id }),
    supabase.rpc('working_capital', { p_organisation_id: org.id }),
    supabase
      .from('journal')
      .select('id, date, description, journal_line(debit)')
      .eq('organisation_id', org.id)
      .order('date', { ascending: false })
      .order('journal_no', { ascending: false })
      .limit(6),
    supabase.from('journal').select('id', { count: 'exact', head: true })
      .eq('organisation_id', org.id),
    supabase.rpc('next_fiscal_year_preview', { p_organisation_id: org.id }),
  ]);

  const p = pl || {};
  const b = bank || {};
  const w = wc || {};
  const pct = (n) => (p.sales ? `${Math.round((n / p.sales) * 1000) / 10}%` : '');
  const stale = b.days_since_earliest != null && b.days_since_earliest > 30;

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Overview</h1>
          <p>{currentYear ? `Year to ${shortDate(currentYear.end_date)}` : 'No financial year is open'}</p>
        </div>
        <div className="btn-row">
          <Link href="/bills/new" className="btn btn-secondary">Enter a bill</Link>
          <Link href="/invoices/new" className="btn btn-primary">Raise an invoice</Link>
        </div>
      </div>

      {nextYear?.available && (nextYear.overdue || nextYear.days_remaining <= 30) && (
        <div className={`notice ${nextYear.overdue ? 'notice-caution' : 'notice-info'}`}>
          {nextYear.overdue ? (
            <>
              <strong>Your financial year has ended.</strong> Nothing can be posted
              after {shortDate(nextYear.previous_end)} until the next year is added.
            </>
          ) : (
            <>Your financial year ends in {nextYear.days_remaining} days.</>
          )}{' '}
          <Link href="/settings">
            Add {shortDate(nextYear.start_date)} to {shortDate(nextYear.end_date)}
          </Link>.
        </div>
      )}

      {journalCount === 0 && (
        <div className="notice notice-info">
          Your accounts are set up and empty. Add a customer, raise an invoice, and
          the figures here will start to move.
        </div>
      )}

      <div className="grid grid-2" style={{ alignItems: 'start' }}>
        {/* ============ How the business is doing ============ */}
        <div className="card">
          <div className="card-head">
            <h2>How the business is doing</h2>
            <span className="hint">Year to date</span>
          </div>

          <table className="table table-flush pl-table">
            <tbody>
              <tr className="no-hover">
                <td>Sales</td>
                <td><Money value={p.sales} /></td>
                <td className="pl-pct muted">{p.sales ? '100%' : ''}</td>
              </tr>
              <tr className="no-hover">
                <td className="muted">Cost of sales</td>
                <td><span className="num">({money(p.cost_of_sales)})</span></td>
                <td className="pl-pct muted">{pct(p.cost_of_sales)}</td>
              </tr>
              <tr className="no-hover pl-subtotal">
                <td>Gross profit</td>
                <td><Money value={p.gross_profit} /></td>
                <td className="pl-pct">{p.gross_margin == null ? '' : `${p.gross_margin}%`}</td>
              </tr>
              {Number(p.other_income) !== 0 && (
                <tr className="no-hover">
                  <td className="muted">Other income</td>
                  <td><Money value={p.other_income} /></td>
                  <td />
                </tr>
              )}
              <tr className="no-hover">
                <td className="muted">Overheads</td>
                <td><span className="num">({money(p.overheads)})</span></td>
                <td className="pl-pct muted">{pct(p.overheads)}</td>
              </tr>
              {Number(p.taxation) !== 0 && (
                <tr className="no-hover">
                  <td className="muted">Tax</td>
                  <td><span className="num">({money(p.taxation)})</span></td>
                  <td />
                </tr>
              )}
            </tbody>
            <tfoot>
              <tr>
                <td>{Number(p.net_profit) < 0 ? 'Loss' : 'Profit'}</td>
                <td>
                  <span className="num" style={{ color: Number(p.net_profit) < 0 ? 'var(--negative)' : 'var(--positive)' }}>
                    {money(Math.abs(Number(p.net_profit) || 0), { currency: ccy })}
                  </span>
                </td>
                <td className="pl-pct">{p.net_margin == null ? '' : `${p.net_margin}%`}</td>
              </tr>
            </tfoot>
          </table>

          <div className="card-body insight">
            <div className="eyebrow">Why gross profit matters</div>
            <p className="hint" style={{ marginTop: '0.375rem', marginBottom: 0 }}>
              Gross profit is what is left of your sales once you have paid for the
              work itself — materials, subcontractors, anything you would not have
              spent had the sale not happened. It tells you whether the work is
              worth doing at all.
              {p.gross_margin != null && (
                <> You are keeping <strong>{p.gross_margin}p of every pound</strong> you invoice.</>
              )}
              {' '}Overheads can be trimmed; a job that loses money before overheads
              will lose money however carefully the rest is run. Watch this
              percentage over time and take it seriously when it slips.
            </p>
          </div>
        </div>

        <div className="stack" style={{ gap: '1rem' }}>
          {/* ============ The bank ============ */}
          <div className="card">
            <div className="card-head">
              <h2>The bank</h2>
              <Link href="/banking" className="btn btn-open btn-sm">Open banking</Link>
            </div>
            <div className="card-body">
              <div className="eyebrow">
                Across {b.accounts || 0} account{Number(b.accounts) === 1 ? '' : 's'}
              </div>
              <div
                className="num"
                style={{
                  fontSize: '1.75rem', fontWeight: 600, marginTop: '0.25rem',
                  textAlign: 'left',
                  color: Number(b.balance) < 0 ? 'var(--negative)' : 'var(--ink)',
                }}
              >
                {money(b.balance, { currency: ccy })}
              </div>
            </div>

            <table className="table table-flush">
              <tbody>
                <tr className="no-hover">
                  <td>Not yet reconciled</td>
                  <td>
                    <span className={Number(b.unreconciled_count) > 0 ? 'num' : 'num num-nil'}>
                      {b.unreconciled_count || 0}
                    </span>
                  </td>
                  <td><Money value={b.unreconciled_total} blankZero /></td>
                </tr>
                {b.earliest_unreconciled && (
                  <tr className="no-hover">
                    <td className="muted">Oldest of those</td>
                    <td colSpan={2} style={{ textAlign: 'right' }}>
                      <span className="small">
                        {shortDate(b.earliest_unreconciled)}{' '}
                        <span className={`pill ${stale ? 'pill-negative' : ''}`}>
                          {b.days_since_earliest} days ago
                        </span>
                      </span>
                    </td>
                  </tr>
                )}
                {Number(b.statement_lines_to_do) > 0 && (
                  <tr className="no-hover">
                    <td className="muted">Statement lines to deal with</td>
                    <td colSpan={2} style={{ textAlign: 'right' }}>
                      <span className="pill pill-caution">{b.statement_lines_to_do}</span>
                    </td>
                  </tr>
                )}
              </tbody>
            </table>

            <div className="card-body" style={{ paddingTop: 0 }}>
              {stale ? (
                <div className="notice notice-caution" style={{ marginBottom: 0 }}>
                  Something has sat unreconciled since {shortDate(b.earliest_unreconciled)}.
                  Until the bank is matched up, treat the balance above as approximate.
                </div>
              ) : Number(b.unreconciled_count) === 0 && Number(b.accounts) > 0 ? (
                <p className="hint" style={{ margin: 0 }}>
                  Everything is reconciled, so this should match your bank exactly.
                </p>
              ) : null}
            </div>
          </div>

          {/* ============ Where you stand ============ */}
          <div className="card">
            <div className="card-head">
              <h2>Where you stand</h2>
              <span className="hint">If everything settled</span>
            </div>

            <table className="table table-flush pl-table">
              <tbody>
                <tr className="no-hover">
                  <td>In the bank</td>
                  <td><Money value={w.bank} /></td>
                  <td className="pl-pct" />
                </tr>
                <tr className="no-hover">
                  <td>
                    Owed to you
                    {Number(w.overdue_in) > 0 && (
                      <div className="hint">{money(w.overdue_in, { currency: ccy })} overdue</div>
                    )}
                  </td>
                  <td><Money value={w.owed_in} /></td>
                  <td className="pl-pct">
                    <Link href="/reports/aged-debtors" className="small">Aged</Link>
                  </td>
                </tr>
                <tr className="no-hover">
                  <td>
                    You owe
                    {Number(w.overdue_out) > 0 && (
                      <div className="hint">{money(w.overdue_out, { currency: ccy })} overdue</div>
                    )}
                  </td>
                  <td><span className="num">({money(w.owed_out)})</span></td>
                  <td className="pl-pct">
                    <Link href="/reports/aged-creditors" className="small">Aged</Link>
                  </td>
                </tr>
              </tbody>
              <tfoot>
                <tr>
                  <td>You would have</td>
                  <td>
                    <span className="num" style={{ color: Number(w.if_all_settled) < 0 ? 'var(--negative)' : 'var(--ink)' }}>
                      {money(w.if_all_settled, { currency: ccy })}
                    </span>
                  </td>
                  <td className="pl-pct" />
                </tr>
              </tfoot>
            </table>

            {w.chase_first && (
              <div className="card-body" style={{ paddingTop: '0.75rem' }}>
                <div className="eyebrow">Chase first</div>
                <div className="row row-between" style={{ marginTop: '0.375rem', gap: '0.75rem' }}>
                  <div style={{ minWidth: 0 }}>
                    <Link href={`/customers/${w.chase_first.contact_id}`} className="table-link">
                      {w.chase_first.name}
                    </Link>
                    <div className="hint">
                      {money(w.chase_first.amount, { currency: ccy })}
                      {w.chase_first.reference ? ` · ${w.chase_first.reference}` : ''}
                    </div>
                  </div>
                  <span className="pill pill-negative nowrap">
                    {w.chase_first.days_overdue} days late
                  </span>
                </div>
                <p className="hint" style={{ marginTop: '0.625rem', marginBottom: 0 }}>
                  Oldest rather than largest — age is what turns a debt into a bad one.
                </p>
              </div>
            )}

            {w.next_due && (
              <div className="card-body" style={{ paddingTop: w.chase_first ? 0 : '0.75rem' }}>
                <p className="hint" style={{ margin: 0 }}>
                  Next out: {w.next_due.name}, {money(w.next_due.amount, { currency: ccy })}{' '}
                  due {shortDate(w.next_due.due_date)}.
                </p>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* ============ Recent activity ============ */}
      <div className="card mt-lg">
        <div className="card-head">
          <h2>Recent activity</h2>
          <Link href="/journals" className="btn btn-open btn-sm">See all</Link>
        </div>
        {(recent || []).length === 0 ? (
          <div className="empty" style={{ padding: '2rem 1.25rem' }}>
            <p>Nothing recorded yet.</p>
          </div>
        ) : (
          <table className="table table-flush">
            <tbody>
              {(recent || []).map((j) => (
                <tr key={j.id}>
                  <td className="nowrap muted small" style={{ width: '6.5rem' }}>
                    {shortDate(j.date)}
                  </td>
                  <td>{j.description}</td>
                  <td>
                    <Money value={(j.journal_line || []).reduce((s, l) => s + Number(l.debit || 0), 0)} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

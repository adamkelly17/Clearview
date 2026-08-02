import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireOrg } from '@/lib/org';
import { money, shortDate } from '@/lib/format';
import Money from '@/components/Money';
import ReconcileSplit from './ReconcileSplit';
import UndoButton from './UndoButton';
import { suggestRulePattern } from '@/lib/statement';

export const dynamic = 'force-dynamic';

export default async function BankAccountPage({ params, searchParams }) {
  const { supabase, org, features } = await requireOrg();
  const pro = features.accountant_mode;
  const view = searchParams?.view || 'todo';

  const { data: bank } = await supabase
    .from('bank_account')
    .select('*, account(code, name, friendly_name)')
    .eq('organisation_id', org.id)
    .eq('id', params.id)
    .maybeSingle();

  if (!bank) notFound();

  const statusFilter =
    view === 'matched' ? ['matched'] : view === 'excluded' ? ['excluded'] : ['unmatched'];

  const [{ data: lines }, { data: recon }, { data: accounts }, { data: vatCodes }, { data: contacts }, { data: banks }, { data: statements }] =
    await Promise.all([
      supabase
        .from('statement_line')
        .select('*')
        .eq('bank_account_id', bank.id)
        .in('status', statusFilter)
        .order('date')
        .limit(300),
      supabase.rpc('bank_reconciliation', { p_bank_account_id: bank.id }),
      supabase
        .from('account')
        .select('id, code, name, friendly_name, account_type(class, report_group)')
        .eq('organisation_id', org.id)
        .eq('active', true)
        .eq('is_control', false)
        .eq('is_bank', false)
        .order('code'),
      supabase
        .from('vat_code')
        .select('id, code, name, friendly_name, rate, is_reverse_charge')
        .eq('organisation_id', org.id)
        .eq('active', true)
        .order('sort_order'),
      supabase
        .from('contact')
        .select('id, name, is_customer, is_supplier')
        .eq('organisation_id', org.id)
        .eq('active', true)
        .order('name'),
      supabase
        .from('bank_account')
        .select('id, name')
        .eq('organisation_id', org.id)
        .eq('active', true)
        .neq('id', bank.id)
        .order('name'),
      supabase
        .from('bank_statement')
        .select('id, name, from_date, to_date, line_count, closing_balance')
        .eq('bank_account_id', bank.id)
        .order('to_date', { ascending: false })
        .limit(5),
    ]);

  /* Suggestions for every line on screen, in one round trip. The old
     screen fetched them per row on expand, which meant you could not see
     what was waiting without opening each one. */
  const lineIds = (lines || []).map((l) => l.id);

  const { data: suggestions } = lineIds.length && view === 'todo'
    ? await supabase.rpc('suggest_matches_bulk', { p_line_ids: lineIds })
    : { data: [] };

  const suggestionsByLine = {};
  for (const s of suggestions || []) {
    (suggestionsByLine[s.statement_line_id] ||= []).push(s);
  }

  /* A starting pattern per line, so ticking "do this automatically" does
     not begin with an empty box. Computed here rather than in the
     database — it is a pure string function and one round trip per row
     would be absurd. */
  const withPatterns = (view === 'todo' ? lines || [] : []).map((l) => ({
    ...l,
    suggested_pattern: suggestRulePattern(l.description),
  }));

  const r = (recon || [])[0] || {};
  const difference = Number(r.difference || 0);
  const reconciled = Math.abs(difference) < 0.005 && Number(r.unmatched_lines || 0) === 0;

  const TABS = [
    ['todo', 'To deal with', Number(r.unmatched_lines || 0)],
    ['matched', 'Matched', null],
    ['excluded', 'Ignored', null],
  ];

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <div className="eyebrow">
            {pro ? `${bank.account?.code} · ` : ''}
            {bank.sort_code ? `${bank.sort_code} ${bank.account_number || ''}` : 'Bank account'}
          </div>
          <h1>{bank.name}</h1>
          <p>
            {vatCodes?.length
              ? 'Match each line against what is already recorded, or code it here.'
              : 'Match each line against what is already recorded.'}
          </p>
        </div>
        <div className="btn-row">
          <Link href="/banking" className="btn btn-secondary">All accounts</Link>
          <Link href={`/banking/${bank.id}/import`} className="btn btn-primary">
            Import a statement
          </Link>
        </div>
      </div>

      <div className="grid grid-4">
        <div className="card"><div className="card-body">
          <div className="eyebrow">Balance in Clearview</div>
          <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(r.ledger_balance || 0, { currency: org.base_currency_code })}
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Statement says</div>
          <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {r.statement_balance == null
              ? '—'
              : money(r.statement_balance, { currency: org.base_currency_code })}
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Difference</div>
          <div
            className="num"
            style={{
              fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left',
              color: Math.abs(difference) > 0.005 ? 'var(--caution)' : 'var(--positive)',
            }}
          >
            {money(difference, { currency: org.base_currency_code })}
          </div>
        </div></div>
        <div className="card"><div className="card-body">
          <div className="eyebrow">Not yet reconciled</div>
          <div className="num" style={{ fontSize: '1.375rem', fontWeight: 600, marginTop: '0.25rem', textAlign: 'left' }}>
            {money(r.unreconciled_total || 0)}
          </div>
          <div className="hint" style={{ marginTop: '0.1875rem' }}>
            {r.unreconciled_count || 0} transaction{Number(r.unreconciled_count) === 1 ? '' : 's'}
          </div>
        </div></div>
      </div>

      {r.statement_balance != null && (
        <div className={`notice mt-md ${reconciled ? 'notice-info' : 'notice-caution'}`}>
          {reconciled ? (
            <>This account is reconciled — the statement and the ledger agree.</>
          ) : (
            <>
              The statement closes at{' '}
              {money(r.statement_balance, { currency: org.base_currency_code })} and Ledger
              shows {money(r.ledger_balance || 0, { currency: org.base_currency_code })}. The
              gap closes as you deal with the lines below.
            </>
          )}
        </div>
      )}

      <div className={view === 'todo' ? 'mt-md' : 'card mt-md'}>
        <div className="card-head" style={view === 'todo' ? { padding: '0 0 0.75rem' } : undefined}>
          <div className="btn-row">
            {TABS.map(([key, label, count]) => (
              <Link
                key={key}
                href={`/banking/${bank.id}?view=${key}`}
                className={`btn btn-sm ${view === key ? 'btn-primary' : 'btn-ghost'}`}
              >
                {label}
                {count ? ` (${count})` : ''}
              </Link>
            ))}
          </div>
        </div>

        {view === 'todo' ? null : (lines || []).length === 0 ? (
          <div className="empty" style={{ padding: '2.5rem 1.5rem' }}>
            <p>Nothing here.</p>
          </div>
        ) : (
          <table className="table table-flush">
            <thead>
              <tr>
                <th style={{ width: '7rem' }}>Date</th>
                <th>Description</th>
                <th className="num" style={{ width: '8rem' }}>Amount</th>
                <th>{view === 'excluded' ? 'Reason' : 'Matched'}</th>
                <th style={{ width: '5rem' }} />
              </tr>
            </thead>
            <tbody>
              {(lines || []).map((l) => (
                <tr key={l.id}>
                  <td className="nowrap">{shortDate(l.date)}</td>
                  <td className="small">{l.description}</td>
                  <td>
                    <span className={`num ${Number(l.amount) > 0 ? 'num-positive' : 'num-negative'}`}>
                      {money(l.amount)}
                    </span>
                  </td>
                  <td className="small muted">
                    {view === 'excluded'
                      ? l.status_detail || 'Ignored'
                      : l.matched_at
                      ? shortDate(l.matched_at)
                      : ''}
                  </td>
                  <td className="actions" style={{ position: 'relative' }}>
                    <UndoButton
                      lineId={l.id}
                      createdSomething={Boolean(l.created_journal_id)}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {view === 'todo' && (
          <ReconcileSplit
            lines={withPatterns}
            suggestionsByLine={suggestionsByLine}
            orgId={org.id}
            bankAccountId={bank.id}
            accounts={accounts || []}
            vatCodes={vatCodes || []}
            contacts={contacts || []}
            bankAccounts={banks || []}
            pro={pro}
            vatEnabled={features.vat_enabled}
          />
        )}
      </div>

      {(statements || []).length > 0 && (
        <div className="card mt-lg">
          <div className="card-head"><h2>Statements imported</h2></div>
          <table className="table table-flush">
            <thead>
              <tr>
                <th>Statement</th>
                <th style={{ width: '7rem' }}>From</th>
                <th style={{ width: '7rem' }}>To</th>
                <th className="num" style={{ width: '5rem' }}>Lines</th>
                <th className="num" style={{ width: '9rem' }}>Closing</th>
              </tr>
            </thead>
            <tbody>
              {(statements || []).map((st) => (
                <tr key={st.id}>
                  <td>{st.name}</td>
                  <td className="nowrap small">{st.from_date ? shortDate(st.from_date) : ''}</td>
                  <td className="nowrap small">{st.to_date ? shortDate(st.to_date) : ''}</td>
                  <td><span className="num">{st.line_count}</span></td>
                  <td><Money value={st.closing_balance || 0} blankZero /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

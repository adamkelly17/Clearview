-- =====================================================================
-- 0021_overview.sql
--
-- Two summaries for the overview screen, and the foundations of the
-- profit and loss report when that comes.
--
-- profit_summary() groups by the report_group already carried on
-- account_type, so a business that adds its own nominal codes gets them
-- counted in the right place without anything here changing.
-- =====================================================================

create or replace function profit_summary(
  p_organisation_id uuid,
  p_from            date,
  p_to              date
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sales     numeric(14,2) := 0;
  v_other     numeric(14,2) := 0;
  v_cos       numeric(14,2) := 0;
  v_overheads numeric(14,2) := 0;
  v_tax       numeric(14,2) := 0;
  v_gross     numeric(14,2);
  v_net       numeric(14,2);
begin
  if not is_org_member(p_organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  -- Income is a credit balance and expenditure a debit, so both are
  -- turned into positive figures here. Nobody wants to read a profit
  -- and loss account in signed debits.
  select
    coalesce(sum(case when t.code = 'sales'
                      then jl.credit - jl.debit else 0 end), 0),
    coalesce(sum(case when t.class = 'income' and t.code <> 'sales'
                      then jl.credit - jl.debit else 0 end), 0),
    coalesce(sum(case when t.report_group = 'Cost of sales'
                      then jl.debit - jl.credit else 0 end), 0),
    coalesce(sum(case when t.report_group = 'Overheads'
                      then jl.debit - jl.credit else 0 end), 0),
    coalesce(sum(case when t.report_group = 'Taxation'
                      then jl.debit - jl.credit else 0 end), 0)
    into v_sales, v_other, v_cos, v_overheads, v_tax
    from journal_line jl
    join journal j on j.id = jl.journal_id
    join account a on a.id = jl.account_id
    join account_type t on t.code = a.account_type_code
   where jl.organisation_id = p_organisation_id
     and t.report = 'profit_and_loss'
     and j.date between p_from and p_to;

  v_gross := v_sales - v_cos;
  v_net := v_gross + v_other - v_overheads - v_tax;

  return jsonb_build_object(
    'sales', v_sales,
    'other_income', v_other,
    'cost_of_sales', v_cos,
    'gross_profit', v_gross,
    'overheads', v_overheads,
    'taxation', v_tax,
    'net_profit', v_net,
    -- Margins only mean anything against sales. Nil sales gives null
    -- rather than a division by zero or a misleading nought.
    'gross_margin', case when v_sales <> 0
                         then round(v_gross / v_sales * 100, 1) else null end,
    'net_margin',   case when v_sales <> 0
                         then round(v_net / v_sales * 100, 1) else null end,
    'from', p_from,
    'to', p_to
  );
end;
$$;

grant execute on function profit_summary(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- Bank position across every account
--
-- The count on its own does not tell you much. The date of the oldest
-- unreconciled entry does: something sitting there since April means the
-- bank has not been looked at since April, and the balance on screen
-- cannot be trusted.
-- ---------------------------------------------------------------------

create or replace function bank_summary(
  p_organisation_id uuid,
  p_as_at           date default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_as             date := coalesce(p_as_at, current_date);
  v_balance        numeric(14,2) := 0;
  v_unrec_count    int := 0;
  v_unrec_total    numeric(14,2) := 0;
  v_earliest       date;
  v_lines_to_do    int := 0;
  v_earliest_line  date;
  v_accounts       int := 0;
begin
  if not is_org_member(p_organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  select count(*) into v_accounts
    from bank_account where organisation_id = p_organisation_id and active;

  select
    coalesce(sum(jl.debit - jl.credit), 0),
    coalesce(count(*) filter (where jl.reconciled_at is null), 0),
    coalesce(sum(case when jl.reconciled_at is null
                      then jl.debit - jl.credit else 0 end), 0),
    min(j.date) filter (where jl.reconciled_at is null)
    into v_balance, v_unrec_count, v_unrec_total, v_earliest
    from journal_line jl
    join journal j on j.id = jl.journal_id
    join account a on a.id = jl.account_id
   where jl.organisation_id = p_organisation_id
     and a.is_bank
     and j.date <= v_as;

  -- Imported statement lines nobody has dealt with yet. A different
  -- thing from an unreconciled transaction, and both are worth knowing.
  select count(*), min(date)
    into v_lines_to_do, v_earliest_line
    from statement_line
   where organisation_id = p_organisation_id
     and status = 'unmatched'
     and date <= v_as;

  return jsonb_build_object(
    'balance', v_balance,
    'accounts', v_accounts,
    'unreconciled_count', v_unrec_count,
    'unreconciled_total', v_unrec_total,
    'earliest_unreconciled', v_earliest,
    'days_since_earliest', case when v_earliest is null
                                then null else v_as - v_earliest end,
    'statement_lines_to_do', v_lines_to_do,
    'earliest_statement_line', v_earliest_line
  );
end;
$$;

grant execute on function bank_summary(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- Working capital
--
-- What is in the bank, what is owed in, what is owed out, and where that
-- leaves you if everything settled. For a small business that last
-- figure is more use than either ledger total on its own — it is the
-- answer to "can I afford this".
-- ---------------------------------------------------------------------

create or replace function working_capital(p_organisation_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_bank      numeric(14,2) := 0;
  v_owed_in   numeric(14,2) := 0;
  v_owed_out  numeric(14,2) := 0;
  v_in_late   numeric(14,2) := 0;
  v_out_late  numeric(14,2) := 0;
  v_worst     record;
  v_next_due  record;
begin
  if not is_org_member(p_organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  select coalesce(sum(jl.debit - jl.credit), 0) into v_bank
    from journal_line jl
    join account a on a.id = jl.account_id
   where jl.organisation_id = p_organisation_id and a.is_bank;

  select
    coalesce(sum(case when o.ledger = 'sales'
      then case when o.direction = 'debit' then o.outstanding_amount
                else -o.outstanding_amount end else 0 end), 0),
    coalesce(sum(case when o.ledger = 'purchase'
      then case when o.direction = 'credit' then o.outstanding_amount
                else -o.outstanding_amount end else 0 end), 0),
    coalesce(sum(case when o.ledger = 'sales' and o.direction = 'debit'
                       and o.days_overdue > 0
                      then o.outstanding_amount else 0 end), 0),
    coalesce(sum(case when o.ledger = 'purchase' and o.direction = 'credit'
                       and o.days_overdue > 0
                      then o.outstanding_amount else 0 end), 0)
    into v_owed_in, v_owed_out, v_in_late, v_out_late
    from ledger_item_outstanding o
   where o.organisation_id = p_organisation_id
     and o.outstanding_amount > 0;

  -- Who to chase first: the oldest overdue sales item, not the biggest.
  -- Age is what turns a debt into a bad one.
  select c.id, c.name, o.outstanding_amount, o.days_overdue, o.reference
    into v_worst
    from ledger_item_outstanding o
    join contact c on c.id = o.contact_id
   where o.organisation_id = p_organisation_id
     and o.ledger = 'sales' and o.direction = 'debit'
     and o.outstanding_amount > 0 and o.days_overdue > 0
   order by o.days_overdue desc, o.outstanding_amount desc
   limit 1;

  select c.name, o.outstanding_amount, o.due_date
    into v_next_due
    from ledger_item_outstanding o
    join contact c on c.id = o.contact_id
   where o.organisation_id = p_organisation_id
     and o.ledger = 'purchase' and o.direction = 'credit'
     and o.outstanding_amount > 0
     and coalesce(o.due_date, o.date) >= current_date
   order by coalesce(o.due_date, o.date)
   limit 1;

  return jsonb_build_object(
    'bank', v_bank,
    'owed_in', v_owed_in,
    'owed_out', v_owed_out,
    'overdue_in', v_in_late,
    'overdue_out', v_out_late,
    'if_all_settled', v_bank + v_owed_in - v_owed_out,
    'chase_first', case when v_worst.id is null then null else jsonb_build_object(
      'contact_id', v_worst.id, 'name', v_worst.name,
      'amount', v_worst.outstanding_amount,
      'days_overdue', v_worst.days_overdue,
      'reference', v_worst.reference) end,
    'next_due', case when v_next_due.name is null then null else jsonb_build_object(
      'name', v_next_due.name, 'amount', v_next_due.outstanding_amount,
      'due_date', v_next_due.due_date) end
  );
end;
$$;

grant execute on function working_capital(uuid) to authenticated;

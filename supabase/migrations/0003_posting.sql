-- =====================================================================
-- 0003_posting.sql
-- The posting gateway.
--
-- post_journal() is the ONLY route into the ledger. Sales, purchases,
-- bank, VAT, depreciation and year end all call this function. No
-- module is ever permitted to INSERT into journal_line directly.
--
-- If you add a module later and it needs to write to the ledger, it
-- calls post_journal(). No exceptions. This is the rule that keeps the
-- audit trail honest.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Period resolution
-- ---------------------------------------------------------------------

create or replace function resolve_period(
  p_organisation_id uuid,
  p_date            date
) returns period
language plpgsql
stable
as $$
declare
  v_period period;
begin
  select * into v_period
    from period
   where organisation_id = p_organisation_id
     and p_date between start_date and end_date;

  if not found then
    raise exception
      'There is no accounting period covering %. Add the financial year first.',
      to_char(p_date, 'DD/MM/YYYY')
      using errcode = 'no_data_found';
  end if;

  if v_period.status <> 'open' then
    raise exception
      'The period % is %. Reopen it or use a different date.',
      v_period.name, v_period.status
      using errcode = 'insufficient_privilege';
  end if;

  return v_period;
end;
$$;

-- ---------------------------------------------------------------------
-- post_journal
--
-- p_lines is a JSON array. Each element:
--   {
--     "account_id":   uuid      (required)
--     "debit":        numeric   (transaction currency)
--     "credit":       numeric   (transaction currency)
--     "description":  text
--     "contact_id":   uuid
--     "department_id":uuid
--     "project_id":   uuid
--     "vat_code_id":  uuid
--     "net_amount":   numeric
--     "vat_amount":   numeric
--   }
--
-- Amounts are supplied in the journal's currency. Base currency
-- amounts are derived using p_exchange_rate. Any rounding difference
-- created by the conversion is posted to the exchange difference
-- account so the journal always balances in base currency.
-- ---------------------------------------------------------------------

create or replace function post_journal(
  p_organisation_id uuid,
  p_date            date,
  p_description     text,
  p_lines           jsonb,
  p_reference       text default null,
  p_source_type     text default 'manual',
  p_source_id       uuid default null,
  p_currency_code   text default null,
  p_exchange_rate   numeric default 1
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period        period;
  v_journal_id    uuid;
  v_journal_no    bigint;
  v_currency      text;
  v_line          jsonb;
  v_line_no       int := 0;
  v_txn_debit     numeric(14,2);
  v_txn_credit    numeric(14,2);
  v_debit         numeric(14,2);
  v_credit        numeric(14,2);
  v_sum_debit     numeric(14,2) := 0;
  v_sum_credit    numeric(14,2) := 0;
  v_txn_sum_debit numeric(14,2) := 0;
  v_txn_sum_credit numeric(14,2) := 0;
  v_rounding      numeric(14,2);
  v_fx_account    uuid;
  v_is_control    boolean;
  v_account_org   uuid;
begin
  if not is_org_member(p_organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A transaction needs at least two lines'
      using errcode = 'check_violation';
  end if;

  v_period := resolve_period(p_organisation_id, p_date);

  select coalesce(p_currency_code, base_currency_code)
    into v_currency
    from organisation
   where id = p_organisation_id;

  select coalesce(max(journal_no), 0) + 1
    into v_journal_no
    from journal
   where organisation_id = p_organisation_id;

  insert into journal (
    organisation_id, journal_no, date, period_id, reference, description,
    source_type, source_id, currency_code, exchange_rate, posted_by
  ) values (
    p_organisation_id, v_journal_no, p_date, v_period.id, p_reference,
    p_description, p_source_type, p_source_id, v_currency,
    coalesce(p_exchange_rate, 1), auth.uid()
  )
  returning id into v_journal_id;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_line_no := v_line_no + 1;

    v_txn_debit  := round(coalesce((v_line ->> 'debit')::numeric, 0), 2);
    v_txn_credit := round(coalesce((v_line ->> 'credit')::numeric, 0), 2);

    if v_txn_debit = 0 and v_txn_credit = 0 then
      continue;  -- silently skip blank rows from the entry grid
    end if;

    if v_txn_debit > 0 and v_txn_credit > 0 then
      raise exception 'Line % has both a debit and a credit', v_line_no
        using errcode = 'check_violation';
    end if;

    -- Guard: the account must belong to this organisation, and must
    -- not be a control account unless a module is doing the posting.
    select organisation_id, is_control
      into v_account_org, v_is_control
      from account
     where id = (v_line ->> 'account_id')::uuid;

    if v_account_org is null then
      raise exception 'Line %: that account does not exist', v_line_no
        using errcode = 'foreign_key_violation';
    end if;

    if v_account_org <> p_organisation_id then
      raise exception 'Line %: that account belongs to another organisation', v_line_no
        using errcode = 'insufficient_privilege';
    end if;

    if v_is_control and p_source_type = 'manual' then
      raise exception
        'Line %: this account is maintained automatically and cannot be posted to by hand',
        v_line_no
        using errcode = 'insufficient_privilege';
    end if;

    v_debit  := round(v_txn_debit  * coalesce(p_exchange_rate, 1), 2);
    v_credit := round(v_txn_credit * coalesce(p_exchange_rate, 1), 2);

    insert into journal_line (
      organisation_id, journal_id, line_no, account_id, description,
      debit, credit, txn_debit, txn_credit,
      contact_id, department_id, project_id,
      vat_code_id, net_amount, vat_amount
    ) values (
      p_organisation_id, v_journal_id, v_line_no,
      (v_line ->> 'account_id')::uuid,
      v_line ->> 'description',
      v_debit, v_credit, v_txn_debit, v_txn_credit,
      nullif(v_line ->> 'contact_id', '')::uuid,
      nullif(v_line ->> 'department_id', '')::uuid,
      nullif(v_line ->> 'project_id', '')::uuid,
      nullif(v_line ->> 'vat_code_id', '')::uuid,
      nullif(v_line ->> 'net_amount', '')::numeric,
      nullif(v_line ->> 'vat_amount', '')::numeric
    );

    v_sum_debit      := v_sum_debit + v_debit;
    v_sum_credit     := v_sum_credit + v_credit;
    v_txn_sum_debit  := v_txn_sum_debit + v_txn_debit;
    v_txn_sum_credit := v_txn_sum_credit + v_txn_credit;
  end loop;

  -- The transaction itself must balance in its own currency. If it
  -- does not, the user has made an error.
  if v_txn_sum_debit <> v_txn_sum_credit then
    raise exception
      'This transaction does not balance. Debits %, credits %, difference %.',
      to_char(v_txn_sum_debit, 'FM999999999990.00'),
      to_char(v_txn_sum_credit, 'FM999999999990.00'),
      to_char(v_txn_sum_debit - v_txn_sum_credit, 'FM999999999990.00')
      using errcode = 'check_violation';
  end if;

  -- Any imbalance left in base currency is pure conversion rounding.
  -- It is the system's problem, not the user's, so it is absorbed
  -- automatically rather than reported as an error.
  v_rounding := v_sum_debit - v_sum_credit;

  if v_rounding <> 0 then
    select id into v_fx_account
      from account
     where organisation_id = p_organisation_id
       and control_type = 'exchange_difference';

    if v_fx_account is null then
      raise exception 'No exchange difference account is set up'
        using errcode = 'no_data_found';
    end if;

    v_line_no := v_line_no + 1;

    insert into journal_line (
      organisation_id, journal_id, line_no, account_id, description,
      debit, credit, txn_debit, txn_credit
    ) values (
      p_organisation_id, v_journal_id, v_line_no, v_fx_account,
      'Currency rounding',
      case when v_rounding < 0 then -v_rounding else 0 end,
      case when v_rounding > 0 then  v_rounding else 0 end,
      0, 0
    );
  end if;

  return v_journal_id;
end;
$$;

-- ---------------------------------------------------------------------
-- reverse_journal
--
-- The only way to undo anything. Creates a mirror-image journal and
-- links the two together in both directions.
-- ---------------------------------------------------------------------

create or replace function reverse_journal(
  p_journal_id uuid,
  p_date       date default null,
  p_reason     text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_original journal;
  v_lines    jsonb;
  v_new_id   uuid;
  v_date     date;
begin
  select * into v_original from journal where id = p_journal_id;

  if not found then
    raise exception 'That transaction does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_original.organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_original.reversed_by_journal_id is not null then
    raise exception 'That transaction has already been reversed'
      using errcode = 'check_violation';
  end if;

  v_date := coalesce(p_date, v_original.date);

  select jsonb_agg(
           jsonb_build_object(
             'account_id',    account_id,
             'debit',         txn_credit,
             'credit',        txn_debit,
             'description',   coalesce(description, ''),
             'contact_id',    contact_id,
             'department_id', department_id,
             'project_id',    project_id,
             'vat_code_id',   vat_code_id,
             'net_amount',    case when net_amount is null then null else -net_amount end,
             'vat_amount',    case when vat_amount is null then null else -vat_amount end
           ) order by line_no
         )
    into v_lines
    from journal_line
   where journal_id = p_journal_id;

  v_new_id := post_journal(
    p_organisation_id => v_original.organisation_id,
    p_date            => v_date,
    p_description     => coalesce(p_reason, 'Reversal of ' || v_original.description),
    p_lines           => v_lines,
    p_reference       => v_original.reference,
    p_source_type     => 'reversal',
    p_source_id       => p_journal_id,
    p_currency_code   => v_original.currency_code,
    p_exchange_rate   => v_original.exchange_rate
  );

  perform set_config('app.ledger_unlocked', 'on', true);
  update journal set reversed_by_journal_id = v_new_id where id = p_journal_id;
  update journal set reverses_journal_id    = p_journal_id where id = v_new_id;
  perform set_config('app.ledger_unlocked', 'off', true);

  return v_new_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------

create or replace function trial_balance(
  p_organisation_id uuid,
  p_to_date         date,
  p_from_date       date default null
) returns table (
  account_id    uuid,
  code          text,
  name          text,
  friendly_name text,
  type_code     text,
  type_name     text,
  class         account_class,
  report        text,
  report_group  text,
  debit         numeric,
  credit        numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with movement as (
    select jl.account_id,
           sum(jl.debit)  as total_debit,
           sum(jl.credit) as total_credit
      from journal_line jl
      join journal j on j.id = jl.journal_id
     where jl.organisation_id = p_organisation_id
       and j.date <= p_to_date
       and (p_from_date is null or j.date >= p_from_date)
     group by jl.account_id
  )
  select a.id,
         a.code,
         a.name,
         coalesce(a.friendly_name, a.name),
         at.code,
         at.name,
         at.class,
         at.report,
         at.report_group,
         case when coalesce(m.total_debit, 0) - coalesce(m.total_credit, 0) > 0
              then coalesce(m.total_debit, 0) - coalesce(m.total_credit, 0)
              else 0 end,
         case when coalesce(m.total_credit, 0) - coalesce(m.total_debit, 0) > 0
              then coalesce(m.total_credit, 0) - coalesce(m.total_debit, 0)
              else 0 end
    from account a
    join account_type at on at.code = a.account_type_code
    left join movement m on m.account_id = a.id
   where a.organisation_id = p_organisation_id
     and (m.account_id is not null)
   order by a.code;
$$;

create or replace function account_activity(
  p_organisation_id uuid,
  p_account_id      uuid,
  p_from_date       date,
  p_to_date         date
) returns table (
  journal_id   uuid,
  journal_no   bigint,
  date         date,
  reference    text,
  description  text,
  line_description text,
  source_type  text,
  debit        numeric,
  credit       numeric,
  running_balance numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with opening as (
    select coalesce(sum(jl.debit - jl.credit), 0) as bal
      from journal_line jl
      join journal j on j.id = jl.journal_id
     where jl.organisation_id = p_organisation_id
       and jl.account_id = p_account_id
       and j.date < p_from_date
  ),
  lines as (
    select j.id, j.journal_no, j.date, j.reference, j.description,
           jl.description as line_description, j.source_type,
           jl.debit, jl.credit
      from journal_line jl
      join journal j on j.id = jl.journal_id
     where jl.organisation_id = p_organisation_id
       and jl.account_id = p_account_id
       and j.date between p_from_date and p_to_date
  )
  select l.id, l.journal_no, l.date, l.reference, l.description,
         l.line_description, l.source_type, l.debit, l.credit,
         (select bal from opening)
           + sum(l.debit - l.credit) over (order by l.date, l.journal_no
                                           rows between unbounded preceding and current row)
    from lines l
   order by l.date, l.journal_no;
$$;

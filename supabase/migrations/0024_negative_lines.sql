-- =====================================================================
-- 0024_negative_lines.sql
--
-- A real invoice with a discount line failed to post:
--
--   new row for relation "journal_line" violates check constraint
--   "journal_line_non_negative"
--
-- The constraint is right. The mistake was mine: post_document() took a
-- line amount and put it on a fixed side, so a −£2.92 promotion became a
-- debit of −2.92 rather than a credit of 2.92.
--
-- Negative lines are entirely ordinary — discounts, promotions, rebates,
-- carriage refunds all print as negatives on perfectly normal invoices.
-- What is not ordinary is a negative debit. Double entry has no use for
-- negative numbers at all: a negative amount on one side is simply a
-- positive amount on the other.
--
-- So the fix is not to relax the constraint. It is to work out the side
-- from the sign, which is what an accountant does without thinking.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Which side does this amount belong on?
--
-- p_credit_side says where a positive amount goes. A negative amount goes
-- to the other side, as its absolute value.
-- ---------------------------------------------------------------------

create or replace function posting_sides(
  p_amount      numeric,
  p_credit_side boolean
) returns jsonb
language sql
immutable
as $$
  select case
    when coalesce(p_amount, 0) = 0
      then jsonb_build_object('debit', 0, 'credit', 0)
    when (p_credit_side and p_amount > 0) or (not p_credit_side and p_amount < 0)
      then jsonb_build_object('debit', 0, 'credit', abs(p_amount))
    else
      jsonb_build_object('debit', abs(p_amount), 'credit', 0)
  end;
$$;

grant execute on function posting_sides(numeric, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- post_journal, made defensive about signs
--
-- post_document is fixed below, but any module written later could make
-- the same mistake. Normalising here means none of them can reach the
-- constraint: a negative debit is silently understood as a credit, which
-- is not a guess — it is the same entry written the other way round.
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
  v_swap          numeric(14,2);
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

    -- A negative amount on one side is a positive amount on the other.
    -- Rewriting it that way is not an assumption; it is the same entry.
    if v_txn_debit < 0 then
      v_swap := v_txn_debit;
      v_txn_debit := 0;
      v_txn_credit := v_txn_credit - v_swap;
    end if;

    if v_txn_credit < 0 then
      v_swap := v_txn_credit;
      v_txn_credit := 0;
      v_txn_debit := v_txn_debit - v_swap;
    end if;

    -- If both sides were given, they net off against each other.
    if v_txn_debit > 0 and v_txn_credit > 0 then
      if v_txn_debit >= v_txn_credit then
        v_txn_debit := v_txn_debit - v_txn_credit;
        v_txn_credit := 0;
      else
        v_txn_credit := v_txn_credit - v_txn_debit;
        v_txn_debit := 0;
      end if;
    end if;

    if v_txn_debit = 0 and v_txn_credit = 0 then
      continue;  -- silently skip blank rows from the entry grid
    end if;

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

  if v_txn_sum_debit <> v_txn_sum_credit then
    raise exception
      'This transaction does not balance. Debits %, credits %, difference %.',
      to_char(v_txn_sum_debit, 'FM999999999990.00'),
      to_char(v_txn_sum_credit, 'FM999999999990.00'),
      to_char(v_txn_sum_debit - v_txn_sum_credit, 'FM999999999990.00')
      using errcode = 'check_violation';
  end if;

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

grant execute on function post_journal(uuid, date, text, jsonb, text, text, uuid, text, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- post_document, working the side out from the sign
-- ---------------------------------------------------------------------

create or replace function post_document(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org         uuid := (p_config ->> 'organisation_id')::uuid;
  v_doc_type    text := p_config ->> 'doc_type';
  v_contact_id  uuid := (p_config ->> 'contact_id')::uuid;
  v_date        date := (p_config ->> 'date')::date;
  v_due_date    date;
  v_number      text;
  v_currency    text;
  v_rate        numeric := coalesce((p_config ->> 'exchange_rate')::numeric, 1);
  v_doc_id      uuid;
  v_is_sales    boolean;
  v_is_credit   boolean;
  v_line        jsonb;
  v_line_no     int := 0;
  v_net         numeric(14,2);
  v_vat         numeric(14,2);
  v_notional    numeric(14,2);
  v_net_total   numeric(14,2) := 0;
  v_vat_total   numeric(14,2) := 0;
  v_notional_total numeric(14,2) := 0;
  v_gross       numeric(14,2);
  v_lines       jsonb := '[]'::jsonb;
  v_control     uuid;
  v_vat_output  uuid;
  v_vat_input   uuid;
  v_journal_id  uuid;
  v_item_id     uuid;
  v_terms       int;
  v_source      text;
  v_account_id  uuid;
  v_vat_code_id uuid;
  v_desc        text;
  v_vat_enabled boolean;
begin
  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_doc_type not in ('SI', 'SC', 'PI', 'PC') then
    raise exception 'Only invoices and credit notes can be posted'
      using errcode = 'check_violation';
  end if;

  -- The guard. Everything below treats a null VAT code as no VAT.
  select coalesce(vat_enabled, false) into v_vat_enabled
    from organisation_feature where organisation_id = v_org;

  v_is_sales  := v_doc_type in ('SI', 'SC');
  v_is_credit := v_doc_type in ('SC', 'PC');

  select coalesce(nullif(p_config ->> 'currency_code', ''), base_currency_code)
    into v_currency from organisation where id = v_org;

  select payment_terms_days into v_terms from contact where id = v_contact_id;
  if v_terms is null then
    raise exception 'That customer or supplier does not exist'
      using errcode = 'no_data_found';
  end if;

  v_due_date := coalesce(
    nullif(p_config ->> 'due_date', '')::date,
    v_date + coalesce(v_terms, 30)
  );

  v_number := nullif(p_config ->> 'number', '');
  if v_number is null then
    v_number := case v_doc_type
      when 'SI' then next_document_number(v_org, 'sales_invoice')
      when 'SC' then next_document_number(v_org, 'sales_credit')
      else 'AUTO-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS')
    end;
  end if;

  select id into v_control from account
   where organisation_id = v_org
     and control_type = case when v_is_sales then 'debtors' else 'creditors' end;

  select id into v_vat_output from account
   where organisation_id = v_org and control_type = 'vat_output';
  select id into v_vat_input from account
   where organisation_id = v_org and control_type = 'vat_input';

  insert into document (
    organisation_id, doc_type, contact_id, number, date, due_date,
    their_reference, status, currency_code, exchange_rate, notes, created_by
  ) values (
    v_org, v_doc_type, v_contact_id, v_number, v_date, v_due_date,
    nullif(p_config ->> 'their_reference', ''), 'draft', v_currency, v_rate,
    nullif(p_config ->> 'notes', ''), auth.uid()
  )
  returning id into v_doc_id;

  for v_line in select * from jsonb_array_elements(p_config -> 'lines')
  loop
    v_account_id  := nullif(v_line ->> 'account_id', '')::uuid;
    v_vat_code_id := nullif(v_line ->> 'vat_code_id', '')::uuid;
    v_desc        := coalesce(nullif(v_line ->> 'description', ''), 'Item');

    -- Not registered means no VAT, whatever the caller asked for.
    if not v_vat_enabled then
      v_vat_code_id := null;
    end if;

    if v_account_id is null then
      raise exception 'Every line needs a category' using errcode = 'check_violation';
    end if;

    select c.net_amount, c.vat_amount, c.notional_vat
      into v_net, v_vat, v_notional
      from calculate_document_line(
        coalesce((v_line ->> 'quantity')::numeric, 1),
        coalesce((v_line ->> 'unit_price')::numeric, 0),
        coalesce((v_line ->> 'discount_percent')::numeric, 0),
        v_vat_code_id,
        v_is_sales
      ) c;

    if v_net = 0 and v_vat = 0 then
      continue;
    end if;

    v_line_no := v_line_no + 1;

    insert into document_line (
      organisation_id, document_id, line_no, description,
      quantity, unit_price, discount_percent,
      account_id, vat_code_id, department_id,
      net_amount, vat_amount, notional_vat
    ) values (
      v_org, v_doc_id, v_line_no, v_desc,
      coalesce((v_line ->> 'quantity')::numeric, 1),
      coalesce((v_line ->> 'unit_price')::numeric, 0),
      coalesce((v_line ->> 'discount_percent')::numeric, 0),
      v_account_id, v_vat_code_id,
      nullif(v_line ->> 'department_id', '')::uuid,
      v_net, v_vat, v_notional
    );

    -- A negative line — a discount, promotion or rebate printed on the
    -- invoice — is a credit to that account, not a negative debit. The
    -- ledger has no use for negative numbers, and the database will not
    -- store one.
    v_lines := v_lines || (
      jsonb_build_object(
        'account_id',  v_account_id,
        'description', v_desc,
        'contact_id',  v_contact_id,
        'vat_code_id', v_vat_code_id,
        'net_amount',  case when v_is_credit then -v_net else v_net end,
        'vat_amount',  case when v_is_credit then -v_vat else v_vat end,
        'department_id', nullif(v_line ->> 'department_id', '')
      )
      || posting_sides(v_net, v_is_sales <> v_is_credit)
    );

    v_net_total      := v_net_total + v_net;
    v_vat_total      := v_vat_total + v_vat;
    v_notional_total := v_notional_total + v_notional;
  end loop;

  if v_line_no = 0 then
    raise exception 'This document has no lines' using errcode = 'check_violation';
  end if;

  v_gross := v_net_total + v_vat_total;

  if v_vat_total <> 0 then
    v_lines := v_lines || (
      jsonb_build_object(
        'account_id',  case when v_is_sales then v_vat_output else v_vat_input end,
        'description', 'VAT',
        'contact_id',  v_contact_id
      )
      || posting_sides(v_vat_total, v_is_sales <> v_is_credit)
    );
  end if;

  if v_notional_total <> 0 then
    v_lines := v_lines
      || jsonb_build_object(
           'account_id',  v_vat_input,
           'description', 'Reverse charge VAT reclaimed',
           'contact_id',  v_contact_id,
           'debit',  case when v_is_credit then 0 else v_notional_total end,
           'credit', case when v_is_credit then v_notional_total else 0 end)
      || jsonb_build_object(
           'account_id',  v_vat_output,
           'description', 'Reverse charge VAT due',
           'contact_id',  v_contact_id,
           'debit',  case when v_is_credit then v_notional_total else 0 end,
           'credit', case when v_is_credit then 0 else v_notional_total end);
  end if;

  v_lines := v_lines || (
    jsonb_build_object(
      'account_id',  v_control,
      'description', v_number,
      'contact_id',  v_contact_id
    )
    || posting_sides(v_gross, not (v_is_sales <> v_is_credit))
  );

  v_source := case v_doc_type
    when 'SI' then 'sales_invoice'
    when 'SC' then 'sales_credit'
    when 'PI' then 'purchase_invoice'
    else 'purchase_credit'
  end;

  v_journal_id := post_journal(
    p_organisation_id => v_org,
    p_date            => v_date,
    p_description     => (select name from contact where id = v_contact_id)
                           || ' — ' || v_number,
    p_lines           => v_lines,
    p_reference       => v_number,
    p_source_type     => v_source,
    p_source_id       => v_doc_id,
    p_currency_code   => v_currency,
    p_exchange_rate   => v_rate
  );

  insert into ledger_item (
    organisation_id, contact_id, ledger, item_type, direction,
    gross_amount, date, due_date, reference, description,
    currency_code, exchange_rate, journal_id, document_id
  ) values (
    v_org, v_contact_id,
    case when v_is_sales then 'sales' else 'purchase' end,
    case when v_is_credit then 'credit_note' else 'invoice' end,
    case when v_is_sales <> v_is_credit then 'debit' else 'credit' end,
    v_gross, v_date, v_due_date, v_number,
    nullif(p_config ->> 'notes', ''),
    v_currency, v_rate, v_journal_id, v_doc_id
  )
  returning id into v_item_id;

  update document
     set status = 'posted',
         journal_id = v_journal_id,
         ledger_item_id = v_item_id,
         net_total = v_net_total,
         vat_total = v_vat_total,
         gross_total = v_gross,
         posted_at = now()
   where id = v_doc_id;

  return v_doc_id;
end;
$$;
grant execute on function post_document(jsonb) to authenticated;

-- =====================================================================
-- 0009_trading_posting.sql
-- Posting for the sales and purchase ledgers.
--
-- Every function here builds a JSON line array and hands it to
-- post_journal(). None of them touch journal_line. That is the rule
-- from phase 1 and it does not bend for a module.
--
-- Line amounts are recalculated server side from quantity, price,
-- discount and VAT code. The browser's arithmetic is never trusted
-- with money.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Line arithmetic
--
-- Reverse charge is the subtle one. On a sale under the domestic
-- reverse charge you charge no VAT at all: the customer accounts for
-- it. On a purchase you are the one who accounts for it, so notional
-- VAT is posted to both the input and output accounts. The net effect
-- on the VAT liability is nil, but boxes 1 and 4 both move, which is
-- exactly what HMRC expects to see.
-- ---------------------------------------------------------------------

create or replace function calculate_document_line(
  p_quantity         numeric,
  p_unit_price       numeric,
  p_discount_percent numeric,
  p_vat_code_id      uuid,
  p_is_sales         boolean
) returns table (
  net_amount   numeric,
  vat_amount   numeric,
  notional_vat numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_net      numeric(14,2);
  v_rate     numeric(5,2) := 0;
  v_reverse  boolean := false;
  v_vat      numeric(14,2) := 0;
  v_notional numeric(14,2) := 0;
begin
  v_net := round(
    coalesce(p_quantity, 0) * coalesce(p_unit_price, 0)
      * (1 - coalesce(p_discount_percent, 0) / 100.0),
    2);

  if p_vat_code_id is not null then
    select rate, is_reverse_charge into v_rate, v_reverse
      from vat_code where id = p_vat_code_id;
  end if;

  if v_reverse then
    -- No VAT on the document either way. On a purchase we account for
    -- it ourselves, so record the notional amount.
    v_vat := 0;
    v_notional := case when p_is_sales then 0 else round(v_net * coalesce(v_rate, 0) / 100.0, 2) end;
  else
    v_vat := round(v_net * coalesce(v_rate, 0) / 100.0, 2);
    v_notional := 0;
  end if;

  return query select v_net, v_vat, v_notional;
end;
$$;

-- ---------------------------------------------------------------------
-- post_document
--
-- Handles SI, SC, PI and PC. Quotes and purchase orders are never
-- posted, they are converted.
--
-- p_config:
--   organisation_id, doc_type, contact_id, date, due_date,
--   their_reference, number (optional), notes, currency_code,
--   exchange_rate,
--   lines: [{ description, quantity, unit_price, discount_percent,
--             account_id, vat_code_id, department_id }]
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
begin
  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_doc_type not in ('SI', 'SC', 'PI', 'PC') then
    raise exception 'Only invoices and credit notes can be posted'
      using errcode = 'check_violation';
  end if;

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

  -- Control and VAT accounts
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

  -- ---- Lines --------------------------------------------------------
  for v_line in select * from jsonb_array_elements(p_config -> 'lines')
  loop
    v_account_id  := nullif(v_line ->> 'account_id', '')::uuid;
    v_vat_code_id := nullif(v_line ->> 'vat_code_id', '')::uuid;
    v_desc        := coalesce(nullif(v_line ->> 'description', ''), 'Item');

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

    -- Income and expense side of the journal
    v_lines := v_lines || jsonb_build_object(
      'account_id',  v_account_id,
      'description', v_desc,
      'contact_id',  v_contact_id,
      'vat_code_id', v_vat_code_id,
      'net_amount',  case when v_is_credit then -v_net else v_net end,
      'vat_amount',  case when v_is_credit then -v_vat else v_vat end,
      'department_id', nullif(v_line ->> 'department_id', ''),
      -- A sale credits income; a purchase debits expense. A credit note
      -- does the opposite.
      'debit',  case when v_is_sales <> v_is_credit then 0     else v_net end,
      'credit', case when v_is_sales <> v_is_credit then v_net else 0     end
    );

    v_net_total      := v_net_total + v_net;
    v_vat_total      := v_vat_total + v_vat;
    v_notional_total := v_notional_total + v_notional;
  end loop;

  if v_line_no = 0 then
    raise exception 'This document has no lines' using errcode = 'check_violation';
  end if;

  v_gross := v_net_total + v_vat_total;

  -- ---- VAT ----------------------------------------------------------
  if v_vat_total <> 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id',  case when v_is_sales then v_vat_output else v_vat_input end,
      'description', 'VAT',
      'contact_id',  v_contact_id,
      'debit',  case when v_is_sales <> v_is_credit then 0 else v_vat_total end,
      'credit', case when v_is_sales <> v_is_credit then v_vat_total else 0 end
    );
  end if;

  -- Reverse charge on a purchase: account for the VAT on both sides.
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

  -- ---- Control account ---------------------------------------------
  -- A sales invoice debits debtors; a purchase invoice credits
  -- creditors. Credit notes reverse it.
  v_lines := v_lines || jsonb_build_object(
    'account_id',  v_control,
    'description', v_number,
    'contact_id',  v_contact_id,
    'debit',  case when v_is_sales <> v_is_credit then v_gross else 0 end,
    'credit', case when v_is_sales <> v_is_credit then 0 else v_gross end
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
    p_reference        => v_number,
    p_source_type     => v_source,
    p_source_id       => v_doc_id,
    p_currency_code   => v_currency,
    p_exchange_rate   => v_rate
  );

  -- ---- Settlement item ---------------------------------------------
  insert into ledger_item (
    organisation_id, contact_id, ledger, item_type, direction,
    gross_amount, date, due_date, reference, description,
    currency_code, exchange_rate, journal_id, document_id
  ) values (
    v_org, v_contact_id,
    case when v_is_sales then 'sales' else 'purchase' end,
    case when v_is_credit then 'credit_note' else 'invoice' end,
    -- Sales invoice: debit (they owe you more).
    -- Purchase invoice: credit (you owe more).
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

-- ---------------------------------------------------------------------
-- post_payment
--
-- Money received from a customer or paid to a supplier. Optionally
-- allocates against outstanding items in the same call.
--
-- p_config:
--   organisation_id, ledger ('sales'|'purchase'), contact_id,
--   bank_account_id, date, amount, reference, description,
--   allocations: [{ item_id, amount }]  (optional)
--   auto_allocate: boolean  (oldest first)
-- ---------------------------------------------------------------------

create or replace function post_payment(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org        uuid := (p_config ->> 'organisation_id')::uuid;
  v_ledger     text := p_config ->> 'ledger';
  v_contact_id uuid := (p_config ->> 'contact_id')::uuid;
  v_bank_id    uuid := (p_config ->> 'bank_account_id')::uuid;
  v_date       date := (p_config ->> 'date')::date;
  v_amount     numeric(14,2) := round((p_config ->> 'amount')::numeric, 2);
  v_reference  text := nullif(p_config ->> 'reference', '');
  v_is_sales   boolean;
  v_control    uuid;
  v_currency   text;
  v_journal_id uuid;
  v_item_id    uuid;
  v_lines      jsonb;
  v_alloc      jsonb;
  v_remaining  numeric(14,2);
  v_target     record;
  v_take       numeric(14,2);
begin
  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_ledger not in ('sales', 'purchase') then
    raise exception 'Payments belong to either the sales or purchase ledger'
      using errcode = 'check_violation';
  end if;

  if v_amount is null or v_amount <= 0 then
    raise exception 'Enter an amount greater than nil' using errcode = 'check_violation';
  end if;

  v_is_sales := v_ledger = 'sales';

  select coalesce(nullif(p_config ->> 'currency_code', ''), base_currency_code)
    into v_currency from organisation where id = v_org;

  select id into v_control from account
   where organisation_id = v_org
     and control_type = case when v_is_sales then 'debtors' else 'creditors' end;

  -- Money in debits the bank and credits debtors.
  -- Money out credits the bank and debits creditors.
  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id',  v_bank_id,
      'description', coalesce(v_reference, case when v_is_sales then 'Receipt' else 'Payment' end),
      'contact_id',  v_contact_id,
      'debit',  case when v_is_sales then v_amount else 0 end,
      'credit', case when v_is_sales then 0 else v_amount end),
    jsonb_build_object(
      'account_id',  v_control,
      'description', coalesce(v_reference, case when v_is_sales then 'Receipt' else 'Payment' end),
      'contact_id',  v_contact_id,
      'debit',  case when v_is_sales then 0 else v_amount end,
      'credit', case when v_is_sales then v_amount else 0 end)
  );

  v_journal_id := post_journal(
    p_organisation_id => v_org,
    p_date            => v_date,
    p_description     => (select name from contact where id = v_contact_id)
                           || ' — ' || case when v_is_sales then 'receipt' else 'payment' end,
    p_lines           => v_lines,
    p_reference       => v_reference,
    p_source_type     => case when v_is_sales then 'sales_receipt' else 'purchase_payment' end,
    p_source_id       => null,
    p_currency_code   => v_currency
  );

  insert into ledger_item (
    organisation_id, contact_id, ledger, item_type, direction,
    gross_amount, date, due_date, reference, description,
    currency_code, journal_id
  ) values (
    v_org, v_contact_id, v_ledger, 'payment',
    -- A receipt credits the sales ledger; a payment debits the
    -- purchase ledger. Either way it settles the opposite side.
    case when v_is_sales then 'credit' else 'debit' end,
    v_amount, v_date, v_date, v_reference,
    nullif(p_config ->> 'description', ''),
    v_currency, v_journal_id
  )
  returning id into v_item_id;

  -- ---- Allocation ---------------------------------------------------
  if p_config ? 'allocations' then
    for v_alloc in select * from jsonb_array_elements(p_config -> 'allocations')
    loop
      perform allocate_items(
        v_org,
        case when v_is_sales then (v_alloc ->> 'item_id')::uuid else v_item_id end,
        case when v_is_sales then v_item_id else (v_alloc ->> 'item_id')::uuid end,
        round((v_alloc ->> 'amount')::numeric, 2),
        v_date
      );
    end loop;

  elsif coalesce((p_config ->> 'auto_allocate')::boolean, false) then
    v_remaining := v_amount;

    for v_target in
      select id, outstanding_amount
        from ledger_item_outstanding
       where organisation_id = v_org
         and contact_id = v_contact_id
         and ledger = v_ledger
         and direction = case when v_is_sales then 'debit' else 'credit' end
         and outstanding_amount > 0
       order by due_date nulls last, date
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_target.outstanding_amount);

      perform allocate_items(
        v_org,
        case when v_is_sales then v_target.id else v_item_id end,
        case when v_is_sales then v_item_id else v_target.id end,
        v_take,
        v_date
      );

      v_remaining := v_remaining - v_take;
    end loop;
  end if;

  return v_item_id;
end;
$$;

-- ---------------------------------------------------------------------
-- allocate_items
--
-- Links a debit item to a credit item. Refuses to over-allocate either
-- side, which is the guard that keeps the ledger agreeing with the
-- control account.
-- ---------------------------------------------------------------------

create or replace function allocate_items(
  p_organisation_id uuid,
  p_debit_item_id   uuid,
  p_credit_item_id  uuid,
  p_amount          numeric,
  p_date            date default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric(14,2) := round(p_amount, 2);
  v_debit  record;
  v_credit record;
  v_id     uuid;
begin
  if not is_org_member(p_organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_amount is null or v_amount <= 0 then
    raise exception 'An allocation must be for more than nil'
      using errcode = 'check_violation';
  end if;

  select * into v_debit from ledger_item_outstanding
   where id = p_debit_item_id and organisation_id = p_organisation_id;
  select * into v_credit from ledger_item_outstanding
   where id = p_credit_item_id and organisation_id = p_organisation_id;

  if v_debit is null or v_credit is null then
    raise exception 'One of those items does not exist' using errcode = 'no_data_found';
  end if;

  if v_debit.contact_id <> v_credit.contact_id then
    raise exception 'Those two items belong to different contacts'
      using errcode = 'check_violation';
  end if;

  if v_debit.direction <> 'debit' or v_credit.direction <> 'credit' then
    raise exception 'An allocation matches one debit item to one credit item'
      using errcode = 'check_violation';
  end if;

  if v_amount > v_debit.outstanding_amount + 0.001 then
    raise exception
      'Cannot allocate % to an item with only % outstanding',
      to_char(v_amount, 'FM999999990.00'),
      to_char(v_debit.outstanding_amount, 'FM999999990.00')
      using errcode = 'check_violation';
  end if;

  if v_amount > v_credit.outstanding_amount + 0.001 then
    raise exception
      'Only % of that payment is left to allocate',
      to_char(v_credit.outstanding_amount, 'FM999999990.00')
      using errcode = 'check_violation';
  end if;

  insert into allocation (
    organisation_id, debit_item_id, credit_item_id, amount, date, created_by
  ) values (
    p_organisation_id, p_debit_item_id, p_credit_item_id, v_amount,
    coalesce(p_date, current_date), auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

grant execute on function post_document(jsonb) to authenticated;
grant execute on function post_payment(jsonb) to authenticated;
grant execute on function allocate_items(uuid, uuid, uuid, numeric, date) to authenticated;
grant execute on function create_contact(jsonb) to authenticated;
grant execute on function aged_analysis(uuid, text, date) to authenticated;
grant execute on function contact_statement(uuid, uuid, date, date) to authenticated;
grant execute on function calculate_document_line(numeric, numeric, numeric, uuid, boolean) to authenticated;

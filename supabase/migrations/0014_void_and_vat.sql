-- =====================================================================
-- 0014_void_and_vat.sql
--
-- Two fixes.
--
-- 1. VOIDING. There was no way to undo a posted bill or invoice. Now
--    there is, and it works the way accounting software has to: the
--    document is never removed. It is marked void, its journal is
--    reversed, and both the original and the reversal stay in the
--    transaction list for ever. Anyone auditing the books can see that
--    something was entered and then taken back out, and when, and by
--    whom, and why.
--
-- 2. VAT ON A BUSINESS THAT IS NOT REGISTERED. post_document() applied
--    whatever VAT code it was given without checking whether the
--    organisation is VAT registered. The interface hid the VAT column
--    but still passed the default code, so a 20.00 bill posted as 20.00
--    net plus 4.00 VAT. Fixed at the database level rather than only in
--    the interface, so no caller can reintroduce it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Void audit columns
-- ---------------------------------------------------------------------

alter table document add column if not exists voided_at    timestamptz;
alter table document add column if not exists voided_by    uuid references auth.users(id);
alter table document add column if not exists void_reason  text;
alter table document add column if not exists void_journal_id uuid references journal(id);

-- ---------------------------------------------------------------------
-- void_document
--
-- Refuses if anything has been paid against it. A part-paid invoice
-- cannot simply be voided — the payment is real and has to be dealt
-- with first, either by unallocating it or by raising a credit note.
-- Silently voiding around a payment would leave the control account
-- disagreeing with the sub-ledger.
-- ---------------------------------------------------------------------

create or replace function void_document(
  p_document_id uuid,
  p_reason      text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc      document;
  v_item     ledger_item;
  v_out      record;
  v_reversal uuid;
  v_new_item uuid;
  v_debit    uuid;
  v_credit   uuid;
begin
  select * into v_doc from document where id = p_document_id;

  if not found then
    raise exception 'That document does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_doc.organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_doc.status = 'void' then
    raise exception 'That document has already been voided'
      using errcode = 'check_violation';
  end if;

  if v_doc.status <> 'posted' then
    raise exception 'Only a posted document can be voided'
      using errcode = 'check_violation';
  end if;

  select * into v_item from ledger_item where id = v_doc.ledger_item_id;

  if v_item.id is not null then
    select * into v_out from ledger_item_outstanding where id = v_item.id;

    if v_out.allocated_amount > 0 then
      raise exception
        'This has % of % settled against it. Unallocate the payment first, or raise a credit note instead.',
        to_char(v_out.allocated_amount, 'FM999999990.00'),
        to_char(v_item.gross_amount, 'FM999999990.00')
        using errcode = 'check_violation';
    end if;
  end if;

  -- Reverse the journal. The original stays exactly where it was.
  v_reversal := reverse_journal(
    v_doc.journal_id,
    greatest(v_doc.date, current_date),
    'Voided — ' || v_doc.number ||
      case when p_reason is null then '' else ': ' || p_reason end
  );

  -- Offset the settlement item so the document stops appearing as
  -- outstanding, without deleting the history of it having existed.
  if v_item.id is not null then
    insert into ledger_item (
      organisation_id, contact_id, ledger, item_type, direction,
      gross_amount, date, due_date, reference, description,
      currency_code, exchange_rate, journal_id, document_id
    ) values (
      v_doc.organisation_id, v_item.contact_id, v_item.ledger, 'contra',
      case when v_item.direction = 'debit' then 'credit' else 'debit' end,
      v_item.gross_amount,
      greatest(v_doc.date, current_date),
      greatest(v_doc.date, current_date),
      v_doc.number,
      'Void of ' || v_doc.number,
      v_item.currency_code, v_item.exchange_rate, v_reversal, v_doc.id
    )
    returning id into v_new_item;

    if v_item.direction = 'debit' then
      v_debit := v_item.id;
      v_credit := v_new_item;
    else
      v_debit := v_new_item;
      v_credit := v_item.id;
    end if;

    perform allocate_items(
      v_doc.organisation_id, v_debit, v_credit, v_item.gross_amount,
      greatest(v_doc.date, current_date)
    );
  end if;

  update document
     set status = 'void',
         voided_at = now(),
         voided_by = auth.uid(),
         void_reason = p_reason,
         void_journal_id = v_reversal
   where id = p_document_id;

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_doc.organisation_id, auth.uid(), 'document', p_document_id::text, 'voided',
          jsonb_build_object('number', v_doc.number, 'gross', v_doc.gross_total,
                             'reason', p_reason, 'reversal_journal', v_reversal));

  return v_reversal;
end;
$$;

grant execute on function void_document(uuid, text) to authenticated;

-- Voiding needs to write the status and the audit columns on a posted
-- document, so the immutability trigger has to know that is allowed.
create or replace function forbid_posted_document_change()
returns trigger
language plpgsql
as $$
begin
  if current_setting('app.ledger_unlocked', true) = 'on' then
    return coalesce(new, old);
  end if;

  if old.status = 'posted' or old.status = 'void' then
    if tg_op = 'DELETE' then
      raise exception
        'A posted document cannot be deleted. Void it instead — that keeps it on the record.'
        using errcode = 'insufficient_privilege';
    end if;

    -- The figures and the identity are fixed for ever. Status, the void
    -- audit columns and the PDF path may still change.
    if new.doc_type    is distinct from old.doc_type
       or new.contact_id  is distinct from old.contact_id
       or new.number      is distinct from old.number
       or new.date        is distinct from old.date
       or new.net_total   is distinct from old.net_total
       or new.vat_total   is distinct from old.vat_total
       or new.gross_total is distinct from old.gross_total
       or new.journal_id  is distinct from old.journal_id then
      raise exception
        'A posted document cannot be changed. Void it and enter it again, or raise a credit note.'
        using errcode = 'insufficient_privilege';
    end if;

    if old.status = 'void' and new.status <> 'void' then
      raise exception 'A voided document cannot be brought back. Enter it again.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

-- ---------------------------------------------------------------------
-- post_document with the VAT registration guard
--
-- Identical to the version in 0009 apart from one thing: if the
-- organisation is not VAT registered, every VAT code is ignored. Doing
-- it here rather than in the interface means the invoice screen, the
-- capture screen, the bank screen and anything built later all get it
-- right without having to remember.
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

    v_lines := v_lines || jsonb_build_object(
      'account_id',  v_account_id,
      'description', v_desc,
      'contact_id',  v_contact_id,
      'vat_code_id', v_vat_code_id,
      'net_amount',  case when v_is_credit then -v_net else v_net end,
      'vat_amount',  case when v_is_credit then -v_vat else v_vat end,
      'department_id', nullif(v_line ->> 'department_id', ''),
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

  if v_vat_total <> 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id',  case when v_is_sales then v_vat_output else v_vat_input end,
      'description', 'VAT',
      'contact_id',  v_contact_id,
      'debit',  case when v_is_sales <> v_is_credit then 0 else v_vat_total end,
      'credit', case when v_is_sales <> v_is_credit then v_vat_total else 0 end
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

-- ---------------------------------------------------------------------
-- The same guard on the bank coding path
-- ---------------------------------------------------------------------

-- Rather than a helper nobody remembers to call, the guard goes inside
-- create_from_statement_line() at the point the VAT code is read.

create or replace function apply_vat_guard(p_organisation_id uuid, p_vat_code_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select case
           when coalesce((select vat_enabled from organisation_feature
                           where organisation_id = p_organisation_id), false)
             then p_vat_code_id
           else null
         end;
$$;

grant execute on function apply_vat_guard(uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------
-- create_from_statement_line, re-issued with the VAT guard in place
--
-- 0013 defines this too; running 0014 after it replaces the definition.
-- Repeated here so that a database at 0013 and one at 0014 end up
-- identical regardless of the order the two were applied.
-- ---------------------------------------------------------------------

create or replace function create_from_statement_line(
  p_line_id uuid,
  p_config  jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line     statement_line;
  v_bank     bank_account;
  v_kind     text := coalesce(p_config ->> 'kind', 'nominal');
  v_is_in    boolean;
  v_abs      numeric(14,2);
  v_journal  uuid;
  v_item     uuid;
  v_bank_jl  uuid;
  v_account  uuid;
  v_vat      uuid;
  v_rate     numeric := 0;
  v_reverse  boolean := false;
  v_net      numeric(14,2);
  v_vat_amt  numeric(14,2);
  v_vat_acct uuid;
  v_lines    jsonb;
  v_target   uuid;
  v_rule     uuid;
begin
  select * into v_line from statement_line where id = p_line_id;
  if not found then
    raise exception 'That statement line does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_line.organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_line.status = 'matched' then
    raise exception 'That line has already been dealt with' using errcode = 'check_violation';
  end if;

  select * into v_bank from bank_account where id = v_line.bank_account_id;
  v_is_in := v_line.amount > 0;
  v_abs := abs(v_line.amount);

  -- ---------------- Settling an invoice or bill --------------------
  if v_kind = 'settle' then
    declare
      v_payload jsonb;
    begin
      v_payload := jsonb_build_object(
        'organisation_id', v_line.organisation_id,
        'ledger',          case when v_is_in then 'sales' else 'purchase' end,
        'contact_id',      p_config ->> 'contact_id',
        'bank_account_id', v_bank.account_id,
        'date',            v_line.date,
        'amount',          v_abs,
        'reference',       coalesce(nullif(p_config ->> 'reference', ''),
                                    v_line.reference, v_line.description)
      );

      -- Only send allocations when there are some. An empty array is not
      -- the same as "allocate these", and passing one would suppress
      -- automatic allocation.
      if jsonb_typeof(p_config -> 'allocations') = 'array'
         and jsonb_array_length(p_config -> 'allocations') > 0 then
        v_payload := v_payload || jsonb_build_object('allocations', p_config -> 'allocations');
      else
        v_payload := v_payload || jsonb_build_object('auto_allocate', true);
      end if;

      v_item := post_payment(v_payload);
    end;

    select journal_id into v_journal from ledger_item where id = v_item;

  -- ---------------- Transfer to another account -------------------
  elsif v_kind = 'transfer' then
    select account_id into v_target from bank_account
     where id = (p_config ->> 'to_bank_account_id')::uuid
       and organisation_id = v_line.organisation_id;

    if v_target is null then
      raise exception 'Choose the account the money went to'
        using errcode = 'no_data_found';
    end if;

    v_journal := post_journal(
      p_organisation_id => v_line.organisation_id,
      p_date            => v_line.date,
      p_description     => coalesce(nullif(p_config ->> 'description', ''),
                                    'Transfer — ' || v_line.description),
      p_lines           => jsonb_build_array(
        jsonb_build_object('account_id', v_bank.account_id,
          'description', v_line.description,
          'debit',  case when v_is_in then v_abs else 0 end,
          'credit', case when v_is_in then 0 else v_abs end),
        jsonb_build_object('account_id', v_target,
          'description', v_line.description,
          'debit',  case when v_is_in then 0 else v_abs end,
          'credit', case when v_is_in then v_abs else 0 end)
      ),
      p_reference       => v_line.reference,
      p_source_type     => 'bank_transfer',
      p_source_id       => p_line_id
    );

  -- ---------------- Straight to a category ------------------------
  else
    v_account := nullif(p_config ->> 'account_id', '')::uuid;
    -- apply_vat_guard() returns null when the organisation is not VAT
    -- registered, so a stray code from the interface cannot add VAT to a
    -- business that does not charge it. Defined in 0014.
    v_vat := apply_vat_guard(v_line.organisation_id,
                             nullif(p_config ->> 'vat_code_id', '')::uuid);

    if v_account is null then
      raise exception 'Choose a category for this transaction'
        using errcode = 'check_violation';
    end if;

    -- The bank figure is gross, so VAT comes out of it rather than
    -- being added on. Getting this the wrong way round is the classic
    -- bank-coding error.
    if v_vat is not null then
      select rate, is_reverse_charge into v_rate, v_reverse
        from vat_code where id = v_vat;
    end if;

    if v_reverse then
      v_rate := 0;
    end if;

    v_net := round(v_abs / (1 + coalesce(v_rate, 0) / 100.0), 2);
    v_vat_amt := v_abs - v_net;

    select id into v_vat_acct from account
     where organisation_id = v_line.organisation_id
       and control_type = case when v_is_in then 'vat_output' else 'vat_input' end;

    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_bank.account_id,
        'description', v_line.description,
        'contact_id', nullif(p_config ->> 'contact_id', ''),
        'debit',  case when v_is_in then v_abs else 0 end,
        'credit', case when v_is_in then 0 else v_abs end),
      jsonb_build_object('account_id', v_account,
        'description', coalesce(nullif(p_config ->> 'description', ''), v_line.description),
        'contact_id', nullif(p_config ->> 'contact_id', ''),
        'vat_code_id', v_vat,
        'net_amount', v_net,
        'vat_amount', v_vat_amt,
        'debit',  case when v_is_in then 0 else v_net end,
        'credit', case when v_is_in then v_net else 0 end)
    );

    if v_vat_amt <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_vat_acct,
        'description', 'VAT',
        'debit',  case when v_is_in then 0 else v_vat_amt end,
        'credit', case when v_is_in then v_vat_amt else 0 end);
    end if;

    v_journal := post_journal(
      p_organisation_id => v_line.organisation_id,
      p_date            => v_line.date,
      p_description     => coalesce(nullif(p_config ->> 'description', ''), v_line.description),
      p_lines           => v_lines,
      p_reference       => v_line.reference,
      p_source_type     => case when v_is_in then 'bank_receipt' else 'bank_payment' end,
      p_source_id       => p_line_id
    );
  end if;

  -- Reconcile against the bank side of whatever was just posted.
  select id into v_bank_jl
    from journal_line
   where journal_id = v_journal
     and account_id = v_bank.account_id
   limit 1;

  perform match_statement_line(p_line_id, v_bank_jl);

  -- If a rule was used, count the hit so the useful ones float up.
  v_rule := nullif(p_config ->> 'rule_id', '')::uuid;
  if v_rule is not null then
    update match_rule
       set hit_count = hit_count + 1, last_used_at = now()
     where id = v_rule;
  end if;

  -- Optionally remember this coding as a rule for next time.
  if coalesce((p_config ->> 'remember')::boolean, false)
     and v_kind = 'nominal' then
    insert into match_rule (
      organisation_id, bank_account_id, name, match_type, pattern,
      direction, account_id, contact_id, vat_code_id
    ) values (
      v_line.organisation_id, v_line.bank_account_id,
      left(v_line.description, 60),
      'contains',
      -- The first few words are the stable part; card and reference
      -- numbers on the end change every time.
      left(regexp_replace(v_line.description, '\s+', ' ', 'g'), 20),
      case when v_is_in then 'in' else 'out' end,
      nullif(p_config ->> 'account_id', '')::uuid,
      nullif(p_config ->> 'contact_id', '')::uuid,
      nullif(p_config ->> 'vat_code_id', '')::uuid
    );
  end if;

  return v_journal;
end;
$$;

grant execute on function create_from_statement_line(uuid, jsonb) to authenticated;

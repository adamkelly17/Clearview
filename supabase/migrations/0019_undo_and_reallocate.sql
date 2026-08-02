-- =====================================================================
-- 0019_undo_and_reallocate.sql
--
-- Three related changes.
--
-- 1. UNDO on a bank line. Both matched and ignored lines can go back to
--    "to deal with". Where a transaction was created from the line, the
--    undo reverses it — otherwise the ledger would keep a transaction
--    with nothing pointing at it.
--
-- 2. UNALLOCATING a payment from an invoice. The function existed but
--    nothing could reach it, so anyone told to "unallocate the payment
--    first" had no way to do so.
--
-- 3. EDITING an invoice that has been paid.
--
-- On that last one: it is safe, and the reason is that an allocation
-- never touches the nominal ledger. `allocation` records which payment
-- settles which invoice and nothing else — the money moved when the
-- payment was posted. So allocations can be taken apart and put back
-- together without the control account ever being wrong at any point.
--
-- What has to happen, in order:
--    unallocate, void, post the replacement, re-allocate what fits.
--
-- The one case that needs care is a replacement smaller than what was
-- paid. Editing a paid £600 invoice down to £400 leaves £200 the
-- customer has overpaid. That is a real credit and it goes on account,
-- rather than being quietly dropped.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Track what a statement line created
-- ---------------------------------------------------------------------

alter table statement_line
  add column if not exists created_journal_id uuid references journal(id);

-- Existing rows: a journal whose source_id is the line was created from
-- it. The settle path posted through post_payment() without a source_id,
-- so those older lines will undo as a simple unlink.
update statement_line sl
   set created_journal_id = j.id
  from journal j
 where j.source_id = sl.id
   and j.organisation_id = sl.organisation_id
   and sl.created_journal_id is null;

-- ---------------------------------------------------------------------
-- create_from_statement_line, re-issued so it records what it created
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

  -- Remember that this transaction was created from the line rather than
  -- matched to something that already existed. Undoing the line later
  -- has to reverse it; without this it would be left orphaned in the
  -- ledger with nothing pointing at it.
  update statement_line set created_journal_id = v_journal where id = p_line_id;

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

-- ---------------------------------------------------------------------
-- Unallocating
--
-- Removes every allocation touching an item, putting both sides back to
-- fully outstanding. Nothing in the nominal ledger moves, because
-- nothing moved when they were allocated.
-- ---------------------------------------------------------------------

create or replace function unallocate_item(p_ledger_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item  ledger_item;
  v_count int;
  v_total numeric(14,2);
begin
  select * into v_item from ledger_item where id = p_ledger_item_id;

  if not found then
    raise exception 'That item does not exist' using errcode = 'no_data_found';
  end if;

  if not has_org_role(v_item.organisation_id, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to unallocate'
      using errcode = 'insufficient_privilege';
  end if;

  select count(*), coalesce(sum(amount), 0) into v_count, v_total
    from allocation
   where debit_item_id = p_ledger_item_id or credit_item_id = p_ledger_item_id;

  if v_count = 0 then
    return jsonb_build_object('removed', 0,
      'message', 'Nothing was allocated against that.');
  end if;

  -- Logged before deleting, because the allocation rows are about to
  -- stop existing and the fact of them is worth keeping.
  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  select v_item.organisation_id, auth.uid(), 'allocation', a.id::text, 'unallocated',
         jsonb_build_object('debit_item', a.debit_item_id, 'credit_item', a.credit_item_id,
                            'amount', a.amount, 'date', a.date)
    from allocation a
   where a.debit_item_id = p_ledger_item_id or a.credit_item_id = p_ledger_item_id;

  delete from allocation
   where debit_item_id = p_ledger_item_id or credit_item_id = p_ledger_item_id;

  return jsonb_build_object('removed', v_count, 'amount', v_total);
end;
$$;

grant execute on function unallocate_item(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Undo a statement line
-- ---------------------------------------------------------------------

create or replace function undo_statement_line(p_line_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line     statement_line;
  v_reversal uuid;
  v_items    int := 0;
begin
  select * into v_line from statement_line where id = p_line_id;

  if not found then
    raise exception 'That statement line does not exist' using errcode = 'no_data_found';
  end if;

  if not has_org_role(v_line.organisation_id, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to undo this'
      using errcode = 'insufficient_privilege';
  end if;

  if v_line.status = 'unmatched' then
    return jsonb_build_object('undone', false,
      'message', 'That line is already waiting to be dealt with.');
  end if;

  -- ---- Ignored: nothing was ever posted --------------------------
  if v_line.status = 'excluded' then
    update statement_line
       set status = 'unmatched', status_detail = null
     where id = p_line_id;

    return jsonb_build_object('undone', true, 'reversed', false,
      'message', 'Back in the list to deal with.');
  end if;

  -- ---- Created from this line: reverse it ------------------------
  if v_line.created_journal_id is not null then
    -- The reversal keeps both sides on the record. What it cannot do on
    -- its own is tidy the sub-ledger, so that is done here.
    v_reversal := reverse_journal(
      v_line.created_journal_id,
      greatest(v_line.date, current_date),
      'Undone from the bank screen');

    -- Anything in the sales or purchase ledger created by that journal
    -- has to go with it, or the control account and the sub-ledger stop
    -- agreeing. Allocations first, then the items themselves.
    delete from allocation
     where debit_item_id in (select id from ledger_item where journal_id = v_line.created_journal_id)
        or credit_item_id in (select id from ledger_item where journal_id = v_line.created_journal_id);

    delete from ledger_item where journal_id = v_line.created_journal_id;
    get diagnostics v_items = row_count;
  end if;

  -- ---- Release the reconciliation --------------------------------
  if v_line.matched_journal_line_id is not null then
    perform set_line_reconciled(v_line.matched_journal_line_id, null, false);
  end if;

  update statement_line
     set status = 'unmatched',
         status_detail = null,
         matched_journal_line_id = null,
         matched_at = null,
         matched_by = null,
         created_journal_id = null
   where id = p_line_id;

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_line.organisation_id, auth.uid(), 'statement_line', p_line_id::text, 'undone',
          jsonb_build_object('was', v_line.status, 'reversal_journal', v_reversal,
                             'ledger_items_removed', v_items));

  return jsonb_build_object(
    'undone', true,
    'reversed', v_reversal is not null,
    'message', case
      when v_reversal is not null
        then 'The transaction it created has been reversed. Both entries stay on the record.'
      else 'Unmatched. The transaction it was matched to is untouched.'
    end
  );
end;
$$;

grant execute on function undo_statement_line(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Editing an invoice that has been paid
--
-- Returns what happened rather than just the new id, because "£200 is now
-- sitting on account" is something the user has to be told.
-- ---------------------------------------------------------------------

-- The 0015 version returned the new document's id. It now returns what
-- happened, because "£200 is sitting on account" is something the user
-- has to be told. Postgres will not change a return type in place.
drop function if exists replace_document(uuid, jsonb, text);

create function replace_document(
  p_document_id uuid,
  p_config      jsonb,
  p_reason      text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old        document;
  v_new_id     uuid;
  v_new_num    text;
  v_new_item   uuid;
  v_config     jsonb;
  v_alloc      record;
  v_held       jsonb := '[]'::jsonb;
  v_restored   numeric(14,2) := 0;
  v_unmatched  numeric(14,2) := 0;
  v_take       numeric(14,2);
  v_remaining  numeric(14,2);
  v_available  numeric(14,2);
  v_direction  text;
begin
  select * into v_old from document where id = p_document_id;

  if not found then
    raise exception 'That document does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_old.organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_old.status <> 'posted' then
    raise exception 'Only a posted document can be edited'
      using errcode = 'check_violation';
  end if;

  -- A document already reported on a filed VAT return must not move. No
  -- return can be filed yet, but the guard belongs here now rather than
  -- being remembered later.
  if exists (
    select 1 from journal_line
     where journal_id = v_old.journal_id and vat_return_id is not null
  ) then
    raise exception
      'This has already been included on a filed VAT return and cannot be edited. Raise a credit note instead.'
      using errcode = 'check_violation';
  end if;

  -- ---- Remember what was settled against it, then let it go -------
  if v_old.ledger_item_id is not null then
    select direction into v_direction from ledger_item where id = v_old.ledger_item_id;

    for v_alloc in
      select a.id,
             case when a.debit_item_id = v_old.ledger_item_id
                  then a.credit_item_id else a.debit_item_id end as other_item_id,
             a.amount, a.date
        from allocation a
       where a.debit_item_id = v_old.ledger_item_id
          or a.credit_item_id = v_old.ledger_item_id
       order by a.date
    loop
      v_held := v_held || jsonb_build_object(
        'other_item_id', v_alloc.other_item_id,
        'amount', v_alloc.amount,
        'date', v_alloc.date);
    end loop;

    if jsonb_array_length(v_held) > 0 then
      -- Safe because an allocation never touched the nominal ledger. The
      -- money moved when the payment was posted; this only records which
      -- invoice it answers to.
      perform unallocate_item(v_old.ledger_item_id);
    end if;
  end if;

  -- ---- Void, then post the replacement ----------------------------
  perform void_document(p_document_id, coalesce(p_reason, 'Edited'));

  v_config := jsonb_build_object('organisation_id', v_old.organisation_id) || p_config;

  if not (v_config ? 'number') or nullif(v_config ->> 'number', '') is null then
    v_config := v_config || jsonb_build_object('number', v_old.number);
  end if;

  if not (v_config ? 'doc_type') then
    v_config := v_config || jsonb_build_object('doc_type', v_old.doc_type);
  end if;

  v_new_id := post_document(v_config);

  select number, ledger_item_id into v_new_num, v_new_item
    from document where id = v_new_id;

  -- ---- Put the payments back where they will fit ------------------
  if jsonb_array_length(v_held) > 0 and v_new_item is not null then
    select outstanding_amount into v_remaining
      from ledger_item_outstanding where id = v_new_item;

    select direction into v_direction from ledger_item where id = v_new_item;

    for v_alloc in select * from jsonb_array_elements(v_held)
    loop
      exit when v_remaining <= 0;

      select outstanding_amount into v_available
        from ledger_item_outstanding
       where id = (v_alloc.value ->> 'other_item_id')::uuid;

      v_take := least(
        (v_alloc.value ->> 'amount')::numeric,
        v_remaining,
        coalesce(v_available, 0));

      if v_take > 0 then
        perform allocate_items(
          v_old.organisation_id,
          case when v_direction = 'debit' then v_new_item
               else (v_alloc.value ->> 'other_item_id')::uuid end,
          case when v_direction = 'debit' then (v_alloc.value ->> 'other_item_id')::uuid
               else v_new_item end,
          v_take,
          (v_alloc.value ->> 'date')::date);

        v_restored := v_restored + v_take;
        v_remaining := v_remaining - v_take;
      end if;
    end loop;

    -- Whatever would not fit stays on account as a credit. Editing a paid
    -- £600 invoice down to £400 leaves £200 the customer has overpaid,
    -- and that is a real balance owed back to them.
    select coalesce(sum((value ->> 'amount')::numeric), 0) - v_restored
      into v_unmatched
      from jsonb_array_elements(v_held);
  end if;

  perform set_config('app.ledger_unlocked', 'on', true);

  update document
     set replaced_by_document_id = v_new_id,
         void_reason = 'Replaced by ' || v_new_num ||
           case when p_reason is null or p_reason = 'Edited'
                then '' else ' — ' || p_reason end
   where id = p_document_id;

  update document set replaces_document_id = p_document_id where id = v_new_id;

  perform set_config('app.ledger_unlocked', 'off', true);

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_old.organisation_id, auth.uid(), 'document', p_document_id::text, 'replaced',
          jsonb_build_object(
            'old_number', v_old.number, 'old_gross', v_old.gross_total,
            'new_document', v_new_id, 'new_number', v_new_num,
            'payments_reapplied', v_restored,
            'left_on_account', v_unmatched,
            'reason', p_reason));

  return jsonb_build_object(
    'new_document_id', v_new_id,
    'new_number', v_new_num,
    'payments_reapplied', v_restored,
    'left_on_account', greatest(v_unmatched, 0)
  );
end;
$$;

grant execute on function replace_document(uuid, jsonb, text) to authenticated;

-- Voiding keeps its restriction. Unlike an edit there is no replacement
-- for a payment to move to, so it has to be dealt with deliberately
-- first — the message points at the unallocate button.

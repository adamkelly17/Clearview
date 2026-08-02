-- =====================================================================
-- Undo on bank lines, unallocation, and the awkward edges of editing an
-- invoice that has been paid.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user uuid := gen_random_uuid();
  v_org  uuid; v_cust uuid; v_supp uuid;
  v_sales uuid; v_cost uuid; v_bank_nom uuid; v_bank uuid; v_elec uuid;
  v_inv uuid; v_item uuid; v_pay uuid; v_line uuid;
  v_res jsonb; v_n numeric; v_c int;
begin
  insert into auth.users (id, email) values (v_user, 'undo@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name','Undo Ltd','entity_type_code','limited_company',
    'year_end_day',31,'year_end_month',3,
    'books_start_date','2026-04-01','vat_enabled',false));

  select id into v_sales from account where organisation_id = v_org and code='4000';
  select id into v_cost  from account where organisation_id = v_org and code='5000';
  select id into v_elec  from account where organisation_id = v_org and code='7200';
  select ba.id, ba.account_id into v_bank, v_bank_nom
    from bank_account ba join account a on a.id = ba.account_id
   where ba.organisation_id = v_org and a.code='1200';

  v_cust := create_contact(jsonb_build_object(
    'organisation_id',v_org,'name','Hartley','is_customer',true));
  v_supp := create_contact(jsonb_build_object(
    'organisation_id',v_org,'name','Timber','is_supplier',true));

  -- ===============================================================
  raise notice '--- Editing a fully paid invoice DOWN below what was paid';
  -- ===============================================================

  v_inv := post_document(jsonb_build_object(
    'organisation_id',v_org,'doc_type','SI','contact_id',v_cust,'date','2026-05-01',
    'lines', jsonb_build_array(jsonb_build_object(
      'description','Kitchen','quantity',1,'unit_price',600,'account_id',v_sales))));

  select ledger_item_id into v_item from document where id = v_inv;

  perform post_payment(jsonb_build_object(
    'organisation_id',v_org,'ledger','sales','contact_id',v_cust,
    'bank_account_id',v_bank_nom,'date','2026-05-10','amount',600.00,
    'allocations', jsonb_build_array(jsonb_build_object('item_id',v_item,'amount',600.00))));

  if (select outstanding_amount from ledger_item_outstanding where id = v_item) <> 0 then
    raise exception 'FAIL: the invoice should be fully paid to start with';
  end if;

  -- The work was actually only worth 400.
  v_res := replace_document(v_inv, jsonb_build_object(
    'doc_type','SI','contact_id',v_cust,'date','2026-05-01',
    'lines', jsonb_build_array(jsonb_build_object(
      'description','Kitchen, reduced','quantity',1,'unit_price',400,'account_id',v_sales))),
    'Overcharged');

  if (v_res ->> 'payments_reapplied')::numeric <> 400.00 then
    raise exception 'FAIL: only 400.00 should fit on the new invoice, got %',
      v_res ->> 'payments_reapplied';
  end if;
  raise notice 'PASS  400.00 of the payment goes onto the smaller invoice';

  if (v_res ->> 'left_on_account')::numeric <> 200.00 then
    raise exception 'FAIL: 200.00 should be left on account, got %',
      v_res ->> 'left_on_account';
  end if;
  raise notice 'PASS  the 200.00 overpayment is reported as left on account';

  -- The customer is genuinely owed 200. Debtors must show that.
  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'debtors';
  if v_n <> -200.00 then
    raise exception 'FAIL: trade debtors should be -200.00 (they overpaid), got %', v_n;
  end if;
  raise notice 'PASS  trade debtors shows -200.00, which is what they are owed back';

  select coalesce(sum(case when direction='debit' then outstanding_amount
                           else -outstanding_amount end), 0) into v_n
    from ledger_item_outstanding where organisation_id = v_org and ledger='sales';
  if v_n <> -200.00 then
    raise exception 'FAIL: the sales ledger should also show -200.00, got %', v_n;
  end if;
  raise notice 'PASS  the sales ledger agrees with the control account throughout';

  -- ===============================================================
  raise notice '--- Editing a paid invoice UP';
  -- ===============================================================

  v_inv := post_document(jsonb_build_object(
    'organisation_id',v_org,'doc_type','PI','contact_id',v_supp,'date','2026-05-02',
    'number','T-1',
    'lines', jsonb_build_array(jsonb_build_object(
      'description','Oak','quantity',1,'unit_price',300,'account_id',v_cost))));

  select ledger_item_id into v_item from document where id = v_inv;

  perform post_payment(jsonb_build_object(
    'organisation_id',v_org,'ledger','purchase','contact_id',v_supp,
    'bank_account_id',v_bank_nom,'date','2026-05-12','amount',300.00,
    'allocations', jsonb_build_array(jsonb_build_object('item_id',v_item,'amount',300.00))));

  v_res := replace_document(v_inv, jsonb_build_object(
    'doc_type','PI','contact_id',v_supp,'date','2026-05-02','number','T-1',
    'lines', jsonb_build_array(jsonb_build_object(
      'description','Oak, corrected','quantity',1,'unit_price',450,'account_id',v_cost))),
    'Undercharged');

  if (v_res ->> 'payments_reapplied')::numeric <> 300.00 then
    raise exception 'FAIL: the whole 300.00 should go back on, got %',
      v_res ->> 'payments_reapplied';
  end if;
  if (v_res ->> 'left_on_account')::numeric <> 0 then
    raise exception 'FAIL: nothing should be on account';
  end if;
  raise notice 'PASS  editing up reapplies the whole payment, leaving 150.00 still to pay';

  if (select outstanding_amount from ledger_item_outstanding
       where id = (select ledger_item_id from document
                    where id = (v_res ->> 'new_document_id')::uuid)) <> 150.00 then
    raise exception 'FAIL: 150.00 should remain outstanding';
  end if;
  raise notice 'PASS  the replacement shows 150.00 outstanding';

  -- ===============================================================
  raise notice '--- Unallocating by hand';
  -- ===============================================================

  select ledger_item_id into v_item
    from document where id = (v_res ->> 'new_document_id')::uuid;

  v_res := unallocate_item(v_item);
  if (v_res ->> 'removed')::int <> 1 then
    raise exception 'FAIL: one allocation should have been removed, got %', v_res ->> 'removed';
  end if;
  if (select outstanding_amount from ledger_item_outstanding where id = v_item) <> 450.00 then
    raise exception 'FAIL: the bill should be fully outstanding again';
  end if;
  raise notice 'PASS  unallocating puts the bill back to 450.00 and frees the payment';

  select coalesce(sum(jl.credit - jl.debit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'creditors';
  if v_n <> 150.00 then
    raise exception 'FAIL: unallocating must not move the nominal ledger, got %', v_n;
  end if;
  raise notice 'PASS  the nominal ledger did not move — allocations are sub-ledger only';

  -- ===============================================================
  raise notice '--- Undo on the bank screen';
  -- ===============================================================

  perform import_statement(jsonb_build_object(
    'organisation_id',v_org,'bank_account_id',v_bank,'name','May',
    'lines', jsonb_build_array(
      jsonb_build_object('date','2026-05-20','description','EDF ENERGY','amount',-120.00),
      jsonb_build_object('date','2026-05-21','description','PERSONAL','amount',-40.00))));

  -- (a) A line we coded ourselves
  select id into v_line from statement_line
   where bank_account_id = v_bank and description = 'EDF ENERGY';

  perform create_from_statement_line(v_line, jsonb_build_object(
    'kind','nominal','account_id',v_elec));

  select coalesce(sum(debit - credit), 0) into v_n from journal_line where account_id = v_elec;
  if v_n <> 120.00 then
    raise exception 'FAIL: electricity should be 120.00';
  end if;

  v_res := undo_statement_line(v_line);

  if (v_res ->> 'reversed')::boolean is not true then
    raise exception 'FAIL: undoing a created transaction should reverse it';
  end if;
  if (select status from statement_line where id = v_line) <> 'unmatched' then
    raise exception 'FAIL: the line should be back to unmatched';
  end if;
  raise notice 'PASS  undo put the line back and reversed what it created';

  select coalesce(sum(debit - credit), 0) into v_n from journal_line where account_id = v_elec;
  if v_n <> 0 then
    raise exception 'FAIL: electricity should be back to nil, got %', v_n;
  end if;
  raise notice 'PASS  the electricity account is back to nil';

  select count(*) into v_c from journal
   where organisation_id = v_org and source_type in ('bank_payment','reversal');
  if v_c < 2 then
    raise exception 'FAIL: both the original and the reversal should remain';
  end if;
  raise notice 'PASS  both entries stay in the audit trail';

  -- (b) An ignored line
  select id into v_line from statement_line
   where bank_account_id = v_bank and description = 'PERSONAL';

  perform exclude_statement_line(v_line, 'Personal');
  v_res := undo_statement_line(v_line);

  if (v_res ->> 'reversed')::boolean is not false then
    raise exception 'FAIL: nothing was posted, so nothing should be reversed';
  end if;
  if (select status from statement_line where id = v_line) <> 'unmatched' then
    raise exception 'FAIL: the ignored line should be back to unmatched';
  end if;
  raise notice 'PASS  an ignored line comes back with nothing reversed';

  -- (c) Undoing a settle removes the sub-ledger it created
  v_inv := post_document(jsonb_build_object(
    'organisation_id',v_org,'doc_type','SI','contact_id',v_cust,'date','2026-05-25',
    'lines', jsonb_build_array(jsonb_build_object(
      'description','Job','quantity',1,'unit_price',75,'account_id',v_sales))));

  perform import_statement(jsonb_build_object(
    'organisation_id',v_org,'bank_account_id',v_bank,'name','Late May',
    'lines', jsonb_build_array(
      jsonb_build_object('date','2026-05-28','description','HARTLEY','amount',75.00))));

  select id into v_line from statement_line
   where bank_account_id = v_bank and description = 'HARTLEY';

  perform create_from_statement_line(v_line, jsonb_build_object(
    'kind','settle','contact_id',v_cust,'auto_allocate',true));

  select ledger_item_id into v_item from document where id = v_inv;
  if (select outstanding_amount from ledger_item_outstanding where id = v_item) <> 0 then
    raise exception 'FAIL: setup — the receipt should have settled the 75.00 invoice, % left',
      (select outstanding_amount from ledger_item_outstanding where id = v_item);
  end if;
  raise notice 'PASS  the receipt settled the invoice to start with';

  v_res := undo_statement_line(v_line);

  if (select outstanding_amount from ledger_item_outstanding where id = v_item) <> 75.00 then
    raise exception 'FAIL: the invoice should be outstanding again after the undo';
  end if;
  raise notice 'PASS  undoing a receipt puts the invoice back to outstanding';

  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'debtors';
  select coalesce(sum(case when direction='debit' then outstanding_amount
                           else -outstanding_amount end), 0) into v_c
    from ledger_item_outstanding where organisation_id = v_org and ledger='sales';

  if v_n <> v_c then
    raise exception 'FAIL: after undo, debtors % disagrees with the sales ledger %', v_n, v_c;
  end if;
  raise notice 'PASS  debtors and the sales ledger still agree at % after the undo',
    to_char(v_n, 'FM999999990.00');

  -- ===============================================================
  raise notice '--- Still sound';
  -- ===============================================================

  select sum(debit) into v_n from trial_balance(v_org, '2027-03-31');
  if v_n <> (select sum(credit) from trial_balance(v_org, '2027-03-31')) then
    raise exception 'FAIL: trial balance out of balance';
  end if;
  raise notice 'PASS  trial balance agrees at %', to_char(v_n, 'FM999999990.00');

  raise notice '';
  raise notice 'All undo and reallocation tests passed.';
end;
$$;

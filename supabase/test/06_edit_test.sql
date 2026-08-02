-- =====================================================================
-- Editing a posted document, and the contact activity view.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user   uuid := gen_random_uuid();
  v_org    uuid;
  v_cust   uuid;
  v_supp   uuid;
  v_supp2  uuid;
  v_sales  uuid;
  v_post   uuid;
  v_rent   uuid;
  v_bank   uuid;
  v_t1     uuid;
  v_t0     uuid;
  v_inv    uuid;
  v_new    uuid;
  v_bill   uuid;
  v_n      numeric;
  v_count  int;
  v_text   text;
  v_doc    jsonb;
begin
  insert into auth.users (id, email) values (v_user, 'edit@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name', 'Brookfield Joinery Ltd', 'entity_type_code', 'limited_company',
    'year_end_day', 31, 'year_end_month', 3,
    'books_start_date', '2026-04-01', 'vat_enabled', true));

  select id into v_sales from account where organisation_id = v_org and code = '4000';
  select id into v_post  from account where organisation_id = v_org and code = '7501';
  select id into v_rent  from account where organisation_id = v_org and code = '7100';
  select id into v_bank  from account where organisation_id = v_org and code = '1200';
  select id into v_t1    from vat_code where organisation_id = v_org and code = 'T1';
  select id into v_t0    from vat_code where organisation_id = v_org and code = 'T0';

  v_cust  := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Hartley Developments', 'is_customer', true));
  v_supp  := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Timber Supplies Ltd', 'is_supplier', true));
  v_supp2 := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Ashridge Plant Hire', 'is_supplier', true));

  -- ---------------------------------------------------------------
  raise notice '--- Reading a document back for editing';
  -- ---------------------------------------------------------------

  v_inv := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'SI', 'contact_id', v_cust,
    'date', '2026-05-01', 'their_reference', 'Job 214',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Kitchen fit', 'quantity', 1,
        'unit_price', 1000, 'account_id', v_sales, 'vat_code_id', v_t1),
      jsonb_build_object('description', 'Materials', 'quantity', 4,
        'unit_price', 50, 'account_id', v_sales, 'vat_code_id', v_t1))));

  v_doc := document_for_edit(v_inv);

  if jsonb_array_length(v_doc -> 'lines') <> 2 then
    raise exception 'FAIL: both lines should come back for editing';
  end if;
  if (v_doc ->> 'their_reference') <> 'Job 214' then
    raise exception 'FAIL: the reference did not come back';
  end if;
  raise notice 'PASS  document and both lines read back in one call';

  select number into v_text from document where id = v_inv;
  raise notice 'PASS  original is %, gross %', v_text,
    (select to_char(gross_total, 'FM999999990.00') from document where id = v_inv);

  -- ---------------------------------------------------------------
  raise notice '--- Editing it';
  -- ---------------------------------------------------------------

  v_new := replace_document(v_inv, jsonb_build_object(
    'doc_type', 'SI',
    'contact_id', v_cust,
    'date', '2026-05-03',
    'their_reference', 'Job 214a',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Kitchen fit, revised', 'quantity', 1,
        'unit_price', 1400, 'account_id', v_sales, 'vat_code_id', v_t1))),
    'Wrong price agreed');

  if (select status from document where id = v_inv) <> 'void' then
    raise exception 'FAIL: the original should be void';
  end if;
  raise notice 'PASS  the original is voided, not deleted';

  if (select gross_total from document where id = v_new) <> 1680.00 then
    raise exception 'FAIL: the replacement should gross 1680.00, got %',
      (select gross_total from document where id = v_new);
  end if;
  raise notice 'PASS  the replacement posts at the corrected 1680.00';

  -- The number carries over, which matters because the customer already
  -- has a document with that number on it.
  if (select number from document where id = v_new)
     <> (select number from document where id = v_inv) then
    raise exception 'FAIL: the replacement should keep the same number, got % vs %',
      (select number from document where id = v_new),
      (select number from document where id = v_inv);
  end if;
  raise notice 'PASS  the replacement keeps the same document number';

  if (select replaced_by_document_id from document where id = v_inv) <> v_new then
    raise exception 'FAIL: the original is not linked forward';
  end if;
  if (select replaces_document_id from document where id = v_new) <> v_inv then
    raise exception 'FAIL: the replacement is not linked back';
  end if;
  raise notice 'PASS  linked in both directions';

  select void_reason into v_text from document where id = v_inv;
  if v_text not like 'Replaced by %' or v_text not like '%Wrong price agreed%' then
    raise exception 'FAIL: void reason should name the replacement and the reason, got %', v_text;
  end if;
  raise notice 'PASS  original records "%"', v_text;

  -- ---------------------------------------------------------------
  raise notice '--- The books show only the corrected figure';
  -- ---------------------------------------------------------------

  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'debtors';

  if v_n <> 1680.00 then
    raise exception 'FAIL: debtors should be 1680.00, not 1200 plus 1680, got %', v_n;
  end if;
  raise notice 'PASS  trade debtors shows 1680.00, the original having been reversed out';

  select coalesce(sum(jl.credit - jl.debit), 0) into v_n
    from journal_line jl where jl.account_id = v_sales;
  if v_n <> 1400.00 then
    raise exception 'FAIL: sales should be 1400.00, got %', v_n;
  end if;
  raise notice 'PASS  income shows 1400.00 net';

  -- ---------------------------------------------------------------
  raise notice '--- But the audit trail keeps everything';
  -- ---------------------------------------------------------------

  select count(*) into v_count from journal
   where organisation_id = v_org and source_type in ('sales_invoice', 'reversal');
  if v_count <> 3 then
    raise exception 'FAIL: expected the original, its reversal and the replacement, found %', v_count;
  end if;
  raise notice 'PASS  three journals remain: original, reversal, replacement';

  if not exists (
    select 1 from audit_log
     where organisation_id = v_org and action = 'replaced' and record_id = v_inv::text
  ) then
    raise exception 'FAIL: the replacement was not logged';
  end if;
  raise notice 'PASS  logged as a replacement with the old and new figures';

  select count(*) into v_count from document_line
   where document_id = v_inv;
  if v_count <> 2 then
    raise exception 'FAIL: the original lines should survive for inspection';
  end if;
  raise notice 'PASS  the original lines survive so the old version can still be read';

  -- ---------------------------------------------------------------
  raise notice '--- Everything about a document can change';
  -- ---------------------------------------------------------------

  v_bill := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'PI', 'contact_id', v_supp,
    'date', '2026-05-05', 'number', 'TS-100',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Postage', 'quantity', 1, 'unit_price', 100,
      'account_id', v_post, 'vat_code_id', v_t1))));

  -- Different supplier, different number, different date, different
  -- category, different VAT treatment, different amount.
  v_new := replace_document(v_bill, jsonb_build_object(
    'doc_type', 'PI',
    'contact_id', v_supp2,
    'date', '2026-06-11',
    'number', 'APH-777',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Excavator hire', 'quantity', 2, 'unit_price', 250,
      'account_id', v_rent, 'vat_code_id', v_t0))),
    'Booked against the wrong supplier');

  if (select contact_id from document where id = v_new) <> v_supp2 then
    raise exception 'FAIL: the supplier did not change';
  end if;
  if (select number from document where id = v_new) <> 'APH-777' then
    raise exception 'FAIL: the number did not change';
  end if;
  if (select date from document where id = v_new) <> '2026-06-11' then
    raise exception 'FAIL: the date did not change';
  end if;
  if (select vat_total from document where id = v_new) <> 0 then
    raise exception 'FAIL: switching to zero rate should remove the VAT, got %',
      (select vat_total from document where id = v_new);
  end if;
  if (select gross_total from document where id = v_new) <> 500.00 then
    raise exception 'FAIL: expected 500.00, got %',
      (select gross_total from document where id = v_new);
  end if;
  raise notice 'PASS  supplier, number, date, category, VAT and amount all changed';

  -- The old supplier should be left owing nothing.
  select coalesce(sum(total), 0) into v_n
    from aged_analysis(v_org, 'purchase', '2027-03-31') where contact_id = v_supp;
  if v_n <> 0 then
    raise exception 'FAIL: the original supplier should owe nothing now, got %', v_n;
  end if;
  raise notice 'PASS  the wrongly-billed supplier is left owing nothing';

  -- ---------------------------------------------------------------
  raise notice '--- Guards';
  -- ---------------------------------------------------------------

  begin
    perform replace_document(v_inv, jsonb_build_object(
      'doc_type', 'SI', 'contact_id', v_cust, 'date', '2026-05-01',
      'lines', jsonb_build_array(jsonb_build_object(
        'description', 'x', 'quantity', 1, 'unit_price', 10,
        'account_id', v_sales, 'vat_code_id', v_t1))));
    raise exception 'FAIL: edited an already voided document';
  exception when check_violation then
    raise notice 'PASS  editing a voided document refused';
  end;

  -- Part paid
  v_inv := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'SI', 'contact_id', v_cust,
    'date', '2026-07-01',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Bathroom', 'quantity', 1, 'unit_price', 500,
      'account_id', v_sales, 'vat_code_id', v_t1))));

  -- Allocate explicitly. Auto-allocation would settle the oldest
  -- outstanding item, which is a different invoice.
  perform post_payment(jsonb_build_object(
    'organisation_id', v_org, 'ledger', 'sales', 'contact_id', v_cust,
    'bank_account_id', v_bank, 'date', '2026-07-05',
    'amount', 100.00,
    'allocations', jsonb_build_array(jsonb_build_object(
      'item_id', (select ledger_item_id from document where id = v_inv),
      'amount', 100.00))));

  begin
    perform replace_document(v_inv, jsonb_build_object(
      'doc_type', 'SI', 'contact_id', v_cust, 'date', '2026-07-01',
      'lines', jsonb_build_array(jsonb_build_object(
        'description', 'Bathroom', 'quantity', 1, 'unit_price', 600,
        'account_id', v_sales, 'vat_code_id', v_t1))));
    raise exception 'FAIL: edited a part-paid invoice';
  exception when check_violation then
    raise notice 'PASS  editing a part-paid invoice refused, with the amount named';
  end;

  -- ---------------------------------------------------------------
  raise notice '--- Contact activity';
  -- ---------------------------------------------------------------

  select count(*) into v_count
    from contact_activity(v_org, v_cust, true);
  raise notice 'PASS  outstanding only returns % item(s)', v_count;

  if exists (
    select 1 from contact_activity(v_org, v_cust, true) where document_status = 'void'
  ) then
    raise exception 'FAIL: voided documents should not show in the outstanding view';
  end if;
  raise notice 'PASS  voided documents excluded from the outstanding view';

  if exists (
    select 1 from contact_activity(v_org, v_cust, true) where outstanding_amount <= 0
  ) then
    raise exception 'FAIL: settled items should not show in the outstanding view';
  end if;
  raise notice 'PASS  settled items excluded from the outstanding view';

  select count(*) into v_count from contact_activity(v_org, v_cust, false);
  if v_count <= (select count(*) from contact_activity(v_org, v_cust, true)) then
    raise exception 'FAIL: the full view should show more than the outstanding view';
  end if;
  raise notice 'PASS  the full view shows everything — % rows including voided and settled', v_count;

  if not exists (
    select 1 from contact_activity(v_org, v_cust, false) where replaced_by is not null
  ) then
    raise exception 'FAIL: the full view should name what replaced a voided document';
  end if;
  raise notice 'PASS  the full view names the document that replaced each voided one';

  -- The running balance over the full list must equal what is owed.
  select running_balance into v_n
    from contact_activity(v_org, v_cust, false)
   order by date desc, item_id desc limit 1;

  select coalesce(sum(jl.debit - jl.credit), 0) into v_count
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'debtors'
     and jl.contact_id = v_cust;

  if v_n <> v_count then
    raise exception 'FAIL: statement balance % disagrees with the ledger %', v_n, v_count;
  end if;
  raise notice 'PASS  the closing balance agrees with trade debtors at %',
    to_char(v_n, 'FM999999990.00');

  -- ---------------------------------------------------------------
  raise notice '--- Still sound';
  -- ---------------------------------------------------------------

  select sum(debit) into v_n from trial_balance(v_org, '2027-03-31');
  if v_n <> (select sum(credit) from trial_balance(v_org, '2027-03-31')) then
    raise exception 'FAIL: trial balance out of balance';
  end if;
  raise notice 'PASS  trial balance agrees at %', to_char(v_n, 'FM999999990.00');

  raise notice '';
  raise notice 'All edit tests passed.';
end;
$$;

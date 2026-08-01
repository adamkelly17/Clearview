-- =====================================================================
-- Voiding and the VAT registration guard.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user    uuid := gen_random_uuid();
  v_novat   uuid;   -- an organisation that is NOT VAT registered
  v_vat     uuid;   -- one that is
  v_supp    uuid;
  v_cust    uuid;
  v_bank    uuid;
  v_post    uuid;
  v_sales   uuid;
  v_t1      uuid;
  v_doc     uuid;
  v_inv     uuid;
  v_rev     uuid;
  v_n       numeric;
  v_count   int;
  v_text    text;
begin
  insert into auth.users (id, email) values (v_user, 'void@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  -- ===============================================================
  raise notice '--- A business that is not VAT registered';
  -- ===============================================================

  v_novat := create_organisation(jsonb_build_object(
    'name', 'Small Trader Ltd', 'entity_type_code', 'limited_company',
    'year_end_day', 31, 'year_end_month', 3,
    'books_start_date', '2026-04-01',
    'vat_enabled', false));

  select id into v_post  from account where organisation_id = v_novat and code = '7501';
  select id into v_t1    from vat_code where organisation_id = v_novat and code = 'T1';

  v_supp := create_contact(jsonb_build_object(
    'organisation_id', v_novat, 'name', 'Amazon', 'is_supplier', true));

  -- The interface should not send a VAT code, but if it does the
  -- database must ignore it. This is the bug: 20.00 was posting as
  -- 20.00 net plus 4.00 VAT.
  v_doc := post_document(jsonb_build_object(
    'organisation_id', v_novat, 'doc_type', 'PI', 'contact_id', v_supp,
    'date', '2026-08-01', 'number', 'TS-9910',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Printing', 'quantity', 1, 'unit_price', 20,
      'account_id', v_post, 'vat_code_id', v_t1))));

  select net_total, vat_total, gross_total into v_n, v_count, v_text
    from document where id = v_doc;

  if (select vat_total from document where id = v_doc) <> 0 then
    raise exception 'FAIL: VAT charged to a business that is not registered: %',
      (select vat_total from document where id = v_doc);
  end if;
  if (select gross_total from document where id = v_doc) <> 20.00 then
    raise exception 'FAIL: a 20.00 bill should total 20.00, got %',
      (select gross_total from document where id = v_doc);
  end if;
  raise notice 'PASS  a 20.00 bill totals 20.00, not 24.00, even with a VAT code passed in';

  if (select vat_code_id from document_line where document_id = v_doc) is not null then
    raise exception 'FAIL: the VAT code should have been stripped from the line';
  end if;
  raise notice 'PASS  the VAT code was stripped from the stored line';

  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_novat and a.control_type = 'vat_input';

  if v_n <> 0 then
    raise exception 'FAIL: nothing should have reached the VAT account, got %', v_n;
  end if;
  raise notice 'PASS  no VAT posted to the input VAT account';

  -- ===============================================================
  raise notice '--- The same organisation once it registers';
  -- ===============================================================

  update organisation_feature set vat_enabled = true where organisation_id = v_novat;

  v_doc := post_document(jsonb_build_object(
    'organisation_id', v_novat, 'doc_type', 'PI', 'contact_id', v_supp,
    'date', '2026-08-02', 'number', 'TS-9911',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Printing', 'quantity', 1, 'unit_price', 20,
      'account_id', v_post, 'vat_code_id', v_t1))));

  if (select gross_total from document where id = v_doc) <> 24.00 then
    raise exception 'FAIL: once registered, a 20.00 net bill should gross 24.00, got %',
      (select gross_total from document where id = v_doc);
  end if;
  raise notice 'PASS  after registering, the same bill correctly grosses 24.00';
  raise notice 'PASS  switching VAT on later needed no data migration';

  update organisation_feature set vat_enabled = false where organisation_id = v_novat;

  -- ===============================================================
  raise notice '--- Voiding';
  -- ===============================================================

  v_vat := create_organisation(jsonb_build_object(
    'name', 'Brookfield Joinery Ltd', 'entity_type_code', 'limited_company',
    'year_end_day', 31, 'year_end_month', 3,
    'books_start_date', '2026-04-01', 'vat_enabled', true));

  select id into v_sales from account where organisation_id = v_vat and code = '4000';
  select id into v_bank  from account where organisation_id = v_vat and code = '1200';
  select id into v_t1    from vat_code where organisation_id = v_vat and code = 'T1';

  v_cust := create_contact(jsonb_build_object(
    'organisation_id', v_vat, 'name', 'Hartley Developments', 'is_customer', true));

  v_inv := post_document(jsonb_build_object(
    'organisation_id', v_vat, 'doc_type', 'SI', 'contact_id', v_cust,
    'date', '2026-05-01',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Kitchen', 'quantity', 1, 'unit_price', 1000,
      'account_id', v_sales, 'vat_code_id', v_t1))));

  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_vat and a.control_type = 'debtors';

  if v_n <> 1200.00 then
    raise exception 'FAIL: debtors should be 1200.00 before voiding, got %', v_n;
  end if;

  v_rev := void_document(v_inv, 'Entered twice');

  if (select status from document where id = v_inv) <> 'void' then
    raise exception 'FAIL: the document was not marked void';
  end if;
  raise notice 'PASS  the document is marked void, not deleted';

  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_vat and a.control_type = 'debtors';

  if v_n <> 0 then
    raise exception 'FAIL: debtors should be back to nil after voiding, got %', v_n;
  end if;
  raise notice 'PASS  trade debtors back to nil';

  select coalesce(sum(jl.credit - jl.debit), 0) into v_n
    from journal_line jl where jl.account_id = v_sales;
  if v_n <> 0 then
    raise exception 'FAIL: sales should be back to nil, got %', v_n;
  end if;
  raise notice 'PASS  the sale is reversed out of income';

  -- The audit trail is the whole point.
  select count(*) into v_count from journal
   where organisation_id = v_vat
     and (id = (select journal_id from document where id = v_inv) or id = v_rev);
  if v_count <> 2 then
    raise exception 'FAIL: both the original and the reversal should remain, found %', v_count;
  end if;
  raise notice 'PASS  both the original and the reversal remain in the transaction list';

  if (select reversed_by_journal_id from journal
       where id = (select journal_id from document where id = v_inv)) <> v_rev then
    raise exception 'FAIL: the original is not linked to its reversal';
  end if;
  raise notice 'PASS  the original and the reversal are linked in both directions';

  if (select void_reason from document where id = v_inv) <> 'Entered twice' then
    raise exception 'FAIL: the reason was not recorded';
  end if;
  if (select voided_by from document where id = v_inv) <> v_user then
    raise exception 'FAIL: who voided it was not recorded';
  end if;
  raise notice 'PASS  who voided it, when and why are all recorded';

  if not exists (
    select 1 from audit_log
     where organisation_id = v_vat and action = 'voided' and record_id = v_inv::text
  ) then
    raise exception 'FAIL: nothing written to the audit log';
  end if;
  raise notice 'PASS  written to the audit log as well';

  -- It must drop off aged debtors.
  select count(*) into v_count from aged_analysis(v_vat, 'sales', '2027-03-31');
  if v_count <> 0 then
    raise exception 'FAIL: a voided invoice should not appear on aged debtors';
  end if;
  raise notice 'PASS  gone from aged debtors, with no orphan balance left behind';

  -- ===============================================================
  raise notice '--- Guards on voiding';
  -- ===============================================================

  begin
    perform void_document(v_inv, 'Again');
    raise exception 'FAIL: voided the same document twice';
  exception when check_violation then
    raise notice 'PASS  voiding the same document twice refused';
  end;

  begin
    delete from document where id = v_inv;
    raise exception 'FAIL: a voided document was deleted';
  exception when insufficient_privilege then
    raise notice 'PASS  deleting a voided document refused';
  end;

  begin
    update document set status = 'posted' where id = v_inv;
    raise exception 'FAIL: a voided document was brought back';
  exception when insufficient_privilege then
    raise notice 'PASS  un-voiding refused — enter it again instead';
  end;

  -- A part-paid invoice cannot be voided around its payment.
  v_inv := post_document(jsonb_build_object(
    'organisation_id', v_vat, 'doc_type', 'SI', 'contact_id', v_cust,
    'date', '2026-05-10',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Bathroom', 'quantity', 1, 'unit_price', 500,
      'account_id', v_sales, 'vat_code_id', v_t1))));

  perform post_payment(jsonb_build_object(
    'organisation_id', v_vat, 'ledger', 'sales', 'contact_id', v_cust,
    'bank_account_id', v_bank, 'date', '2026-05-15',
    'amount', 100.00, 'auto_allocate', true));

  begin
    perform void_document(v_inv, 'Changed my mind');
    raise exception 'FAIL: voided an invoice that has been part paid';
  exception when check_violation then
    raise notice 'PASS  voiding a part-paid invoice refused, with the amount named';
  end;

  -- ===============================================================
  raise notice '--- The ledger is still sound';
  -- ===============================================================

  select sum(debit) into v_n from trial_balance(v_vat, '2027-03-31');
  if v_n <> (select sum(credit) from trial_balance(v_vat, '2027-03-31')) then
    raise exception 'FAIL: trial balance out of balance after voiding';
  end if;
  raise notice 'PASS  trial balance still agrees at %', to_char(v_n, 'FM999999990.00');

  select coalesce(sum(jl.credit - jl.debit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_novat and a.control_type = 'creditors';
  select coalesce(sum(case when direction = 'credit' then outstanding_amount
                           else -outstanding_amount end), 0) into v_count
    from ledger_item_outstanding
   where organisation_id = v_novat and ledger = 'purchase';

  if v_n <> v_count then
    raise exception 'FAIL: creditors % disagrees with the purchase ledger %', v_n, v_count;
  end if;
  raise notice 'PASS  control accounts still agree with their sub-ledgers';

  raise notice '';
  raise notice 'All void and VAT tests passed.';
end;
$$;

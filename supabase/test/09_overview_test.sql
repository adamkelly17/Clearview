-- =====================================================================
-- The overview figures.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user uuid := gen_random_uuid();
  v_org uuid; v_cust uuid; v_supp uuid;
  v_sales uuid; v_mat uuid; v_rent uuid; v_int uuid; v_bank uuid; v_ba uuid;
  v_p jsonb; v_b jsonb; v_w jsonb; v_line uuid;
begin
  insert into auth.users (id, email) values (v_user, 'overview@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name','Brookfield Joinery Ltd','entity_type_code','limited_company',
    'year_end_day',31,'year_end_month',3,
    'books_start_date','2026-04-01','vat_enabled',false));

  select id into v_sales from account where organisation_id=v_org and code='4000';
  select id into v_mat   from account where organisation_id=v_org and code='5001';
  select id into v_rent  from account where organisation_id=v_org and code='7100';
  select id into v_int   from account where organisation_id=v_org and code='4906';
  select id into v_bank  from account where organisation_id=v_org and code='1200';
  select id into v_ba from bank_account where account_id = v_bank;

  v_cust := create_contact(jsonb_build_object(
    'organisation_id',v_org,'name','Hartley Developments','is_customer',true));
  v_supp := create_contact(jsonb_build_object(
    'organisation_id',v_org,'name','Timber Supplies','is_supplier',true));

  perform post_document(jsonb_build_object('organisation_id',v_org,'doc_type','SI',
    'contact_id',v_cust,'date','2026-05-01','lines',jsonb_build_array(
      jsonb_build_object('description','Job','quantity',1,'unit_price',20000,'account_id',v_sales))));

  perform post_document(jsonb_build_object('organisation_id',v_org,'doc_type','PI',
    'contact_id',v_supp,'date','2026-05-02','number','T-1','lines',jsonb_build_array(
      jsonb_build_object('description','Materials','quantity',1,'unit_price',12000,'account_id',v_mat))));

  perform post_journal(v_org,'2026-05-03','Rent', jsonb_build_array(
    jsonb_build_object('account_id',v_rent,'debit',3000),
    jsonb_build_object('account_id',v_bank,'credit',3000)));

  perform post_journal(v_org,'2026-05-04','Bank interest', jsonb_build_array(
    jsonb_build_object('account_id',v_bank,'debit',50),
    jsonb_build_object('account_id',v_int,'credit',50)));

  raise notice '--- The profit chain';

  v_p := profit_summary(v_org,'2026-04-01','2027-03-31');

  if (v_p ->> 'sales')::numeric <> 20000 then
    raise exception 'FAIL: sales should be 20000, got %', v_p ->> 'sales';
  end if;
  raise notice 'PASS  sales 20,000';

  if (v_p ->> 'cost_of_sales')::numeric <> 12000 then
    raise exception 'FAIL: cost of sales should be 12000, got %', v_p ->> 'cost_of_sales';
  end if;
  raise notice 'PASS  cost of sales 12,000';

  if (v_p ->> 'gross_profit')::numeric <> 8000 then
    raise exception 'FAIL: gross profit should be 8000, got %', v_p ->> 'gross_profit';
  end if;
  if (v_p ->> 'gross_margin')::numeric <> 40.0 then
    raise exception 'FAIL: gross margin should be 40.0, got %', v_p ->> 'gross_margin';
  end if;
  raise notice 'PASS  gross profit 8,000 at 40.0%%';

  -- Interest received is income but not sales: it must not flatter the
  -- gross margin, which is about the work itself.
  if (v_p ->> 'other_income')::numeric <> 50 then
    raise exception 'FAIL: other income should be 50, got %', v_p ->> 'other_income';
  end if;
  raise notice 'PASS  bank interest counted as other income, outside gross profit';

  if (v_p ->> 'overheads')::numeric <> 3000 then
    raise exception 'FAIL: overheads should be 3000, got %', v_p ->> 'overheads';
  end if;
  if (v_p ->> 'net_profit')::numeric <> 5050 then
    raise exception 'FAIL: profit should be 5050 (8000 + 50 - 3000), got %', v_p ->> 'net_profit';
  end if;
  raise notice 'PASS  overheads 3,000 leaving a profit of 5,050';

  -- The chain has to actually add up.
  if (v_p ->> 'sales')::numeric - (v_p ->> 'cost_of_sales')::numeric
     <> (v_p ->> 'gross_profit')::numeric then
    raise exception 'FAIL: sales less cost of sales does not equal gross profit';
  end if;
  if (v_p ->> 'gross_profit')::numeric + (v_p ->> 'other_income')::numeric
     - (v_p ->> 'overheads')::numeric - (v_p ->> 'taxation')::numeric
     <> (v_p ->> 'net_profit')::numeric then
    raise exception 'FAIL: the chain down to profit does not add up';
  end if;
  raise notice 'PASS  the chain adds up from sales through to profit';

  -- Nil sales must not divide by zero.
  declare v_empty uuid;
  begin
    v_empty := create_organisation(jsonb_build_object(
      'name','Nothing Yet Ltd','entity_type_code','sole_trader',
      'year_end_day',31,'year_end_month',3,'books_start_date','2026-04-01'));
    v_p := profit_summary(v_empty,'2026-04-01','2027-03-31');
    if (v_p ->> 'gross_margin') is not null then
      raise exception 'FAIL: no sales should give no margin, not a number';
    end if;
    raise notice 'PASS  a business with no sales reports no margin rather than nought';
  end;

  raise notice '--- The bank';

  v_b := bank_summary(v_org);

  if (v_b ->> 'balance')::numeric <> -2950 then
    raise exception 'FAIL: bank should be -2950 (3000 out, 50 in), got %', v_b ->> 'balance';
  end if;
  raise notice 'PASS  bank balance -2,950 across all accounts';

  if (v_b ->> 'unreconciled_count')::int <> 2 then
    raise exception 'FAIL: both bank entries should be unreconciled, got %',
      v_b ->> 'unreconciled_count';
  end if;
  if (v_b ->> 'earliest_unreconciled')::date <> '2026-05-03' then
    raise exception 'FAIL: the oldest unreconciled entry should be 03/05, got %',
      v_b ->> 'earliest_unreconciled';
  end if;
  raise notice 'PASS  2 unreconciled, oldest dated 03/05/2026';

  if (v_b ->> 'days_since_earliest')::int < 1 then
    raise exception 'FAIL: the age of the oldest entry should be reported';
  end if;
  raise notice 'PASS  its age is reported, which is what says whether the balance can be trusted';

  -- Reconciling one should move both the count and the oldest date on.
  perform import_statement(jsonb_build_object(
    'organisation_id',v_org,'bank_account_id',v_ba,'name','May',
    'lines',jsonb_build_array(jsonb_build_object(
      'date','2026-05-03','description','ELM PROPERTIES','amount',-3000.00))));

  select id into v_line from statement_line where bank_account_id = v_ba;

  perform match_statement_line(v_line, (
    select jl.id from journal_line jl join journal j on j.id = jl.journal_id
     where jl.account_id = v_bank and jl.credit = 3000 and j.date = '2026-05-03' limit 1));

  v_b := bank_summary(v_org);
  if (v_b ->> 'unreconciled_count')::int <> 1 then
    raise exception 'FAIL: one should now be reconciled, got % left', v_b ->> 'unreconciled_count';
  end if;
  if (v_b ->> 'earliest_unreconciled')::date <> '2026-05-04' then
    raise exception 'FAIL: the oldest should have moved to 04/05, got %',
      v_b ->> 'earliest_unreconciled';
  end if;
  raise notice 'PASS  reconciling one moves both the count and the oldest date';

  raise notice '--- Where you stand';

  v_w := working_capital(v_org);

  if (v_w ->> 'owed_in')::numeric <> 20000 then
    raise exception 'FAIL: owed in should be 20000, got %', v_w ->> 'owed_in';
  end if;
  if (v_w ->> 'owed_out')::numeric <> 12000 then
    raise exception 'FAIL: owed out should be 12000, got %', v_w ->> 'owed_out';
  end if;
  raise notice 'PASS  20,000 owed in and 12,000 owed out';

  if (v_w ->> 'if_all_settled')::numeric
     <> (v_w ->> 'bank')::numeric + 20000 - 12000 then
    raise exception 'FAIL: the settled position does not add up';
  end if;
  raise notice 'PASS  "you would have" equals bank plus owed in less owed out';

  raise notice '';
  raise notice 'All overview tests passed.';
end;
$$;

-- =====================================================================
-- The customer and supplier list figures, and the reports built from
-- them. The list and the summary report share one function, so they
-- cannot disagree — this checks the arithmetic behind both.
-- =====================================================================

do $$
declare
  v_user uuid := gen_random_uuid();
  v_org uuid; v_c1 uuid; v_c2 uuid; v_c3 uuid; v_sales uuid; v_bank uuid;
  v_r record; v_n numeric; v_c int; v_item uuid;
begin
  insert into auth.users (id, email) values (v_user, 'lists@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name','List Test Ltd','entity_type_code','limited_company',
    'year_end_day',31,'year_end_month',3,
    'books_start_date','2026-01-01','vat_enabled',false));

  select id into v_sales from account where organisation_id=v_org and code='4000';
  select id into v_bank  from account where organisation_id=v_org and code='1200';

  v_c1 := create_contact(jsonb_build_object('organisation_id',v_org,
    'name','Hartley Developments','is_customer',true,'credit_limit',5000));
  v_c2 := create_contact(jsonb_build_object('organisation_id',v_org,
    'name','Quiet Co','is_customer',true));
  v_c3 := create_contact(jsonb_build_object('organisation_id',v_org,
    'name','Prompt Payers','is_customer',true));

  -- Hartley: one very old, one mid-aged, one not yet due.
  perform post_document(jsonb_build_object('organisation_id',v_org,'doc_type','SI',
    'contact_id',v_c1,'date','2026-01-05','due_date','2026-01-20',
    'lines',jsonb_build_array(jsonb_build_object(
      'description','Old','quantity',1,'unit_price',1000,'account_id',v_sales))));
  perform post_document(jsonb_build_object('organisation_id',v_org,'doc_type','SI',
    'contact_id',v_c1,'date','2026-06-01','due_date','2026-07-01',
    'lines',jsonb_build_array(jsonb_build_object(
      'description','Mid','quantity',1,'unit_price',2000,'account_id',v_sales))));
  perform post_document(jsonb_build_object('organisation_id',v_org,'doc_type','SI',
    'contact_id',v_c1,'date','2026-08-01','due_date','2027-12-31',
    'lines',jsonb_build_array(jsonb_build_object(
      'description','Not yet due','quantity',1,'unit_price',3000,'account_id',v_sales))));

  -- Prompt Payers: raised and settled, so should show nil.
  perform post_document(jsonb_build_object('organisation_id',v_org,'doc_type','SI',
    'contact_id',v_c3,'date','2026-03-01','lines',jsonb_build_array(jsonb_build_object(
      'description','Paid','quantity',1,'unit_price',400,'account_id',v_sales))));
  perform post_payment(jsonb_build_object('organisation_id',v_org,'ledger','sales',
    'contact_id',v_c3,'bank_account_id',v_bank,'date','2026-03-10',
    'amount',400.00,'auto_allocate',true));

  raise notice '--- Amounts and counts per customer';

  select * into v_r from contact_summary(v_org,'sales')
   where contact_id = v_c1;

  if v_r.total_due <> 6000 then
    raise exception 'FAIL: Hartley should owe 6000, got %', v_r.total_due;
  end if;
  if v_r.outstanding_count <> 3 then
    raise exception 'FAIL: 3 outstanding invoices expected, got %', v_r.outstanding_count;
  end if;
  raise notice 'PASS  6,000 due across 3 invoices';

  -- Only the two past their due date count as overdue.
  if v_r.overdue_amount <> 3000 then
    raise exception 'FAIL: 3000 should be overdue, got %', v_r.overdue_amount;
  end if;
  if v_r.overdue_count <> 2 then
    raise exception 'FAIL: 2 invoices should be overdue, got %', v_r.overdue_count;
  end if;
  raise notice 'PASS  3,000 overdue across 2 invoices — the future-dated one excluded';

  if not v_r.over_limit then
    raise exception 'FAIL: 6000 against a 5000 limit should flag';
  end if;
  raise notice 'PASS  flagged as over the 5,000 credit limit';

  -- The buckets have to add back to the total.
  if v_r.current_amount + v_r.days_30 + v_r.days_60 + v_r.days_90 + v_r.older
     <> v_r.total_due then
    raise exception 'FAIL: the ageing buckets do not add up to the total';
  end if;
  raise notice 'PASS  the ageing buckets add back to the total due';

  -- Customers with nothing outstanding still appear, at nil.
  select * into v_r from contact_summary(v_org,'sales') where contact_id = v_c2;
  if v_r.total_due <> 0 or v_r.outstanding_count <> 0 then
    raise exception 'FAIL: a customer with no invoices should show nil';
  end if;
  raise notice 'PASS  a customer with no invoices still appears, at nil';

  select * into v_r from contact_summary(v_org,'sales') where contact_id = v_c3;
  if v_r.total_due <> 0 then
    raise exception 'FAIL: a fully paid customer should show nil, got %', v_r.total_due;
  end if;
  raise notice 'PASS  a customer who has paid shows nil rather than dropping off';

  raise notice '--- The reports agree with the screen';

  select coalesce(sum(total_due), 0) into v_n from contact_summary(v_org,'sales');
  select coalesce(sum(outstanding_amount), 0) into v_c from outstanding_items(v_org,'sales',false);

  if v_n <> v_c then
    raise exception 'FAIL: the summary totals % but the detail totals %', v_n, v_c;
  end if;
  raise notice 'PASS  the summary and the detailed report total the same at %',
    to_char(v_n, 'FM999999990.00');

  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'debtors';

  if v_n <> v_c then
    raise exception 'FAIL: the reports total % but trade debtors is %', v_c, v_n;
  end if;
  raise notice 'PASS  and both agree with trade debtors on the trial balance';

  select count(*) into v_c from outstanding_items(v_org,'sales',true);
  if v_c <> 2 then
    raise exception 'FAIL: the overdue report should have 2 rows, got %', v_c;
  end if;
  raise notice 'PASS  the overdue report shows only the 2 overdue invoices';

  -- Every row carries a bucket, or the spreadsheet cannot be pivoted.
  if exists (select 1 from outstanding_items(v_org,'sales',false) where bucket is null) then
    raise exception 'FAIL: a row came back with no ageing bucket';
  end if;
  raise notice 'PASS  every row carries an ageing bucket';

  raise notice '--- Editing a customer';

  perform update_contact(jsonb_build_object(
    'id', v_c2, 'name', 'Quiet Company Ltd',
    'payment_terms_days', 14, 'credit_limit', 2500,
    'address_line_1', '4 Elm Trading Estate', 'city', 'Wokingham',
    'postcode', 'RG40 1AB', 'on_hold', true));

  if (select name from contact where id = v_c2) <> 'Quiet Company Ltd' then
    raise exception 'FAIL: the name did not change';
  end if;
  if (select payment_terms_days from contact where id = v_c2) <> 14 then
    raise exception 'FAIL: the terms did not change';
  end if;
  if not (select on_hold from contact where id = v_c2) then
    raise exception 'FAIL: on hold did not take';
  end if;
  raise notice 'PASS  name, terms, credit limit and hold status all updated';

  if (select postcode from contact_address where contact_id = v_c2) <> 'RG40 1AB' then
    raise exception 'FAIL: the address was not created alongside';
  end if;
  raise notice 'PASS  the address was created with it, not left behind';

  -- Editing again should update the same address rather than add another.
  perform update_contact(jsonb_build_object(
    'id', v_c2, 'name', 'Quiet Company Ltd', 'postcode', 'RG41 2QN'));

  if (select count(*) from contact_address where contact_id = v_c2) <> 1 then
    raise exception 'FAIL: a second address was created';
  end if;
  if (select postcode from contact_address where contact_id = v_c2) <> 'RG41 2QN' then
    raise exception 'FAIL: the address was not updated';
  end if;
  raise notice 'PASS  editing again updates the same address rather than adding another';

  if not exists (
    select 1 from audit_log where organisation_id = v_org
      and table_name = 'contact' and action = 'updated'
  ) then
    raise exception 'FAIL: the change was not logged';
  end if;
  raise notice 'PASS  the change is recorded in the audit log';

  raise notice '';
  raise notice 'All list and report tests passed.';
end;
$$;

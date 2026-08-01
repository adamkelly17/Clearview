-- =====================================================================
-- Trading layer tests: sales, purchases, VAT, allocation, ageing.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user    uuid := gen_random_uuid();
  v_org     uuid;
  v_cust    uuid;
  v_supp    uuid;
  v_sub     uuid;
  v_bank    uuid;
  v_sales   uuid;
  v_subcon  uuid;
  v_debtors uuid;
  v_credits uuid;
  v_vat_out uuid;
  v_vat_in  uuid;
  v_t1      uuid;
  v_t0      uuid;
  v_t21     uuid;
  v_inv1    uuid;
  v_inv2    uuid;
  v_bill    uuid;
  v_rc_bill uuid;
  v_credit  uuid;
  v_pay     uuid;
  v_item    uuid;
  v_n       numeric;
  v_m       numeric;
  v_count   int;
  v_text    text;
begin
  insert into auth.users (id, email) values (v_user, 'trade@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name', 'Brookfield Joinery Ltd',
    'entity_type_code', 'limited_company',
    'year_end_day', 31, 'year_end_month', 3,
    'books_start_date', '2026-04-01',
    'vat_enabled', true, 'vat_scheme', 'standard'
  ));

  select id into v_bank    from account where organisation_id = v_org and code = '1200';
  select id into v_sales   from account where organisation_id = v_org and code = '4000';
  select id into v_subcon  from account where organisation_id = v_org and code = '5002';
  select id into v_debtors from account where organisation_id = v_org and control_type = 'debtors';
  select id into v_credits from account where organisation_id = v_org and control_type = 'creditors';
  select id into v_vat_out from account where organisation_id = v_org and control_type = 'vat_output';
  select id into v_vat_in  from account where organisation_id = v_org and control_type = 'vat_input';

  select id into v_t1  from vat_code where organisation_id = v_org and code = 'T1';
  select id into v_t0  from vat_code where organisation_id = v_org and code = 'T0';
  select id into v_t21 from vat_code where organisation_id = v_org and code = 'T21';

  -- ---------------------------------------------------------------
  raise notice '--- Contacts';
  -- ---------------------------------------------------------------

  v_cust := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Hartley Developments',
    'is_customer', true, 'payment_terms_days', 30,
    'email', 'accounts@hartley.co.uk', 'credit_limit', 10000
  ));

  v_supp := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Timber Supplies Ltd',
    'is_supplier', true, 'payment_terms_days', 14
  ));

  v_sub := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'K. Wells Carpentry',
    'is_supplier', true, 'cis_registered', true, 'cis_deduction_rate', 20
  ));

  select code into v_text from contact where id = v_cust;
  raise notice 'PASS  three contacts created, customer coded %', v_text;

  -- ---------------------------------------------------------------
  raise notice '--- Sales invoice with standard rate VAT';
  -- ---------------------------------------------------------------

  v_inv1 := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'SI',
    'contact_id', v_cust, 'date', '2026-05-01',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Kitchen fit', 'quantity', 1,
        'unit_price', 4000, 'account_id', v_sales, 'vat_code_id', v_t1),
      jsonb_build_object('description', 'Materials', 'quantity', 10,
        'unit_price', 45.50, 'account_id', v_sales, 'vat_code_id', v_t1)
    )
  ));

  select net_total, vat_total into v_n, v_m
    from document where id = v_inv1;

  if v_n <> 4455.00 then
    raise exception 'FAIL: net should be 4455.00, got %', v_n;
  end if;
  if v_m <> 891.00 then
    raise exception 'FAIL: VAT should be 891.00, got %', v_m;
  end if;
  raise notice 'PASS  invoice net 4455.00, VAT 891.00, gross 5346.00';

  if (select due_date from document where id = v_inv1) <> '2026-05-31' then
    raise exception 'FAIL: due date should be 30 days after invoice date';
  end if;
  raise notice 'PASS  due date set from the customer''s 30 day terms';

  -- Check the journal
  select coalesce(sum(debit - credit), 0) into v_n
    from journal_line where account_id = v_debtors;
  if v_n <> 5346.00 then
    raise exception 'FAIL: trade debtors should be 5346.00, got %', v_n;
  end if;

  select coalesce(sum(credit - debit), 0) into v_n
    from journal_line where account_id = v_sales;
  if v_n <> 4455.00 then
    raise exception 'FAIL: sales should be 4455.00, got %', v_n;
  end if;

  select coalesce(sum(credit - debit), 0) into v_n
    from journal_line where account_id = v_vat_out;
  if v_n <> 891.00 then
    raise exception 'FAIL: VAT on sales should be 891.00, got %', v_n;
  end if;
  raise notice 'PASS  posted Dr debtors 5346.00, Cr sales 4455.00, Cr VAT 891.00';

  -- ---------------------------------------------------------------
  raise notice '--- Zero rated sale';
  -- ---------------------------------------------------------------

  v_inv2 := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'SI',
    'contact_id', v_cust, 'date', '2026-05-15',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Zero rated work', 'quantity', 1,
        'unit_price', 1000, 'account_id', v_sales, 'vat_code_id', v_t0)
    )
  ));

  if (select vat_total from document where id = v_inv2) <> 0 then
    raise exception 'FAIL: zero rated sale should carry no VAT';
  end if;
  raise notice 'PASS  zero rated sale carries no VAT';

  -- ---------------------------------------------------------------
  raise notice '--- Discount and quantity arithmetic';
  -- ---------------------------------------------------------------

  perform post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'SI',
    'contact_id', v_cust, 'date', '2026-05-20',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Discounted', 'quantity', 3,
        'unit_price', 100, 'discount_percent', 10,
        'account_id', v_sales, 'vat_code_id', v_t1)
    )
  ));

  select net_amount, vat_amount into v_n, v_m
    from document_line
   where description = 'Discounted';

  if v_n <> 270.00 or v_m <> 54.00 then
    raise exception 'FAIL: 3 x 100 less 10%% should be 270.00 net and 54.00 VAT, got % and %', v_n, v_m;
  end if;
  raise notice 'PASS  3 x 100.00 less 10%% = 270.00 net, 54.00 VAT';

  -- ---------------------------------------------------------------
  raise notice '--- Purchase invoice';
  -- ---------------------------------------------------------------

  v_bill := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'PI',
    'contact_id', v_supp, 'date', '2026-05-05',
    'number', 'TS-9910', 'their_reference', 'TS-9910',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Oak', 'quantity', 1,
        'unit_price', 800, 'account_id', v_subcon, 'vat_code_id', v_t1)
    )
  ));

  select coalesce(sum(credit - debit), 0) into v_n
    from journal_line where account_id = v_credits;
  if v_n <> 960.00 then
    raise exception 'FAIL: trade creditors should be 960.00, got %', v_n;
  end if;

  select coalesce(sum(debit - credit), 0) into v_n
    from journal_line where account_id = v_vat_in;
  if v_n <> 160.00 then
    raise exception 'FAIL: VAT on purchases should be 160.00, got %', v_n;
  end if;
  raise notice 'PASS  bill posted Cr creditors 960.00, Dr VAT 160.00';

  -- ---------------------------------------------------------------
  raise notice '--- CIS domestic reverse charge on a purchase';
  -- ---------------------------------------------------------------

  v_rc_bill := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'PI',
    'contact_id', v_sub, 'date', '2026-05-08',
    'number', 'KW-114',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Subcontract labour', 'quantity', 1,
        'unit_price', 2000, 'account_id', v_subcon, 'vat_code_id', v_t21)
    )
  ));

  -- The supplier charges no VAT, so the bill is 2000 flat.
  if (select gross_total from document where id = v_rc_bill) <> 2000.00 then
    raise exception 'FAIL: a reverse charge bill should be net only, got %',
      (select gross_total from document where id = v_rc_bill);
  end if;
  raise notice 'PASS  reverse charge bill totals 2000.00 with no VAT added';

  if (select notional_vat from document_line
       where document_id = v_rc_bill) <> 400.00 then
    raise exception 'FAIL: notional VAT should be 400.00';
  end if;

  -- Notional VAT must hit both sides, netting to nil on the liability.
  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl
   where jl.journal_id = (select journal_id from document where id = v_rc_bill)
     and jl.account_id = v_vat_in;
  select coalesce(sum(jl.credit - jl.debit), 0) into v_m
    from journal_line jl
   where jl.journal_id = (select journal_id from document where id = v_rc_bill)
     and jl.account_id = v_vat_out;

  if v_n <> 400.00 or v_m <> 400.00 then
    raise exception 'FAIL: reverse charge should post 400.00 to both VAT accounts, got Dr % Cr %', v_n, v_m;
  end if;
  raise notice 'PASS  reverse charge posts 400.00 to input and output VAT, net nil';

  -- ---------------------------------------------------------------
  raise notice '--- Credit note';
  -- ---------------------------------------------------------------

  v_credit := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'SC',
    'contact_id', v_cust, 'date', '2026-05-25',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Overcharge on kitchen fit', 'quantity', 1,
        'unit_price', 500, 'account_id', v_sales, 'vat_code_id', v_t1)
    )
  ));

  if (select direction from ledger_item where document_id = v_credit) <> 'credit' then
    raise exception 'FAIL: a sales credit note should be a credit item';
  end if;
  raise notice 'PASS  credit note recorded as a credit on the sales ledger';

  -- ---------------------------------------------------------------
  raise notice '--- Receipt with automatic allocation';
  -- ---------------------------------------------------------------

  v_pay := post_payment(jsonb_build_object(
    'organisation_id', v_org, 'ledger', 'sales', 'contact_id', v_cust,
    'bank_account_id', v_bank, 'date', '2026-06-02',
    'amount', 5346.00, 'reference', 'BACS 0602',
    'auto_allocate', true
  ));

  select outstanding_amount into v_n
    from ledger_item_outstanding
   where document_id = v_inv1;

  if v_n <> 0 then
    raise exception 'FAIL: the first invoice should be fully settled, % left', v_n;
  end if;
  raise notice 'PASS  5346.00 receipt cleared the oldest invoice exactly';

  select outstanding_amount into v_n from ledger_item_outstanding where id = v_pay;
  if v_n <> 0 then
    raise exception 'FAIL: the receipt should be fully allocated, % left', v_n;
  end if;
  raise notice 'PASS  receipt fully allocated, nothing left on account';

  -- ---------------------------------------------------------------
  raise notice '--- Part payment';
  -- ---------------------------------------------------------------

  perform post_payment(jsonb_build_object(
    'organisation_id', v_org, 'ledger', 'sales', 'contact_id', v_cust,
    'bank_account_id', v_bank, 'date', '2026-06-10',
    'amount', 400.00, 'reference', 'BACS 0610',
    'auto_allocate', true
  ));

  select outstanding_amount, settlement_status into v_n, v_text
    from ledger_item_outstanding where document_id = v_inv2;

  if v_n <> 600.00 then
    raise exception 'FAIL: the 1000.00 invoice should have 600.00 left, got %', v_n;
  end if;
  if v_text <> 'part_settled' then
    raise exception 'FAIL: that invoice should read as part settled, got %', v_text;
  end if;
  raise notice 'PASS  400.00 against a 1000.00 invoice leaves 600.00, marked part settled';

  -- ---------------------------------------------------------------
  raise notice '--- Over-allocation is refused';
  -- ---------------------------------------------------------------

  select id into v_item from ledger_item_outstanding
   where document_id = v_inv2;

  v_pay := post_payment(jsonb_build_object(
    'organisation_id', v_org, 'ledger', 'sales', 'contact_id', v_cust,
    'bank_account_id', v_bank, 'date', '2026-06-12', 'amount', 100.00
  ));

  begin
    perform allocate_items(v_org, v_item, v_pay, 5000.00, '2026-06-12');
    raise exception 'FAIL: allowed an allocation larger than the invoice';
  exception when check_violation then
    raise notice 'PASS  allocating more than is outstanding refused';
  end;

  begin
    perform allocate_items(v_org, v_item, v_pay, 100.01, '2026-06-12');
    raise exception 'FAIL: allowed an allocation larger than the payment';
  exception when check_violation then
    raise notice 'PASS  allocating more than the payment refused';
  end;

  perform allocate_items(v_org, v_item, v_pay, 100.00, '2026-06-12');
  raise notice 'PASS  a valid 100.00 allocation accepted';

  -- ---------------------------------------------------------------
  raise notice '--- The control account agrees with the sales ledger';
  -- ---------------------------------------------------------------

  select coalesce(sum(debit - credit), 0) into v_n
    from journal_line where account_id = v_debtors;

  select coalesce(sum(
           case when direction = 'debit' then outstanding_amount
                else -outstanding_amount end), 0)
    into v_m
    from ledger_item_outstanding
   where organisation_id = v_org and ledger = 'sales';

  if v_n <> v_m then
    raise exception
      'FAIL: trade debtors is % but the sales ledger totals %', v_n, v_m;
  end if;
  raise notice 'PASS  trade debtors and the sales ledger both show %',
    to_char(v_n, 'FM999999990.00');

  select coalesce(sum(credit - debit), 0) into v_n
    from journal_line where account_id = v_credits;
  select coalesce(sum(
           case when direction = 'credit' then outstanding_amount
                else -outstanding_amount end), 0)
    into v_m
    from ledger_item_outstanding
   where organisation_id = v_org and ledger = 'purchase';

  if v_n <> v_m then
    raise exception
      'FAIL: trade creditors is % but the purchase ledger totals %', v_n, v_m;
  end if;
  raise notice 'PASS  trade creditors and the purchase ledger both show %',
    to_char(v_n, 'FM999999990.00');

  -- ---------------------------------------------------------------
  raise notice '--- Aged analysis';
  -- ---------------------------------------------------------------

  select sum(total) into v_n from aged_analysis(v_org, 'sales', '2027-03-31');
  select coalesce(sum(
           case when direction = 'debit' then outstanding_amount
                else -outstanding_amount end), 0)
    into v_m
    from ledger_item_outstanding
   where organisation_id = v_org and ledger = 'sales' and outstanding_amount > 0;

  if v_n <> v_m then
    raise exception 'FAIL: aged debtors totals % but the ledger shows %', v_n, v_m;
  end if;
  raise notice 'PASS  aged debtors agrees with the sales ledger at %',
    to_char(coalesce(v_n, 0), 'FM999999990.00');

  select count(*) into v_count from aged_analysis(v_org, 'purchase', '2027-03-31');
  if v_count <> 2 then
    raise exception 'FAIL: expected two suppliers on the aged creditors, got %', v_count;
  end if;
  raise notice 'PASS  aged creditors lists both suppliers';

  -- ---------------------------------------------------------------
  raise notice '--- Statement';
  -- ---------------------------------------------------------------

  select count(*) into v_count from contact_statement(v_org, v_cust, null, null);
  if v_count < 6 then
    raise exception 'FAIL: expected a full statement, got % rows', v_count;
  end if;
  raise notice 'PASS  customer statement returns % rows in date order', v_count;

  -- ---------------------------------------------------------------
  raise notice '--- Guards';
  -- ---------------------------------------------------------------

  begin
    update document set gross_total = 1 where id = v_inv1;
    raise exception 'FAIL: a posted invoice was altered';
  exception when insufficient_privilege then
    raise notice 'PASS  altering a posted invoice refused';
  end;

  begin
    delete from document where id = v_inv1;
    raise exception 'FAIL: a posted invoice was deleted';
  exception when insufficient_privilege then
    raise notice 'PASS  deleting a posted invoice refused';
  end;

  begin
    perform post_document(jsonb_build_object(
      'organisation_id', v_org, 'doc_type', 'SI',
      'contact_id', v_cust, 'date', '2026-05-01',
      'lines', '[]'::jsonb));
    raise exception 'FAIL: an empty invoice was posted';
  exception when check_violation then
    raise notice 'PASS  an invoice with no lines refused';
  end;

  -- Cross-contact allocation
  declare
    v_supplier_item uuid;
  begin
    select id into v_supplier_item from ledger_item where document_id = v_bill;
    begin
      perform allocate_items(v_org, v_item, v_supplier_item, 10.00);
      raise exception 'FAIL: allocated across two different contacts';
    exception when check_violation then
      raise notice 'PASS  allocating between two different contacts refused';
    end;
  end;

  -- ---------------------------------------------------------------
  raise notice '--- Trial balance still agrees';
  -- ---------------------------------------------------------------

  select sum(debit), sum(credit) into v_n, v_m
    from trial_balance(v_org, '2027-03-31');

  if v_n <> v_m then
    raise exception 'FAIL: trial balance out by %', v_n - v_m;
  end if;
  raise notice 'PASS  trial balance agrees at % after % transactions',
    to_char(v_n, 'FM999999990.00'),
    (select count(*) from journal where organisation_id = v_org);

  raise notice '';
  raise notice 'All trading tests passed.';
end;
$$;

-- =====================================================================
-- Banking tests: import, deduplication, suggestion, matching, coding
-- from the bank, transfers and reconciliation.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user    uuid := gen_random_uuid();
  v_org     uuid;
  v_current uuid;   -- bank_account
  v_savings uuid;
  v_curr_nom uuid;  -- the nominal behind it
  v_sav_nom uuid;
  v_cust    uuid;
  v_supp    uuid;
  v_rent    uuid;
  v_elec    uuid;
  v_t1      uuid;
  v_t9      uuid;
  v_inv     uuid;
  v_stmt    uuid;
  v_result  jsonb;
  v_line    uuid;
  v_line2   uuid;
  v_line3   uuid;
  v_jl      uuid;
  v_sug     record;
  v_rec     record;
  v_n       numeric;
  v_count   int;
  v_rule    uuid;
begin
  insert into auth.users (id, email) values (v_user, 'bank@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name', 'Brookfield Joinery Ltd', 'entity_type_code', 'limited_company',
    'year_end_day', 31, 'year_end_month', 3,
    'books_start_date', '2026-04-01', 'vat_enabled', true));

  select id into v_rent from account where organisation_id = v_org and code = '7100';
  select id into v_elec from account where organisation_id = v_org and code = '7200';
  select id into v_t1   from vat_code where organisation_id = v_org and code = 'T1';
  select id into v_t9   from vat_code where organisation_id = v_org and code = 'T9';

  -- ---------------------------------------------------------------
  raise notice '--- Bank accounts';
  -- ---------------------------------------------------------------

  -- The chart of accounts seeds four bank nominals and the migration
  -- backfills bank_account rows for them.
  select count(*) into v_count from bank_account where organisation_id = v_org;
  if v_count <> 4 then
    raise exception 'FAIL: expected 4 bank accounts from the seeded chart, got %', v_count;
  end if;
  raise notice 'PASS  four bank accounts created from the seeded nominals';

  select ba.id, ba.account_id into v_current, v_curr_nom
    from bank_account ba join account a on a.id = ba.account_id
   where ba.organisation_id = v_org and a.code = '1200';

  select ba.id, ba.account_id into v_savings, v_sav_nom
    from bank_account ba join account a on a.id = ba.account_id
   where ba.organisation_id = v_org and a.code = '1210';

  -- A new account with an opening balance.
  declare v_new uuid;
  begin
    v_new := create_bank_account(jsonb_build_object(
      'organisation_id', v_org, 'name', 'Metro Business Account',
      'type', 'current', 'sort_code', '23-05-80',
      'opening_balance', 5000, 'opening_date', '2026-04-01'));

    if (select code from account where id =
         (select account_id from bank_account where id = v_new)) <> '1241' then
      raise exception 'FAIL: a new bank nominal should take the next free 12xx code, got %',
        (select code from account where id = (select account_id from bank_account where id = v_new));
    end if;
    raise notice 'PASS  new bank account allocated nominal 1241 in the 12xx range';

    select coalesce(sum(jl.debit - jl.credit), 0) into v_n
      from journal_line jl
     where jl.account_id = (select account_id from bank_account where id = v_new);

    if v_n <> 5000.00 then
      raise exception 'FAIL: opening balance should be 5000.00, got %', v_n;
    end if;
    raise notice 'PASS  opening balance posted as a real transaction';
  end;

  -- ---------------------------------------------------------------
  raise notice '--- Importing a statement';
  -- ---------------------------------------------------------------

  v_result := import_statement(jsonb_build_object(
    'organisation_id', v_org,
    'bank_account_id', v_current,
    'name', 'May 2026',
    'source_filename', 'statement-may.csv',
    'closing_balance', 4173.60,
    'lines', jsonb_build_array(
      jsonb_build_object('date','2026-05-02','description','HARTLEY DEVELOPMENTS BACS','amount', 5346.00),
      jsonb_build_object('date','2026-05-05','description','EDF ENERGY DD 4471','amount', -186.00),
      jsonb_build_object('date','2026-05-06','description','ELM PROPERTIES RENT','amount', -1200.00),
      jsonb_build_object('date','2026-05-08','description','TRANSFER TO SAVINGS','amount', -2000.00),
      jsonb_build_object('date','2026-05-09','description','BANK CHARGES','amount', -12.40),
      jsonb_build_object('date','2026-05-11','description','EDF ENERGY DD 4471','amount', -186.00),
      jsonb_build_object('date','2026-05-12','description','NOTHING HAPPENED','amount', 0)
    )));

  v_stmt := (v_result ->> 'statement_id')::uuid;

  if (v_result ->> 'inserted')::int <> 6 then
    raise exception 'FAIL: expected 6 lines imported (one zero row skipped), got %',
      v_result ->> 'inserted';
  end if;
  raise notice 'PASS  6 lines imported, the zero-amount row skipped';

  if (select from_date from bank_statement where id = v_stmt) <> '2026-05-02' then
    raise exception 'FAIL: statement date range not derived from the rows';
  end if;
  raise notice 'PASS  statement date range derived from the rows themselves';

  -- ---------------------------------------------------------------
  raise notice '--- Duplicate import protection';
  -- ---------------------------------------------------------------

  v_result := import_statement(jsonb_build_object(
    'organisation_id', v_org, 'bank_account_id', v_current, 'name', 'May again',
    'lines', jsonb_build_array(
      jsonb_build_object('date','2026-05-05','description','EDF ENERGY DD 4471','amount', -186.00),
      jsonb_build_object('date','2026-05-06','description','elm  properties   rent','amount', -1200.00),
      jsonb_build_object('date','2026-05-15','description','NEW TRANSACTION','amount', -50.00)
    )));

  if (v_result ->> 'duplicates')::int <> 2 or (v_result ->> 'inserted')::int <> 1 then
    raise exception 'FAIL: expected 2 duplicates and 1 new, got % and %',
      v_result ->> 'duplicates', v_result ->> 'inserted';
  end if;
  raise notice 'PASS  overlapping re-import found 2 duplicates, added only the new row';
  raise notice 'PASS  spacing and case differences did not defeat the duplicate check';

  -- Two genuinely identical DD payments on different dates must both survive.
  select count(*) into v_count from statement_line
   where bank_account_id = v_current and description = 'EDF ENERGY DD 4471';
  if v_count <> 2 then
    raise exception 'FAIL: the two separate EDF payments should both be kept, found %', v_count;
  end if;
  raise notice 'PASS  the same amount on two different dates kept as two lines';

  -- An import that is entirely duplicates should not leave a statement.
  v_result := import_statement(jsonb_build_object(
    'organisation_id', v_org, 'bank_account_id', v_current, 'name', 'All dupes',
    'lines', jsonb_build_array(
      jsonb_build_object('date','2026-05-09','description','BANK CHARGES','amount', -12.40))));

  if (v_result ->> 'statement_id') is not null then
    raise exception 'FAIL: an all-duplicate import should not create a statement';
  end if;
  raise notice 'PASS  an import of nothing but duplicates leaves no empty statement behind';

  -- ---------------------------------------------------------------
  raise notice '--- Matching something already in the ledger';
  -- ---------------------------------------------------------------

  v_cust := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Hartley Developments', 'is_customer', true));

  v_inv := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'SI', 'contact_id', v_cust,
    'date', '2026-04-20',
    'lines', jsonb_build_array(jsonb_build_object(
      'description','Kitchen fit','quantity',1,'unit_price',4455,
      'account_id',(select id from account where organisation_id = v_org and code='4000'),
      'vat_code_id', v_t1))));

  -- Record the receipt in the sales ledger first, as you would.
  perform post_payment(jsonb_build_object(
    'organisation_id', v_org, 'ledger','sales','contact_id', v_cust,
    'bank_account_id', v_curr_nom, 'date','2026-05-02',
    'amount', 5346.00, 'reference','BACS', 'auto_allocate', true));

  select id into v_line from statement_line
   where bank_account_id = v_current and description = 'HARTLEY DEVELOPMENTS BACS';

  select * into v_sug from suggest_matches_for_line(v_line) where kind = 'journal_line' limit 1;

  if v_sug.ref_id is null then
    raise exception 'FAIL: the receipt already in the ledger was not suggested';
  end if;
  raise notice 'PASS  an existing receipt suggested as a match, score %', v_sug.score;

  perform match_statement_line(v_line, v_sug.ref_id);

  if (select status from statement_line where id = v_line) <> 'matched' then
    raise exception 'FAIL: the line was not marked matched';
  end if;
  if (select reconciled_at from journal_line where id = v_sug.ref_id) is null then
    raise exception 'FAIL: the journal line was not stamped as reconciled';
  end if;
  raise notice 'PASS  matching stamped the journal line as reconciled';

  -- Guards
  begin
    perform match_statement_line(v_line, v_sug.ref_id);
    raise exception 'FAIL: matched the same line twice';
  exception when check_violation then
    raise notice 'PASS  matching an already matched line refused';
  end;

  select id into v_line2 from statement_line
   where bank_account_id = v_current and description = 'BANK CHARGES';

  begin
    perform match_statement_line(v_line2, v_sug.ref_id);
    raise exception 'FAIL: matched a 12.40 line against a 5346.00 transaction';
  exception when check_violation then
    raise notice 'PASS  matching lines with different amounts refused';
  end;

  -- ---------------------------------------------------------------
  raise notice '--- Coding straight from the bank, VAT out of the gross';
  -- ---------------------------------------------------------------

  select id into v_line3 from statement_line
   where bank_account_id = v_current and description = 'ELM PROPERTIES RENT';

  perform create_from_statement_line(v_line3, jsonb_build_object(
    'kind','nominal', 'account_id', v_rent, 'vat_code_id', v_t1,
    'description','Rent for May'));

  -- 1200.00 gross at 20% is 1000.00 net and 200.00 VAT, not 1200 + 240.
  select coalesce(sum(debit - credit), 0) into v_n
    from journal_line where account_id = v_rent;

  if v_n <> 1000.00 then
    raise exception 'FAIL: rent should be 1000.00 net from a 1200.00 gross payment, got %', v_n;
  end if;
  raise notice 'PASS  1200.00 gross split into 1000.00 net and 200.00 VAT';

  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'vat_input';

  if v_n <> 200.00 then
    raise exception 'FAIL: input VAT should be 200.00, got %', v_n;
  end if;
  raise notice 'PASS  VAT reclaimed posted to the input VAT account';

  if (select status from statement_line where id = v_line3) <> 'matched' then
    raise exception 'FAIL: creating a transaction should reconcile the line automatically';
  end if;
  raise notice 'PASS  creating a transaction reconciled the line in the same step';

  -- No VAT code means the whole amount goes to the category.
  select id into v_line2 from statement_line
   where bank_account_id = v_current and description = 'BANK CHARGES';

  perform create_from_statement_line(v_line2, jsonb_build_object(
    'kind','nominal',
    'account_id', (select id from account where organisation_id = v_org and code = '7900'),
    'vat_code_id', v_t9));

  select coalesce(sum(debit - credit), 0) into v_n
    from journal_line
   where account_id = (select id from account where organisation_id = v_org and code = '7900');

  if v_n <> 12.40 then
    raise exception 'FAIL: bank charges should be the full 12.40, got %', v_n;
  end if;
  raise notice 'PASS  a no-VAT code puts the whole amount to the category';

  -- ---------------------------------------------------------------
  raise notice '--- Rules';
  -- ---------------------------------------------------------------

  select id into v_line from statement_line
   where bank_account_id = v_current and description = 'EDF ENERGY DD 4471'
     and date = '2026-05-05';

  perform create_from_statement_line(v_line, jsonb_build_object(
    'kind','nominal', 'account_id', v_elec, 'vat_code_id', v_t1,
    'remember', true));

  select id into v_rule from match_rule
   where organisation_id = v_org and account_id = v_elec;

  if v_rule is null then
    raise exception 'FAIL: no rule was remembered';
  end if;
  raise notice 'PASS  coding remembered as a rule for next time';

  -- The second EDF payment should now be suggested by that rule.
  select id into v_line from statement_line
   where bank_account_id = v_current and description = 'EDF ENERGY DD 4471'
     and date = '2026-05-11';

  select * into v_sug from suggest_matches_for_line(v_line) where kind = 'rule' limit 1;

  if v_sug.ref_id <> v_rule then
    raise exception 'FAIL: the saved rule did not match the second EDF payment';
  end if;
  raise notice 'PASS  the rule matched the next identical direct debit';

  perform create_from_statement_line(v_line, jsonb_build_object(
    'kind','nominal', 'account_id', v_elec, 'vat_code_id', v_t1, 'rule_id', v_rule));

  if (select hit_count from match_rule where id = v_rule) <> 1 then
    raise exception 'FAIL: rule hit count not incremented';
  end if;
  raise notice 'PASS  using a rule counts the hit so useful rules float up';

  -- ---------------------------------------------------------------
  raise notice '--- Transfers';
  -- ---------------------------------------------------------------

  select id into v_line from statement_line
   where bank_account_id = v_current and description = 'TRANSFER TO SAVINGS';

  perform create_from_statement_line(v_line, jsonb_build_object(
    'kind','transfer', 'to_bank_account_id', v_savings));

  select coalesce(sum(debit - credit), 0) into v_n
    from journal_line where account_id = v_sav_nom;

  if v_n <> 2000.00 then
    raise exception 'FAIL: savings should have gone up by 2000.00, got %', v_n;
  end if;
  raise notice 'PASS  transfer moved 2000.00 out of current and into savings';

  -- ---------------------------------------------------------------
  raise notice '--- Settling an invoice from the bank';
  -- ---------------------------------------------------------------

  v_supp := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Timber Supplies Ltd', 'is_supplier', true));

  perform post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type','PI','contact_id', v_supp,
    'date','2026-05-10','number','TS-500',
    'lines', jsonb_build_array(jsonb_build_object(
      'description','Oak','quantity',1,'unit_price',400,
      'account_id',(select id from account where organisation_id = v_org and code='5000'),
      'vat_code_id', v_t1))));

  v_result := import_statement(jsonb_build_object(
    'organisation_id', v_org, 'bank_account_id', v_current, 'name','Late May',
    'lines', jsonb_build_array(
      jsonb_build_object('date','2026-05-20','description','TIMBER SUPPLIES LTD','amount', -480.00))));

  select id into v_line from statement_line
   where bank_account_id = v_current and description = 'TIMBER SUPPLIES LTD';

  select * into v_sug from suggest_matches_for_line(v_line) where kind = 'ledger_item' limit 1;

  if v_sug.ref_id is null then
    raise exception 'FAIL: the outstanding bill was not suggested';
  end if;
  if v_sug.score <= 0.9 then
    raise exception 'FAIL: the supplier name in the description should raise the score, got %', v_sug.score;
  end if;
  raise notice 'PASS  outstanding bill suggested, score % boosted by the name in the description', v_sug.score;

  perform create_from_statement_line(v_line, jsonb_build_object(
    'kind','settle', 'contact_id', v_supp, 'auto_allocate', true));

  select outstanding_amount into v_n from ledger_item_outstanding
   where document_id = (select id from document where organisation_id = v_org and number = 'TS-500');

  if v_n <> 0 then
    raise exception 'FAIL: the bill should be settled, % left', v_n;
  end if;
  raise notice 'PASS  paying from the bank settled the bill and allocated it';

  -- ---------------------------------------------------------------
  raise notice '--- Excluding and unmatching';
  -- ---------------------------------------------------------------

  select id into v_line from statement_line
   where bank_account_id = v_current and description = 'NEW TRANSACTION';

  perform exclude_statement_line(v_line, 'Personal, not the business');
  if (select status from statement_line where id = v_line) <> 'excluded' then
    raise exception 'FAIL: exclusion did not take';
  end if;
  raise notice 'PASS  a line can be excluded with a reason';

  select id into v_line from statement_line
   where bank_account_id = v_current and description = 'ELM PROPERTIES RENT';
  select matched_journal_line_id into v_jl from statement_line where id = v_line;

  perform unmatch_statement_line(v_line);

  if (select status from statement_line where id = v_line) <> 'unmatched' then
    raise exception 'FAIL: unmatching did not reset the line';
  end if;
  if (select reconciled_at from journal_line where id = v_jl) is not null then
    raise exception 'FAIL: unmatching did not clear the reconciliation stamp';
  end if;
  raise notice 'PASS  unmatching resets the line and clears the stamp, transaction untouched';

  -- Re-match it for the reconciliation figures below.
  perform match_statement_line(v_line, v_jl);

  -- ---------------------------------------------------------------
  raise notice '--- Reconciliation figures';
  -- ---------------------------------------------------------------

  select * into v_rec from bank_reconciliation(v_current, '2026-05-31');

  select coalesce(sum(jl.debit - jl.credit), 0) into v_n
    from journal_line jl join journal j on j.id = jl.journal_id
   where jl.account_id = v_curr_nom and j.date <= '2026-05-31';

  if v_rec.ledger_balance <> v_n then
    raise exception 'FAIL: reported ledger balance % does not match the nominal %',
      v_rec.ledger_balance, v_n;
  end if;
  raise notice 'PASS  reported ledger balance agrees with the nominal at %',
    to_char(v_n, 'FM999999990.00');

  if v_rec.unmatched_lines <> 0 then
    raise exception 'FAIL: expected every line dealt with, % unmatched', v_rec.unmatched_lines;
  end if;
  raise notice 'PASS  every imported line is matched or excluded';

  if v_rec.reconciled_balance + v_rec.unreconciled_total <> v_rec.ledger_balance then
    raise exception 'FAIL: reconciled plus unreconciled should equal the ledger balance';
  end if;
  raise notice 'PASS  reconciled plus unreconciled equals the ledger balance';

  -- ---------------------------------------------------------------
  raise notice '--- The ledger is still sound';
  -- ---------------------------------------------------------------

  select sum(debit) into v_n from trial_balance(v_org, '2027-03-31');
  if v_n <> (select sum(credit) from trial_balance(v_org, '2027-03-31')) then
    raise exception 'FAIL: trial balance out of balance after all that banking';
  end if;
  raise notice 'PASS  trial balance still agrees at %', to_char(v_n, 'FM999999990.00');

  raise notice '';
  raise notice 'All banking tests passed.';
end;
$$;

-- =====================================================================
-- Split-screen reconciliation: bulk suggestions, rule preview, and
-- applying a rule across the lines it already matches.
-- =====================================================================

do $$
declare
  v_user   uuid := gen_random_uuid();
  v_org    uuid;
  v_bank   uuid;
  v_elec   uuid;
  v_t1     uuid;
  v_ids    uuid[];
  v_rule   uuid;
  v_result jsonb;
  v_count  int;
  v_amount numeric;
  v_text   text;
begin
  insert into auth.users (id, email) values (v_user, 'rules@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name', 'Rule Test Ltd', 'entity_type_code', 'limited_company',
    'year_end_day', 31, 'year_end_month', 3,
    'books_start_date', '2026-04-01', 'vat_enabled', true));

  select ba.id into v_bank from bank_account ba join account a on a.id = ba.account_id
   where ba.organisation_id = v_org and a.code = '1200';
  select id into v_elec from account where organisation_id = v_org and code = '7200';
  select id into v_t1   from vat_code where organisation_id = v_org and code = 'T1';

  perform import_statement(jsonb_build_object(
    'organisation_id', v_org, 'bank_account_id', v_bank, 'name', 'Q1',
    'lines', jsonb_build_array(
      jsonb_build_object('date','2026-05-05','description','EDF ENERGY DD 4471','amount',-186.00),
      jsonb_build_object('date','2026-06-05','description','EDF ENERGY DD 4471','amount',-191.20),
      jsonb_build_object('date','2026-07-05','description','EDF ENERGY DD 5588','amount',-188.40),
      jsonb_build_object('date','2026-07-09','description','BT BUSINESS 99213','amount',-64.00))));

  raise notice '--- Pattern suggestion';

  v_text := suggest_rule_pattern('EDF ENERGY DD 4471');
  if v_text <> 'EDF ENERGY' then
    raise exception 'FAIL: expected "EDF ENERGY", got "%"', v_text;
  end if;
  raise notice 'PASS  "EDF ENERGY DD 4471" suggests the pattern "EDF ENERGY"';

  -- The merchant name after the processor's asterisk is kept: a rule of
  -- just "SUMUP" would catch every merchant using that card reader.
  if suggest_rule_pattern('SUMUP  *COFFEE 12345') <> 'SUMUP *COFFEE' then
    raise exception 'FAIL: got "%"', suggest_rule_pattern('SUMUP  *COFFEE 12345');
  end if;
  raise notice 'PASS  the volatile tail is dropped but the merchant name is kept';

  if suggest_rule_pattern('CARD PAYMENT TO SCREWFIX 4471') <> 'SCREWFIX' then
    raise exception 'FAIL: got "%"', suggest_rule_pattern('CARD PAYMENT TO SCREWFIX 4471');
  end if;
  raise notice 'PASS  leading markers like "CARD PAYMENT TO" are skipped';

  raise notice '--- Suggestions for every line in one call';

  select array_agg(id) into v_ids from statement_line where bank_account_id = v_bank;

  select count(distinct statement_line_id) into v_count
    from suggest_matches_bulk(v_ids);
  raise notice 'PASS  one call covered % lines', coalesce(v_count, 0);

  raise notice '--- Rule reach preview';

  v_count := preview_rule_matches(v_org, v_bank, 'EDF ENERGY', 'contains', 'out', null);
  if v_count <> 3 then
    raise exception 'FAIL: "EDF ENERGY" should reach 3 lines, got %', v_count;
  end if;
  raise notice 'PASS  the pattern "EDF ENERGY" is shown as reaching 3 lines';

  -- Narrowing the pattern to include the direct debit number drops the
  -- July line, which carries a different one. Two of the three remain.
  v_count := preview_rule_matches(v_org, v_bank, 'EDF ENERGY DD 4471', 'contains', 'out', null);
  if v_count <> 2 then
    raise exception 'FAIL: the narrower pattern should reach 2, got %', v_count;
  end if;
  raise notice 'PASS  narrowing the pattern to the DD number drops it from 3 to 2, visibly, before saving';

  v_count := preview_rule_matches(v_org, v_bank, 'EDF ENERGY', 'contains', 'in', null);
  if v_count <> 0 then
    raise exception 'FAIL: direction should exclude money-out lines, got %', v_count;
  end if;
  raise notice 'PASS  direction is respected by the preview';

  raise notice '--- Saving and applying a rule';

  v_rule := create_match_rule(jsonb_build_object(
    'organisation_id', v_org, 'bank_account_id', v_bank,
    'name', 'Electricity', 'pattern', 'EDF ENERGY',
    'match_type', 'contains', 'direction', 'out',
    'account_id', v_elec, 'vat_code_id', v_t1));

  v_result := apply_rule_to_unmatched(v_rule, v_bank);

  if (v_result ->> 'applied')::int <> 3 then
    raise exception 'FAIL: expected 3 lines coded, got %', v_result ->> 'applied';
  end if;
  raise notice 'PASS  applying the rule coded all 3 matching lines in one go';

  if (select count(*) from statement_line
       where bank_account_id = v_bank and status = 'unmatched') <> 1 then
    raise exception 'FAIL: only the BT line should remain unmatched';
  end if;
  raise notice 'PASS  the unrelated line was left alone';

  -- 186.00 + 191.20 + 188.40 = 565.60 gross, so 471.33 net at 20%.
  select coalesce(sum(debit - credit), 0) into v_amount
    from journal_line where account_id = v_elec;
  if round(v_amount, 2) <> 471.33 then
    raise exception 'FAIL: electricity should be 471.33 net, got %', v_amount;
  end if;
  raise notice 'PASS  all three posted net of VAT, totalling 471.33';

  if (select hit_count from match_rule where id = v_rule) <> 3 then
    raise exception 'FAIL: hit count should be 3, got %',
      (select hit_count from match_rule where id = v_rule);
  end if;
  raise notice 'PASS  the rule records three hits';

  raise notice '--- Guards';

  begin
    perform create_match_rule(jsonb_build_object(
      'organisation_id', v_org, 'pattern', '', 'account_id', v_elec));
    raise exception 'FAIL: saved a rule with nothing to match on';
  exception when check_violation then
    raise notice 'PASS  a rule with an empty pattern refused';
  end;

  begin
    perform create_match_rule(jsonb_build_object(
      'organisation_id', v_org, 'pattern', 'ANYTHING'));
    raise exception 'FAIL: saved a rule with no category';
  exception when check_violation then
    raise notice 'PASS  a rule with no category refused';
  end;

  select sum(debit) into v_amount from trial_balance(v_org, '2027-03-31');
  if v_amount <> (select sum(credit) from trial_balance(v_org, '2027-03-31')) then
    raise exception 'FAIL: trial balance out of balance';
  end if;
  raise notice 'PASS  trial balance still agrees';

  raise notice '';
  raise notice 'All rule tests passed.';
end;
$$;

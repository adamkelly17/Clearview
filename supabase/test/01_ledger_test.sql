-- =====================================================================
-- Ledger behaviour tests.
--
-- Each test either prints PASS or raises. Run after the migrations
-- against a scratch database.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user   uuid := gen_random_uuid();
  v_org    uuid;
  v_bank   uuid;
  v_sales  uuid;
  v_rent   uuid;
  v_debtor uuid;
  v_j1     uuid;
  v_j2     uuid;
  v_rev    uuid;
  v_err    text;
  v_count  int;
  v_debit  numeric;
  v_credit numeric;
begin
  insert into auth.users (id, email) values (v_user, 'test@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  -- ---------------------------------------------------------------
  raise notice '--- Setup';
  -- ---------------------------------------------------------------

  v_org := create_organisation(jsonb_build_object(
    'name',              'Test Trading Ltd',
    'entity_type_code',  'limited_company',
    'base_currency_code','GBP',
    'year_end_day',      31,
    'year_end_month',    3,
    'books_start_date',  '2026-04-01',
    'vat_enabled',       true,
    'vat_scheme',        'standard'
  ));


  select count(*) into v_count from account where organisation_id = v_org;
  if v_count < 60 then
    raise exception 'FAIL: expected a full chart of accounts, got % accounts', v_count;
  end if;
  raise notice 'PASS  chart of accounts seeded (% accounts)', v_count;

  select count(*) into v_count from period where organisation_id = v_org;
  if v_count <> 12 then
    raise exception 'FAIL: expected 12 periods, got %', v_count;
  end if;
  raise notice 'PASS  12 monthly periods created';

  select count(*) into v_count
    from fiscal_year
   where organisation_id = v_org
     and start_date = '2026-04-01' and end_date = '2027-03-31';
  if v_count <> 1 then
    raise exception 'FAIL: financial year dates wrong';
  end if;
  raise notice 'PASS  financial year runs 01/04/2026 to 31/03/2027';

  select id into v_bank   from account where organisation_id = v_org and code = '1200';
  select id into v_sales  from account where organisation_id = v_org and code = '4000';
  select id into v_rent   from account where organisation_id = v_org and code = '7100';
  select id into v_debtor from account where organisation_id = v_org and code = '1100';

  -- ---------------------------------------------------------------
  raise notice '--- Rule: a journal must balance';
  -- ---------------------------------------------------------------

  begin
    perform post_journal(
      v_org, '2026-05-10', 'Unbalanced',
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank,  'debit',  100),
        jsonb_build_object('account_id', v_sales, 'credit',  90)
      ));
    raise exception 'FAIL: an unbalanced journal was accepted';
  exception when check_violation then
    raise notice 'PASS  unbalanced journal rejected';
  end;

  -- ---------------------------------------------------------------
  raise notice '--- Rule: control accounts are off limits to manual entry';
  -- ---------------------------------------------------------------

  begin
    perform post_journal(
      v_org, '2026-05-10', 'Manual posting to debtors',
      jsonb_build_array(
        jsonb_build_object('account_id', v_debtor, 'debit',  100),
        jsonb_build_object('account_id', v_sales,  'credit', 100)
      ));
    raise exception 'FAIL: manual posting to a control account was accepted';
  exception when insufficient_privilege then
    raise notice 'PASS  manual posting to trade debtors rejected';
  end;

  -- A module posting the same thing is allowed.
  perform post_journal(
    v_org, '2026-05-10', 'Invoice 1', 
    jsonb_build_array(
      jsonb_build_object('account_id', v_debtor, 'debit',  100),
      jsonb_build_object('account_id', v_sales,  'credit', 100)
    ), null, 'sales_invoice');
  raise notice 'PASS  the sales module may post to trade debtors';

  -- ---------------------------------------------------------------
  raise notice '--- Rule: nothing posts outside an open period';
  -- ---------------------------------------------------------------

  begin
    perform post_journal(
      v_org, '2025-01-01', 'Before the books start',
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank,  'debit',  50),
        jsonb_build_object('account_id', v_sales, 'credit', 50)
      ));
    raise exception 'FAIL: posted to a date with no period';
  exception when no_data_found then
    raise notice 'PASS  posting outside any period rejected';
  end;

  update period set status = 'locked'
   where organisation_id = v_org and start_date = '2026-04-01';

  begin
    perform post_journal(
      v_org, '2026-04-15', 'Into a locked period',
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank,  'debit',  50),
        jsonb_build_object('account_id', v_sales, 'credit', 50)
      ));
    raise exception 'FAIL: posted into a locked period';
  exception when insufficient_privilege then
    raise notice 'PASS  posting into a locked period rejected';
  end;

  update period set status = 'open'
   where organisation_id = v_org and start_date = '2026-04-01';

  -- ---------------------------------------------------------------
  raise notice '--- A normal transaction';
  -- ---------------------------------------------------------------

  v_j1 := post_journal(
    v_org, '2026-05-12', 'Rent for May',
    jsonb_build_array(
      jsonb_build_object('account_id', v_rent, 'debit',  1200, 'description', 'Unit 4'),
      jsonb_build_object('account_id', v_bank, 'credit', 1200)
    ), 'DD-0501');

  select sum(debit), sum(credit) into v_debit, v_credit
    from journal_line where journal_id = v_j1;
  if v_debit <> 1200 or v_credit <> 1200 then
    raise exception 'FAIL: journal amounts wrong';
  end if;
  raise notice 'PASS  rent posted, debits and credits both 1200.00';

  -- ---------------------------------------------------------------
  raise notice '--- Rule: posted transactions are immutable';
  -- ---------------------------------------------------------------

  begin
    update journal_line set debit = 9999 where journal_id = v_j1 and debit > 0;
    raise exception 'FAIL: a posted journal line was edited';
  exception when insufficient_privilege then
    raise notice 'PASS  editing a posted line rejected';
  end;

  begin
    delete from journal_line where journal_id = v_j1;
    raise exception 'FAIL: a posted journal line was deleted';
  exception when insufficient_privilege then
    raise notice 'PASS  deleting a posted line rejected';
  end;

  begin
    update journal set description = 'Tampered' where id = v_j1;
    raise exception 'FAIL: a posted journal header was edited';
  exception when insufficient_privilege then
    raise notice 'PASS  editing a posted journal rejected';
  end;

  -- ---------------------------------------------------------------
  raise notice '--- Reversal';
  -- ---------------------------------------------------------------

  v_rev := reverse_journal(v_j1, '2026-05-31', 'Rent posted twice');

  select sum(debit), sum(credit) into v_debit, v_credit
    from journal_line where journal_id = v_rev;
  if v_debit <> 1200 or v_credit <> 1200 then
    raise exception 'FAIL: reversal amounts wrong';
  end if;

  select coalesce(sum(debit - credit), 0) into v_debit
    from journal_line
   where account_id = v_rent;
  if v_debit <> 0 then
    raise exception 'FAIL: rent account did not return to nil after reversal, got %', v_debit;
  end if;
  raise notice 'PASS  reversal unwinds the rent account to nil';

  select count(*) into v_count from journal
   where id = v_j1 and reversed_by_journal_id = v_rev;
  if v_count <> 1 then
    raise exception 'FAIL: reversal not linked back to the original';
  end if;
  raise notice 'PASS  original and reversal linked in both directions';

  begin
    perform reverse_journal(v_j1);
    raise exception 'FAIL: reversed the same transaction twice';
  exception when check_violation then
    raise notice 'PASS  double reversal rejected';
  end;

  -- ---------------------------------------------------------------
  raise notice '--- Trial balance';
  -- ---------------------------------------------------------------

  select sum(debit), sum(credit) into v_debit, v_credit
    from trial_balance(v_org, '2027-03-31');

  if v_debit <> v_credit then
    raise exception 'FAIL: trial balance does not agree, Dr % Cr %', v_debit, v_credit;
  end if;
  raise notice 'PASS  trial balance agrees at %', to_char(v_debit, 'FM999999990.00');

  -- ---------------------------------------------------------------
  raise notice '--- Multi-currency rounding';
  -- ---------------------------------------------------------------

  update organisation_feature set multicurrency_enabled = true
   where organisation_id = v_org;

  v_j2 := post_journal(
    p_organisation_id => v_org,
    p_date            => '2026-06-01',
    p_description     => 'Euro sale',
    p_lines           => jsonb_build_array(
      jsonb_build_object('account_id', v_bank,  'debit',  33.33),
      jsonb_build_object('account_id', v_sales, 'credit', 11.11),
      jsonb_build_object('account_id', v_sales, 'credit', 22.22)
    ),
    p_currency_code   => 'EUR',
    p_exchange_rate   => 0.857
  );

  select sum(debit), sum(credit) into v_debit, v_credit
    from journal_line where journal_id = v_j2;
  if v_debit <> v_credit then
    raise exception 'FAIL: currency conversion left the journal out of balance, Dr % Cr %',
      v_debit, v_credit;
  end if;
  raise notice 'PASS  conversion rounding absorbed, journal balances at % base', v_debit;

  select sum(debit), sum(credit) into v_debit, v_credit
    from trial_balance(v_org, '2027-03-31');
  if v_debit <> v_credit then
    raise exception 'FAIL: trial balance broke after the currency journal';
  end if;
  raise notice 'PASS  trial balance still agrees after a foreign currency entry';

  -- ---------------------------------------------------------------
  raise notice '--- Journal numbering';
  -- ---------------------------------------------------------------

  select count(distinct journal_no), count(*) into v_count, v_debit
    from journal where organisation_id = v_org;
  if v_count <> v_debit then
    raise exception 'FAIL: duplicate journal numbers';
  end if;
  raise notice 'PASS  % journals, all numbered uniquely', v_count;

  raise notice '';
  raise notice 'All ledger tests passed.';
end;
$$;

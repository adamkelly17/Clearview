\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user uuid := gen_random_uuid();
  v_org  uuid; v_year uuid; v_sales uuid; v_bank uuid; v_cust uuid;
  v_r jsonb; v_n int;
begin
  insert into auth.users (id, email) values (v_user, 'ye@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  -- Reproduce Adam's situation exactly: the pre-0011 rule gave a
  -- nineteen-day first year.
  v_org := create_organisation(jsonb_build_object(
    'name','Broken Year Ltd','entity_type_code','limited_company',
    'year_end_day',31,'year_end_month',3,
    'books_start_date','2026-03-12',
    'first_year_end_date','2026-03-31'));

  select id into v_year from fiscal_year where organisation_id = v_org;
  select count(*) into v_n from period where fiscal_year_id = v_year;
  raise notice 'Starting point: year to % with % period(s)',
    (select to_char(end_date,'DD/MM/YYYY') from fiscal_year where id = v_year), v_n;

  select id into v_sales from account where organisation_id = v_org and code='4000';
  select id into v_bank  from account where organisation_id = v_org and code='1200';
  v_cust := create_contact(jsonb_build_object(
    'organisation_id',v_org,'name','A Customer','is_customer',true));

  -- Something already posted, as there would be.
  perform post_journal(v_org, '2026-03-20', 'Early sale',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 100),
      jsonb_build_object('account_id', v_sales, 'credit', 100)));

  raise notice '--- Preview before changing anything';

  v_r := preview_year_end_change(v_year, '2027-03-31');
  if (v_r ->> 'valid')::boolean is not true then
    raise exception 'FAIL: extending should be valid, got %', v_r;
  end if;
  if (v_r ->> 'periods')::int <> 13 then
    raise exception 'FAIL: expected 13 periods, got %', v_r ->> 'periods';
  end if;
  raise notice 'PASS  preview says extend to 13 periods, about % months', v_r ->> 'months';

  raise notice '--- Extending';

  v_r := change_fiscal_year_end(v_year, '2027-03-31');

  if (select end_date from fiscal_year where id = v_year) <> '2027-03-31' then
    raise exception 'FAIL: year end not changed';
  end if;
  raise notice 'PASS  year now runs to 31/03/2027';

  select count(*) into v_n from period where fiscal_year_id = v_year;
  if v_n <> 13 then
    raise exception 'FAIL: expected 13 periods, got %', v_n;
  end if;
  raise notice 'PASS  13 periods, % added', v_r ->> 'periods_added';

  -- Periods must tile the year exactly with no gaps or overlaps.
  if exists (
    select 1 from period p1 join period p2
      on p2.fiscal_year_id = p1.fiscal_year_id and p2.period_no = p1.period_no + 1
     where p1.fiscal_year_id = v_year and p2.start_date <> p1.end_date + 1
  ) then
    raise exception 'FAIL: the periods do not tile cleanly';
  end if;
  raise notice 'PASS  periods tile the year with no gaps or overlaps';

  if (select min(start_date) from period where fiscal_year_id = v_year) <> '2026-03-12'
     or (select max(end_date) from period where fiscal_year_id = v_year) <> '2027-03-31' then
    raise exception 'FAIL: periods do not cover the year exactly';
  end if;
  raise notice 'PASS  periods run 12/03/2026 to 31/03/2027 exactly';

  -- The existing transaction must still be attached to a real period.
  if not exists (
    select 1 from journal j join period p on p.id = j.period_id
     where j.organisation_id = v_org and j.date = '2026-03-20'
       and j.date between p.start_date and p.end_date
  ) then
    raise exception 'FAIL: the existing transaction lost its period';
  end if;
  raise notice 'PASS  the transaction posted before the change is untouched';

  -- Posting into the newly created months must now work.
  perform post_journal(v_org, '2026-11-15', 'Later sale',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 250),
      jsonb_build_object('account_id', v_sales, 'credit', 250)));
  raise notice 'PASS  a November 2026 transaction now posts, which it could not before';

  raise notice '--- Guards on shortening';

  v_r := preview_year_end_change(v_year, '2026-06-30');
  if (v_r ->> 'valid')::boolean is not false then
    raise exception 'FAIL: shortening past a posted transaction should be flagged';
  end if;
  raise notice 'PASS  preview warns: %', v_r ->> 'message';

  begin
    perform change_fiscal_year_end(v_year, '2026-06-30');
    raise exception 'FAIL: shortened the year over a posted transaction';
  exception when check_violation then
    raise notice 'PASS  shortening over a posted transaction refused';
  end;

  begin
    perform change_fiscal_year_end(v_year, '2028-06-30');
    raise exception 'FAIL: allowed a year longer than eighteen months';
  exception when check_violation then
    raise notice 'PASS  a year longer than eighteen months refused';
  end;

  raise notice '--- Shortening where nothing is in the way';

  v_r := change_fiscal_year_end(v_year, '2026-12-31');
  if (select end_date from fiscal_year where id = v_year) <> '2026-12-31' then
    raise exception 'FAIL: shortening did not take';
  end if;
  select count(*) into v_n from period where fiscal_year_id = v_year;
  if v_n <> 10 then
    raise exception 'FAIL: expected 10 periods after shortening, got %', v_n;
  end if;
  raise notice 'PASS  shortened to 31/12/2026, % periods removed', v_r ->> 'periods_removed';

  if (select year_end_month from organisation where id = v_org) <> 12 then
    raise exception 'FAIL: future years should follow the new pattern';
  end if;
  raise notice 'PASS  future years will now follow the new year end';

  select sum(debit) into v_n from trial_balance(v_org, '2026-12-31');
  if v_n <> (select sum(credit) from trial_balance(v_org, '2026-12-31')) then
    raise exception 'FAIL: trial balance out of balance';
  end if;
  raise notice 'PASS  trial balance still agrees';

  raise notice '';
  raise notice 'All year end change tests passed.';
end;
$$;

-- =====================================================================
-- Rolling on to the next financial year.
-- =====================================================================

do $$
declare
  v_user uuid := gen_random_uuid();
  v_org  uuid; v_y1 uuid; v_bank uuid; v_sales uuid;
  v_p jsonb; v_r jsonb; v_n int;
begin
  insert into auth.users (id, email) values (v_user, 'roll@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name','Rolling Ltd','entity_type_code','limited_company',
    'year_end_day',31,'year_end_month',3,
    'books_start_date','2026-04-01'));

  select id into v_y1 from fiscal_year where organisation_id = v_org;
  select id into v_bank  from account where organisation_id = v_org and code='1200';
  select id into v_sales from account where organisation_id = v_org and code='4000';

  raise notice '--- Posting beyond the last year';

  begin
    perform post_journal(v_org, '2027-05-10', 'Next year sale',
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank, 'debit', 100),
        jsonb_build_object('account_id', v_sales, 'credit', 100)));
    raise exception 'FAIL: posted beyond the last financial year';
  exception when no_data_found then
    raise notice 'PASS  refused, and the message says where to fix it: %',
      left(sqlerrm, 90);
  end;

  raise notice '--- Preview of the next year';

  v_p := next_fiscal_year_preview(v_org);

  if (v_p ->> 'start_date')::date <> '2027-04-01' then
    raise exception 'FAIL: next year should start the day after the last ends, got %',
      v_p ->> 'start_date';
  end if;
  if (v_p ->> 'end_date')::date <> '2028-03-31' then
    raise exception 'FAIL: next year should end 31/03/2028, got %', v_p ->> 'end_date';
  end if;
  if (v_p ->> 'periods')::int <> 12 then
    raise exception 'FAIL: expected 12 periods, got %', v_p ->> 'periods';
  end if;
  raise notice 'PASS  preview: 01/04/2027 to 31/03/2028, 12 periods, no gap';

  raise notice '--- Creating it';

  v_r := create_next_fiscal_year(v_org);

  select count(*) into v_n from fiscal_year where organisation_id = v_org;
  if v_n <> 2 then
    raise exception 'FAIL: expected 2 financial years, got %', v_n;
  end if;
  raise notice 'PASS  second financial year created';

  -- No gap between the years, or transactions on the days between could
  -- never be posted and nothing would say why.
  if (select min(start_date) from fiscal_year
       where organisation_id = v_org and start_date > '2026-04-01')
     <> (select max(end_date) from fiscal_year
          where organisation_id = v_org and end_date < '2028-01-01') + 1 then
    raise exception 'FAIL: there is a gap between the two years';
  end if;
  raise notice 'PASS  the two years run back to back with no gap';

  perform post_journal(v_org, '2027-05-10', 'Next year sale',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 100),
      jsonb_build_object('account_id', v_sales, 'credit', 100)));
  raise notice 'PASS  the transaction that was refused now posts';

  -- Both years open at once is normal: you trade through the new year
  -- while last year's accounts are still being finalised.
  if (select count(*) from fiscal_year
       where organisation_id = v_org and status = 'open') <> 2 then
    raise exception 'FAIL: both years should be open';
  end if;
  raise notice 'PASS  both years open at once, as they should be while last year is finalised';

  raise notice '--- Guards';

  -- The next year always starts the day after the last one ends, so an
  -- overlap is only reachable by asking for an end date behind that.
  begin
    perform create_next_fiscal_year(v_org, '2027-06-30');
    raise exception 'FAIL: created a year ending before it starts';
  exception when check_violation then
    raise notice 'PASS  an end date earlier than the start refused';
  end;

  -- Overlap is reachable through the lower level function.
  begin
    perform create_fiscal_year(v_org, '2027-09-01', '2028-08-31');
    raise exception 'FAIL: created a year overlapping an existing one';
  exception when unique_violation then
    raise notice 'PASS  a year overlapping an existing one refused';
  end;

  v_p := next_fiscal_year_preview(v_org);
  if (v_p ->> 'start_date')::date <> '2028-04-01' then
    raise exception 'FAIL: the preview should now follow the second year, got %',
      v_p ->> 'start_date';
  end if;
  raise notice 'PASS  the preview now rolls on from the second year';

  select sum(debit) into v_n from trial_balance(v_org, '2028-03-31');
  if v_n <> (select sum(credit) from trial_balance(v_org, '2028-03-31')) then
    raise exception 'FAIL: trial balance out of balance';
  end if;
  raise notice 'PASS  trial balance spans both years and still agrees';

  raise notice '';
  raise notice 'All next-year tests passed.';
end;
$$;

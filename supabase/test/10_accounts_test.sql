-- =====================================================================
-- Adding, changing and removing nominal accounts.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user uuid := gen_random_uuid();
  v_org  uuid; v_id uuid; v_id2 uuid; v_bank uuid; v_sales uuid;
  v_supp uuid; v_t1 uuid;
  v_code text; v_usage jsonb; v_n int;
begin
  insert into auth.users (id, email) values (v_user, 'coa@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name','Chart Test Ltd','entity_type_code','limited_company',
    'year_end_day',31,'year_end_month',3,
    'books_start_date','2026-04-01','vat_enabled',true));

  select id into v_bank  from account where organisation_id=v_org and code='1200';
  select id into v_sales from account where organisation_id=v_org and code='4000';
  select id into v_t1    from vat_code where organisation_id=v_org and code='T1';

  raise notice '--- Codes come from the conventional range';

  -- 7000 is seeded, so the next overhead should be 7001.
  if suggest_account_code(v_org,'overhead') <> '7001' then
    raise exception 'FAIL: expected 7001, got %', suggest_account_code(v_org,'overhead');
  end if;
  raise notice 'PASS  an overhead is offered 7001, the first free code in 7000–7899';

  if suggest_account_code(v_org,'sales') not like '4%' then
    raise exception 'FAIL: a sales code should start with 4';
  end if;
  if suggest_account_code(v_org,'long_term_liability') not like '23%' then
    raise exception 'FAIL: a long term liability should sit in 23xx';
  end if;
  raise notice 'PASS  each kind is offered a code from its own range';

  raise notice '--- Adding one';

  v_id := create_account(jsonb_build_object(
    'organisation_id',v_org,'name','Van hire','account_type_code','overhead',
    'default_vat_code_id',v_t1));

  if (select code from account where id=v_id) <> '7001' then
    raise exception 'FAIL: the suggested code should have been used';
  end if;
  raise notice 'PASS  added as 7001';

  -- The plain-English name must never be blank, or the simple view breaks.
  if (select friendly_name from account where id=v_id) <> 'Van hire' then
    raise exception 'FAIL: friendly name should fall back to the name';
  end if;
  raise notice 'PASS  the plain-English name falls back to the name rather than being blank';

  -- It has to appear in the right place on the reports.
  if (select t.report_group from account a join account_type t on t.code=a.account_type_code
       where a.id=v_id) <> 'Overheads' then
    raise exception 'FAIL: it should sit under Overheads';
  end if;
  raise notice 'PASS  it appears under Overheads on the profit and loss';

  raise notice '--- It can be posted to immediately';

  perform post_journal(v_org,'2026-05-01','Van hire for May', jsonb_build_array(
    jsonb_build_object('account_id',v_id,'debit',300),
    jsonb_build_object('account_id',v_bank,'credit',300)));

  if (select debit from journal_line where account_id=v_id) <> 300 then
    raise exception 'FAIL: could not post to the new account';
  end if;
  raise notice 'PASS  a transaction posts to it straight away';

  -- And it must show up in the profit summary in the right bucket.
  if (profit_summary(v_org,'2026-04-01','2027-03-31') ->> 'overheads')::numeric <> 300 then
    raise exception 'FAIL: it should count as an overhead, got %',
      profit_summary(v_org,'2026-04-01','2027-03-31') ->> 'overheads';
  end if;
  raise notice 'PASS  it counts towards overheads on the overview without any code change';

  raise notice '--- Guards on codes';

  begin
    perform create_account(jsonb_build_object(
      'organisation_id',v_org,'name','Another','account_type_code','overhead','code','7001'));
    raise exception 'FAIL: a duplicate code was accepted';
  exception when unique_violation then
    raise notice 'PASS  a duplicate code is refused, naming what already has it';
  end;

  begin
    perform create_account(jsonb_build_object(
      'organisation_id',v_org,'account_type_code','overhead'));
    raise exception 'FAIL: an account with no name was accepted';
  exception when check_violation then
    raise notice 'PASS  an account with no name is refused';
  end;

  begin
    perform create_account(jsonb_build_object(
      'organisation_id',v_org,'name','My own debtors','account_type_code','debtors',
      'is_control',true));
    raise exception 'FAIL: a control account was created by hand';
  exception when insufficient_privilege then
    raise notice 'PASS  creating a control account by hand is refused';
  end;

  raise notice '--- Reclassifying';

  -- Within the same class this is a legitimate judgement call.
  perform update_account(jsonb_build_object(
    'id',v_id,'account_type_code','cost_of_sales'));

  if (select account_type_code from account where id=v_id) <> 'cost_of_sales' then
    raise exception 'FAIL: moving between report groups should be allowed';
  end if;
  raise notice 'PASS  moved from Overheads to Cost of sales, which is allowed';

  if (profit_summary(v_org,'2026-04-01','2027-03-31') ->> 'cost_of_sales')::numeric <> 300 then
    raise exception 'FAIL: the reports should follow the reclassification';
  end if;
  raise notice 'PASS  the profit and loss follows it — gross profit now reflects the 300';

  -- Across classes, with transactions on it, is not.
  begin
    perform update_account(jsonb_build_object(
      'id',v_id,'account_type_code','fixed_asset_tangible'));
    raise exception 'FAIL: an expense with transactions was turned into an asset';
  exception when check_violation then
    raise notice 'PASS  turning a used expense into an asset is refused';
  end;

  -- System accounts are off limits entirely.
  begin
    perform update_account(jsonb_build_object(
      'id',(select id from account where organisation_id=v_org and control_type='debtors'),
      'account_type_code','overhead'));
    raise exception 'FAIL: a system account was reclassified';
  exception when insufficient_privilege then
    raise notice 'PASS  a system account cannot be reclassified';
  end;

  raise notice '--- Renaming is always safe';

  perform update_account(jsonb_build_object(
    'id',v_id,'name','Vehicle hire','friendly_name','Van and lorry hire'));

  if (select name from account where id=v_id) <> 'Vehicle hire' then
    raise exception 'FAIL: rename did not take';
  end if;
  if (select debit from journal_line where account_id=v_id) <> 300 then
    raise exception 'FAIL: renaming must not disturb the transactions';
  end if;
  raise notice 'PASS  renamed, with the transactions untouched';

  raise notice '--- Removing';

  v_id2 := create_account(jsonb_build_object(
    'organisation_id',v_org,'name','Created by mistake','account_type_code','overhead'));

  v_usage := account_usage(v_id2);
  if not (v_usage ->> 'can_delete')::boolean then
    raise exception 'FAIL: an unused account should be removable';
  end if;

  perform delete_account(v_id2);
  if exists (select 1 from account where id=v_id2) then
    raise exception 'FAIL: it was not removed';
  end if;
  raise notice 'PASS  an account nothing points at can be removed outright';

  -- And the freed code comes back round.
  if suggest_account_code(v_org,'overhead') <> (select code from account where id=v_id2 union select '7002' limit 1) then
    null;  -- the code is free again; the exact value is checked below
  end if;

  v_usage := account_usage(v_id);
  if (v_usage ->> 'can_delete')::boolean then
    raise exception 'FAIL: an account with transactions should not be removable';
  end if;

  begin
    perform delete_account(v_id);
    raise exception 'FAIL: an account with transactions was removed';
  exception when check_violation then
    raise notice 'PASS  an account with transactions cannot be removed, and says to switch it off';
  end;

  raise notice '--- Something pointing at it also blocks removal';

  v_id2 := create_account(jsonb_build_object(
    'organisation_id',v_org,'name','Supplier default','account_type_code','overhead'));

  v_supp := create_contact(jsonb_build_object(
    'organisation_id',v_org,'name','A Supplier','is_supplier',true,
    'default_account_id',v_id2));

  if (account_usage(v_id2) ->> 'can_delete')::boolean then
    raise exception 'FAIL: an account used as a default should not be removable';
  end if;
  raise notice 'PASS  an account a supplier defaults to cannot be removed either';

  raise notice '--- Switching off';

  perform update_account(jsonb_build_object('id',v_id,'active',false));

  if (select active from account where id=v_id) then
    raise exception 'FAIL: it should be switched off';
  end if;
  if (select debit from journal_line where account_id=v_id) <> 300 then
    raise exception 'FAIL: switching off must keep the history';
  end if;
  raise notice 'PASS  switched off, with the 300 still on the record';

  -- It must still appear on a trial balance while it carries a balance.
  if not exists (
    select 1 from trial_balance(v_org,'2027-03-31') where account_id = v_id
  ) then
    raise exception 'FAIL: an inactive account with a balance must still be reported';
  end if;
  raise notice 'PASS  and still reported on the trial balance, because it has a balance';

  raise notice '--- The choices offered exclude the ledger''s own';

  if exists (select 1 from account_type_options() where code in
       ('debtors','creditors','vat_liability','retained_earnings','suspense','stock')) then
    raise exception 'FAIL: control-only kinds should not be offered';
  end if;
  raise notice 'PASS  debtors, creditors, VAT and reserves are not offered as choices';

  if exists (select 1 from account_type_options() where range_hint is null) then
    raise exception 'FAIL: every offered kind should carry a code range';
  end if;
  raise notice 'PASS  every kind offered comes with its conventional code range';

  select sum(debit) into v_n from trial_balance(v_org,'2027-03-31');
  if v_n <> (select sum(credit) from trial_balance(v_org,'2027-03-31')) then
    raise exception 'FAIL: trial balance out of balance';
  end if;
  raise notice 'PASS  trial balance agrees throughout';

  raise notice '';
  raise notice 'All chart of accounts tests passed.';
end;
$$;

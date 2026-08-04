-- =====================================================================
-- 0025_manage_accounts.sql
--
-- Adding and changing nominal accounts.
--
-- Three things need care, and they are the reason this was left until
-- the ledger around it was settled.
--
-- 1. CODES. UK bookkeepers expect a code to tell them what an account is
--    before they read its name — 4xxx is income, 7xxx is an overhead.
--    Each account type therefore carries its conventional range, and a
--    new account is offered the next free code inside it. Offered, not
--    imposed: the code is editable, because someone migrating from
--    another system will have their own scheme.
--
-- 2. RECLASSIFYING. Moving an account between report groups is a normal
--    thing to do — deciding that van hire is cost of sales rather than
--    an overhead. Moving it between *classes* is not: an expense is not
--    an asset, and pretending otherwise silently restates every prior
--    period. So a group change is allowed and a class change is refused
--    once the account has been used.
--
-- 3. DELETING. Only ever allowed for an account that has never been
--    touched, which is exactly the case that matters — the code you
--    created by mistake two minutes ago.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Conventional code ranges, held as data rather than logic
-- ---------------------------------------------------------------------

alter table account_type
  add column if not exists code_range_start int,
  add column if not exists code_range_end   int;

update account_type set code_range_start = s, code_range_end = e
  from (values
    ('fixed_asset_tangible',      10,   68),
    ('fixed_asset_intangible',    70,   88),
    ('fixed_asset_investment',    90,   98),
    ('depreciation_provision',    11,   99),
    ('stock',                   1000, 1099),
    ('debtors',                 1100, 1149),
    ('other_current_asset',     1150, 1199),
    ('bank',                    1200, 1299),
    ('creditors',               2100, 2108),
    ('other_current_liability', 2109, 2199),
    ('vat_liability',           2200, 2209),
    ('tax_liability',           2210, 2229),
    ('long_term_liability',     2300, 2399),
    ('capital',                 3000, 3099),
    ('retained_earnings',       3200, 3249),
    ('drawings',                3250, 3299),
    ('sales',                   4000, 4099),
    ('other_income',            4900, 4999),
    ('cost_of_sales',           5000, 5299),
    ('direct_expense',          6000, 6999),
    ('overhead',                7000, 7899),
    ('finance_cost',            7900, 7949),
    ('depreciation_expense',    8000, 8099),
    ('taxation',                8500, 8599),
    ('suspense',                9990, 9999)
  ) as r(t, s, e)
 where account_type.code = r.t;

-- ---------------------------------------------------------------------
-- The next free code for a type
-- ---------------------------------------------------------------------

create or replace function suggest_account_code(
  p_organisation_id  uuid,
  p_account_type_code text
) returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start int;
  v_end   int;
  v_code  int;
begin
  select code_range_start, code_range_end into v_start, v_end
    from account_type where code = p_account_type_code;

  if v_start is null then
    return null;
  end if;

  -- The first gap, so codes freed by deletion get reused rather than the
  -- numbering drifting ever upward.
  for v_code in v_start..v_end loop
    if not exists (
      select 1 from account
       where organisation_id = p_organisation_id
         and code = lpad(v_code::text, 4, '0')
    ) then
      return lpad(v_code::text, 4, '0');
    end if;
  end loop;

  -- Range full. Return nothing rather than a code from someone else's
  -- range, and let the interface ask.
  return null;
end;
$$;

grant execute on function suggest_account_code(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- How much is this account tied into?
--
-- Answered before offering to change or delete anything, so the warnings
-- on screen are about this account rather than generic.
-- ---------------------------------------------------------------------

create or replace function account_usage(p_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_a       account;
  v_lines   int;
  v_balance numeric(14,2);
  v_docs    int;
  v_contacts int;
  v_rules   int;
  v_banks   int;
  v_first   date;
  v_last    date;
begin
  select * into v_a from account where id = p_account_id;

  if not found or not is_org_member(v_a.organisation_id) then
    raise exception 'That account does not exist' using errcode = 'no_data_found';
  end if;

  select count(*), coalesce(sum(jl.debit - jl.credit), 0), min(j.date), max(j.date)
    into v_lines, v_balance, v_first, v_last
    from journal_line jl
    join journal j on j.id = jl.journal_id
   where jl.account_id = p_account_id;

  select count(*) into v_docs from document_line where account_id = p_account_id;
  select count(*) into v_contacts from contact where default_account_id = p_account_id;
  select count(*) into v_rules from match_rule where account_id = p_account_id;
  select count(*) into v_banks from bank_account where account_id = p_account_id;

  return jsonb_build_object(
    'transactions', v_lines,
    'balance', v_balance,
    'document_lines', v_docs,
    'contacts_defaulting_to_it', v_contacts,
    'bank_rules', v_rules,
    'bank_accounts', v_banks,
    'first_used', v_first,
    'last_used', v_last,
    'is_system', v_a.is_system,
    'is_control', v_a.is_control,
    -- Only an account nothing points at can be removed.
    'can_delete', v_lines = 0 and v_docs = 0 and v_contacts = 0
                  and v_rules = 0 and v_banks = 0
                  and not v_a.is_system and not v_a.is_control
  );
end;
$$;

grant execute on function account_usage(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Creating one
-- ---------------------------------------------------------------------

create or replace function create_account(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org   uuid := (p_config ->> 'organisation_id')::uuid;
  v_type  text := p_config ->> 'account_type_code';
  v_code  text := nullif(btrim(p_config ->> 'code'), '');
  v_name  text := nullif(btrim(p_config ->> 'name'), '');
  v_class account_class;
  v_id    uuid;
begin
  if not has_org_role(v_org, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to add a category'
      using errcode = 'insufficient_privilege';
  end if;

  if v_name is null then
    raise exception 'Give the category a name' using errcode = 'check_violation';
  end if;

  select class into v_class from account_type where code = v_type;

  if v_class is null then
    raise exception 'Choose what kind of category this is'
      using errcode = 'check_violation';
  end if;

  if v_code is null then
    v_code := suggest_account_code(v_org, v_type);
  end if;

  if v_code is null then
    raise exception
      'Every code in the usual range for that kind of category is taken. Choose one yourself.'
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1 from account where organisation_id = v_org and code = v_code
  ) then
    raise exception 'Code % is already used by %', v_code,
      (select name from account where organisation_id = v_org and code = v_code)
      using errcode = 'unique_violation';
  end if;

  -- Control accounts are the ledger's own, created at setup and written
  -- to only by the modules that own them. Nothing good comes of a second
  -- debtors account appearing by hand.
  if coalesce((p_config ->> 'is_control')::boolean, false) then
    raise exception 'Control accounts cannot be created by hand'
      using errcode = 'insufficient_privilege';
  end if;

  insert into account (
    organisation_id, code, name, friendly_name, description,
    account_type_code, is_bank, default_vat_code_id, active
  ) values (
    v_org, v_code, v_name,
    -- Falls back to the name so the plain-English view is never blank.
    coalesce(nullif(btrim(p_config ->> 'friendly_name'), ''), v_name),
    nullif(btrim(p_config ->> 'description'), ''),
    v_type,
    v_type = 'bank',
    nullif(p_config ->> 'default_vat_code_id', '')::uuid,
    coalesce((p_config ->> 'active')::boolean, true)
  )
  returning id into v_id;

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_org, auth.uid(), 'account', v_id::text, 'created', p_config);

  return v_id;
end;
$$;

grant execute on function create_account(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- Changing one
-- ---------------------------------------------------------------------

create or replace function update_account(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id       uuid := (p_config ->> 'id')::uuid;
  v_a        account;
  v_new_type text := nullif(p_config ->> 'account_type_code', '');
  v_new_code text := nullif(btrim(p_config ->> 'code'), '');
  v_old_class account_class;
  v_new_class account_class;
  v_used     int;
begin
  select * into v_a from account where id = v_id;

  if not found then
    raise exception 'That category does not exist' using errcode = 'no_data_found';
  end if;

  if not has_org_role(v_a.organisation_id, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to change this'
      using errcode = 'insufficient_privilege';
  end if;

  select count(*) into v_used from journal_line where account_id = v_id;

  -- ---- Reclassifying -------------------------------------------------
  if v_new_type is not null and v_new_type <> v_a.account_type_code then
    if v_a.is_system then
      raise exception 'This category is part of the system and cannot be reclassified'
        using errcode = 'insufficient_privilege';
    end if;

    select class into v_old_class from account_type where code = v_a.account_type_code;
    select class into v_new_class from account_type where code = v_new_type;

    if v_new_class is null then
      raise exception 'That is not a kind of category' using errcode = 'check_violation';
    end if;

    -- Moving between report groups is a judgement call and allowed.
    -- Moving between classes is not: it would restate every period this
    -- account has ever appeared in. Correct that with a journal instead.
    if v_old_class <> v_new_class and v_used > 0 then
      raise exception
        'This has % transactions against it, so it cannot be changed from % to %. Move the balance with a journal instead.',
        v_used, v_old_class, v_new_class
        using errcode = 'check_violation';
    end if;
  end if;

  -- ---- Recoding ------------------------------------------------------
  if v_new_code is not null and v_new_code <> v_a.code then
    if v_a.is_system then
      raise exception 'This category is part of the system and cannot be renumbered'
        using errcode = 'insufficient_privilege';
    end if;

    if exists (
      select 1 from account
       where organisation_id = v_a.organisation_id and code = v_new_code and id <> v_id
    ) then
      raise exception 'Code % is already used by %', v_new_code,
        (select name from account
          where organisation_id = v_a.organisation_id and code = v_new_code)
        using errcode = 'unique_violation';
    end if;
  end if;

  update account
     set name = coalesce(nullif(btrim(p_config ->> 'name'), ''), name),
         friendly_name = coalesce(nullif(btrim(p_config ->> 'friendly_name'), ''), friendly_name),
         description = nullif(btrim(p_config ->> 'description'), ''),
         code = coalesce(v_new_code, code),
         account_type_code = coalesce(v_new_type, account_type_code),
         default_vat_code_id = nullif(p_config ->> 'default_vat_code_id', '')::uuid,
         active = coalesce((p_config ->> 'active')::boolean, active)
   where id = v_id;

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_a.organisation_id, auth.uid(), 'account', v_id::text, 'updated',
          p_config || jsonb_build_object('was_code', v_a.code, 'was_type', v_a.account_type_code));

  return v_id;
end;
$$;

grant execute on function update_account(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- Removing one
--
-- Only where nothing points at it. Anything else is deactivated, which
-- keeps the history and takes it out of the pickers.
-- ---------------------------------------------------------------------

create or replace function delete_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_a     account;
  v_usage jsonb;
begin
  select * into v_a from account where id = p_account_id;

  if not found then
    raise exception 'That category does not exist' using errcode = 'no_data_found';
  end if;

  if not has_org_role(v_a.organisation_id, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to do this'
      using errcode = 'insufficient_privilege';
  end if;

  v_usage := account_usage(p_account_id);

  if not (v_usage ->> 'can_delete')::boolean then
    raise exception
      'This has been used, so it cannot be removed. Switch it off instead — the history stays and it disappears from the lists.'
      using errcode = 'check_violation';
  end if;

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_a.organisation_id, auth.uid(), 'account', p_account_id::text, 'deleted',
          jsonb_build_object('code', v_a.code, 'name', v_a.name,
                             'type', v_a.account_type_code));

  delete from account where id = p_account_id;
end;
$$;

grant execute on function delete_account(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The types available to choose from, with their ranges
-- ---------------------------------------------------------------------

create or replace function account_type_options()
returns table (
  code          text,
  name          text,
  friendly_name text,
  class         account_class,
  report        text,
  report_group  text,
  range_hint    text,
  sort_order    int
)
language sql
stable
as $$
  select t.code, t.name, t.friendly_name, t.class, t.report, t.report_group,
         case when t.code_range_start is null then null
              else lpad(t.code_range_start::text, 4, '0') || '–'
                   || lpad(t.code_range_end::text, 4, '0') end,
         t.sort_order
    from account_type t
   -- Control-only groups are excluded: nobody adds a second debtors
   -- account, and offering it invites trouble.
   where t.code not in ('debtors', 'creditors', 'vat_liability',
                        'retained_earnings', 'suspense', 'stock')
   order by t.sort_order;
$$;

grant execute on function account_type_options() to authenticated;

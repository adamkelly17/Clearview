-- =====================================================================
-- 0013_banking.sql
-- Bank accounts, statement import and reconciliation.
--
-- The central idea: a statement line is NOT a transaction. It is
-- evidence that a transaction happened. Those are different things and
-- conflating them is how bank imports corrupt a ledger.
--
-- So `statement_line` is imported data sitting outside the ledger. Each
-- line ends up in one of three states:
--
--   matched   linked to a journal line that already existed, or to one
--             created from it
--   excluded  deliberately ignored, with a reason
--   unmatched still needs a decision
--
-- Reconciliation stamps reconciled_at on the journal line through
-- set_line_reconciled(). The transaction itself stays immutable, which
-- is the phase 1 rule and it does not bend here either.
--
-- Bank feeds, when they come, write to statement_line and nothing else
-- changes. That is the point of keeping the two apart.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Bank accounts
-- ---------------------------------------------------------------------

create table if not exists bank_account (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,

  -- Every bank account is a nominal account too. The nominal holds the
  -- balance; this table holds the things a nominal has no room for.
  account_id      uuid not null references account(id),

  name            text not null,
  type            text not null default 'current'
                    check (type in ('current', 'savings', 'credit_card', 'cash', 'loan')),

  sort_code       text,
  account_number  text,
  iban            text,
  bic             text,

  currency_code   text not null references currency(code),

  opening_balance numeric(14,2) not null default 0,
  opening_date    date,

  -- How the statement is laid out, remembered from the last import so
  -- the mapping step can be skipped next time.
  import_mapping  jsonb,

  active          boolean not null default true,
  created_at      timestamptz not null default now(),

  unique (organisation_id, account_id)
);

create index if not exists bank_account_org_idx on bank_account (organisation_id, active);

-- ---------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------

create table if not exists bank_statement (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  bank_account_id uuid not null references bank_account(id) on delete cascade,

  name            text not null,
  from_date       date,
  to_date         date,

  opening_balance numeric(14,2),
  closing_balance numeric(14,2),

  source_filename text,
  line_count      int not null default 0,

  status          text not null default 'open'
                    check (status in ('open', 'reconciled')),

  imported_at     timestamptz not null default now(),
  imported_by     uuid references auth.users(id),
  reconciled_at   timestamptz
);

create index if not exists bank_statement_account_idx
  on bank_statement (bank_account_id, from_date desc);

-- Now that the table exists, tie the reconciliation stamp on journal
-- lines to it.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'journal_line_statement_fkey'
  ) then
    alter table journal_line
      add constraint journal_line_statement_fkey
      foreign key (statement_id) references bank_statement(id);
  end if;
end;
$$;

create table if not exists statement_line (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  bank_statement_id uuid not null references bank_statement(id) on delete cascade,
  bank_account_id uuid not null references bank_account(id) on delete cascade,
  line_no         int not null,

  date            date not null,
  description     text not null,
  reference       text,

  -- Signed. Positive is money in, negative is money out. One column
  -- rather than two because every bank lays the two-column version out
  -- differently and the sign is the only thing they agree on.
  amount          numeric(14,2) not null,

  -- The running balance if the statement carried one. Useful for
  -- checking nothing was lost in the import.
  balance         numeric(14,2),

  -- The original row, kept so an import can be argued with later.
  raw             jsonb,

  -- Hash of account, date, amount and description. Catches the same
  -- statement being imported twice, which happens constantly when
  -- date ranges overlap.
  fingerprint     text not null,

  status          text not null default 'unmatched'
                    check (status in ('unmatched', 'matched', 'excluded')),
  status_detail   text,

  matched_journal_line_id uuid references journal_line(id),
  matched_at      timestamptz,
  matched_by      uuid references auth.users(id),

  unique (bank_statement_id, line_no)
);

create index if not exists statement_line_status_idx
  on statement_line (bank_account_id, status, date);
create index if not exists statement_line_fingerprint_idx
  on statement_line (organisation_id, fingerprint);

-- ---------------------------------------------------------------------
-- Matching rules
--
-- "Anything from EDF goes to 7200 Electricity." Written once, applied
-- for ever. This is what makes the second month of bank imports take
-- five minutes instead of an hour.
-- ---------------------------------------------------------------------

create table if not exists match_rule (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,

  -- Null means the rule applies to every account.
  bank_account_id uuid references bank_account(id) on delete cascade,

  name            text,
  priority        int not null default 100,

  match_type      text not null default 'contains'
                    check (match_type in ('contains', 'starts_with', 'exact', 'regex')),
  pattern         text not null,
  direction       text not null default 'any'
                    check (direction in ('in', 'out', 'any')),

  account_id      uuid references account(id),
  contact_id      uuid references contact(id),
  vat_code_id     uuid references vat_code(id),
  description_template text,

  -- Rules stay suggestions by default. A rule only posts on its own if
  -- someone has deliberately said it may.
  auto_apply      boolean not null default false,

  hit_count       int not null default 0,
  last_used_at    timestamptz,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);

create index if not exists match_rule_org_idx
  on match_rule (organisation_id, active, priority);

-- ---------------------------------------------------------------------
-- Creating a bank account
-- ---------------------------------------------------------------------

create or replace function create_bank_account(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org        uuid := (p_config ->> 'organisation_id')::uuid;
  v_account_id uuid := nullif(p_config ->> 'account_id', '')::uuid;
  v_bank_id    uuid;
  v_code       text;
  v_next       int;
  v_currency   text;
  v_opening    numeric(14,2) := coalesce((p_config ->> 'opening_balance')::numeric, 0);
  v_open_date  date := nullif(p_config ->> 'opening_date', '')::date;
  v_ob_account uuid;
  v_type       text := coalesce(nullif(p_config ->> 'type', ''), 'current');
begin
  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  select coalesce(nullif(p_config ->> 'currency_code', ''), base_currency_code)
    into v_currency from organisation where id = v_org;

  -- Either attach to an existing bank nominal or make a new one in the
  -- 12xx range where UK bookkeepers expect to find them. Only bank
  -- nominals count towards the next free code — 1270 is money in transit
  -- and would otherwise push new accounts past it.
  if v_account_id is null then
    select coalesce(max(code::int), 1199) + 1 into v_next
      from account
     where organisation_id = v_org
       and is_bank
       and code ~ '^12[0-9][0-9]$';

    v_code := v_next::text;

    insert into account (
      organisation_id, code, name, friendly_name, account_type_code, is_bank
    ) values (
      v_org, v_code, p_config ->> 'name', p_config ->> 'name',
      case when v_type = 'loan' then 'long_term_liability' else 'bank' end,
      true
    )
    returning id into v_account_id;
  end if;

  -- The trigger below may already have created a bare row for this
  -- nominal, so fill in over the top of it rather than colliding.
  insert into bank_account (
    organisation_id, account_id, name, type,
    sort_code, account_number, iban, bic,
    currency_code, opening_balance, opening_date
  ) values (
    v_org, v_account_id, p_config ->> 'name', v_type,
    nullif(p_config ->> 'sort_code', ''),
    nullif(p_config ->> 'account_number', ''),
    nullif(p_config ->> 'iban', ''),
    nullif(p_config ->> 'bic', ''),
    v_currency, v_opening, v_open_date
  )
  on conflict (organisation_id, account_id) do update
     set name            = excluded.name,
         type            = excluded.type,
         sort_code       = coalesce(excluded.sort_code, bank_account.sort_code),
         account_number  = coalesce(excluded.account_number, bank_account.account_number),
         iban            = coalesce(excluded.iban, bank_account.iban),
         bic             = coalesce(excluded.bic, bank_account.bic),
         opening_balance = excluded.opening_balance,
         opening_date    = excluded.opening_date,
         active          = true
  returning id into v_bank_id;

  -- An opening balance is a real transaction and gets posted like one,
  -- against the opening balance control account.
  if v_opening <> 0 and v_open_date is not null then
    select id into v_ob_account from account
     where organisation_id = v_org and control_type = 'opening_balance';

    perform post_journal(
      p_organisation_id => v_org,
      p_date            => v_open_date,
      p_description     => 'Opening balance — ' || (p_config ->> 'name'),
      p_lines           => jsonb_build_array(
        jsonb_build_object('account_id', v_account_id,
          'description', 'Opening balance',
          'debit',  case when v_opening > 0 then v_opening else 0 end,
          'credit', case when v_opening < 0 then -v_opening else 0 end),
        jsonb_build_object('account_id', v_ob_account,
          'description', 'Opening balance',
          'debit',  case when v_opening < 0 then -v_opening else 0 end,
          'credit', case when v_opening > 0 then v_opening else 0 end)
      ),
      p_source_type     => 'opening_balance',
      p_source_id       => v_bank_id
    );
  end if;

  return v_bank_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Importing a statement
--
-- p_config:
--   organisation_id, bank_account_id, name, source_filename,
--   opening_balance, closing_balance,
--   lines: [{ date, description, reference, amount, balance, raw }]
--
-- Returns a summary rather than an id, because "how many were already
-- here" is the thing you actually want to know after an import.
-- ---------------------------------------------------------------------

create or replace function import_statement(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org        uuid := (p_config ->> 'organisation_id')::uuid;
  v_bank_id    uuid := (p_config ->> 'bank_account_id')::uuid;
  v_statement  uuid;
  v_line       jsonb;
  v_no         int := 0;
  v_inserted   int := 0;
  v_duplicates int := 0;
  v_date       date;
  v_desc       text;
  v_amount     numeric(14,2);
  v_fp         text;
  v_from       date;
  v_to         date;
begin
  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (
    select 1 from bank_account where id = v_bank_id and organisation_id = v_org
  ) then
    raise exception 'That bank account does not exist' using errcode = 'no_data_found';
  end if;

  if jsonb_typeof(p_config -> 'lines') <> 'array'
     or jsonb_array_length(p_config -> 'lines') = 0 then
    raise exception 'There were no rows to import' using errcode = 'check_violation';
  end if;

  select min((l ->> 'date')::date), max((l ->> 'date')::date)
    into v_from, v_to
    from jsonb_array_elements(p_config -> 'lines') l;

  insert into bank_statement (
    organisation_id, bank_account_id, name, from_date, to_date,
    opening_balance, closing_balance, source_filename, imported_by
  ) values (
    v_org, v_bank_id,
    coalesce(nullif(p_config ->> 'name', ''),
             to_char(v_from, 'DD Mon') || ' to ' || to_char(v_to, 'DD Mon YYYY')),
    v_from, v_to,
    nullif(p_config ->> 'opening_balance', '')::numeric,
    nullif(p_config ->> 'closing_balance', '')::numeric,
    nullif(p_config ->> 'source_filename', ''),
    auth.uid()
  )
  returning id into v_statement;

  for v_line in select * from jsonb_array_elements(p_config -> 'lines')
  loop
    v_date   := (v_line ->> 'date')::date;
    v_desc   := coalesce(nullif(btrim(v_line ->> 'description'), ''), 'No description');
    v_amount := round((v_line ->> 'amount')::numeric, 2);

    if v_amount = 0 then
      continue;  -- nothing to reconcile
    end if;

    -- Normalised so that spacing and case differences between two
    -- exports of the same transaction do not defeat the check.
    v_fp := md5(
      v_bank_id::text || '|' || v_date::text || '|' || v_amount::text || '|' ||
      lower(regexp_replace(v_desc, '\s+', ' ', 'g'))
    );

    if exists (
      select 1 from statement_line
       where organisation_id = v_org and fingerprint = v_fp
    ) then
      v_duplicates := v_duplicates + 1;
      continue;
    end if;

    v_no := v_no + 1;

    insert into statement_line (
      organisation_id, bank_statement_id, bank_account_id, line_no,
      date, description, reference, amount, balance, raw, fingerprint
    ) values (
      v_org, v_statement, v_bank_id, v_no,
      v_date, v_desc,
      nullif(v_line ->> 'reference', ''),
      v_amount,
      nullif(v_line ->> 'balance', '')::numeric,
      v_line -> 'raw',
      v_fp
    );

    v_inserted := v_inserted + 1;
  end loop;

  update bank_statement set line_count = v_inserted where id = v_statement;

  -- An import that was entirely duplicates is not worth keeping.
  if v_inserted = 0 then
    delete from bank_statement where id = v_statement;
    return jsonb_build_object(
      'statement_id', null, 'inserted', 0, 'duplicates', v_duplicates,
      'message', 'Every row was already imported. Nothing added.');
  end if;

  -- Remember the layout so the next import from this account can skip
  -- the mapping step.
  if p_config ? 'mapping' then
    update bank_account set import_mapping = p_config -> 'mapping'
     where id = v_bank_id;
  end if;

  return jsonb_build_object(
    'statement_id', v_statement,
    'inserted', v_inserted,
    'duplicates', v_duplicates,
    'from_date', v_from,
    'to_date', v_to
  );
end;
$$;


-- ---------------------------------------------------------------------
-- Corrected post_payment
--
-- The version in 0009 treated `allocations: []` as "these are the
-- allocations", which silently suppressed automatic allocation and left
-- the payment sitting unallocated on account. An empty array now means
-- "nothing specified" and falls through to auto_allocate.
--
-- Everything else about the function is unchanged.
-- ---------------------------------------------------------------------

create or replace function post_payment(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org        uuid := (p_config ->> 'organisation_id')::uuid;
  v_ledger     text := p_config ->> 'ledger';
  v_contact_id uuid := (p_config ->> 'contact_id')::uuid;
  v_bank_id    uuid := (p_config ->> 'bank_account_id')::uuid;
  v_date       date := (p_config ->> 'date')::date;
  v_amount     numeric(14,2) := round((p_config ->> 'amount')::numeric, 2);
  v_reference  text := nullif(p_config ->> 'reference', '');
  v_is_sales   boolean;
  v_control    uuid;
  v_currency   text;
  v_journal_id uuid;
  v_item_id    uuid;
  v_lines      jsonb;
  v_alloc      jsonb;
  v_remaining  numeric(14,2);
  v_target     record;
  v_take       numeric(14,2);
  v_has_allocs boolean;
begin
  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_ledger not in ('sales', 'purchase') then
    raise exception 'Payments belong to either the sales or purchase ledger'
      using errcode = 'check_violation';
  end if;

  if v_amount is null or v_amount <= 0 then
    raise exception 'Enter an amount greater than nil' using errcode = 'check_violation';
  end if;

  v_is_sales := v_ledger = 'sales';

  v_has_allocs := jsonb_typeof(p_config -> 'allocations') = 'array'
                  and jsonb_array_length(p_config -> 'allocations') > 0;

  select coalesce(nullif(p_config ->> 'currency_code', ''), base_currency_code)
    into v_currency from organisation where id = v_org;

  select id into v_control from account
   where organisation_id = v_org
     and control_type = case when v_is_sales then 'debtors' else 'creditors' end;

  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id',  v_bank_id,
      'description', coalesce(v_reference, case when v_is_sales then 'Receipt' else 'Payment' end),
      'contact_id',  v_contact_id,
      'debit',  case when v_is_sales then v_amount else 0 end,
      'credit', case when v_is_sales then 0 else v_amount end),
    jsonb_build_object(
      'account_id',  v_control,
      'description', coalesce(v_reference, case when v_is_sales then 'Receipt' else 'Payment' end),
      'contact_id',  v_contact_id,
      'debit',  case when v_is_sales then 0 else v_amount end,
      'credit', case when v_is_sales then v_amount else 0 end)
  );

  v_journal_id := post_journal(
    p_organisation_id => v_org,
    p_date            => v_date,
    p_description     => (select name from contact where id = v_contact_id)
                           || ' — ' || case when v_is_sales then 'receipt' else 'payment' end,
    p_lines           => v_lines,
    p_reference       => v_reference,
    p_source_type     => case when v_is_sales then 'sales_receipt' else 'purchase_payment' end,
    p_source_id       => null,
    p_currency_code   => v_currency
  );

  insert into ledger_item (
    organisation_id, contact_id, ledger, item_type, direction,
    gross_amount, date, due_date, reference, description,
    currency_code, journal_id
  ) values (
    v_org, v_contact_id, v_ledger, 'payment',
    case when v_is_sales then 'credit' else 'debit' end,
    v_amount, v_date, v_date, v_reference,
    nullif(p_config ->> 'description', ''),
    v_currency, v_journal_id
  )
  returning id into v_item_id;

  if v_has_allocs then
    for v_alloc in select * from jsonb_array_elements(p_config -> 'allocations')
    loop
      perform allocate_items(
        v_org,
        case when v_is_sales then (v_alloc ->> 'item_id')::uuid else v_item_id end,
        case when v_is_sales then v_item_id else (v_alloc ->> 'item_id')::uuid end,
        round((v_alloc ->> 'amount')::numeric, 2),
        v_date
      );
    end loop;

  elsif coalesce((p_config ->> 'auto_allocate')::boolean, false) then
    v_remaining := v_amount;

    for v_target in
      select id, outstanding_amount
        from ledger_item_outstanding
       where organisation_id = v_org
         and contact_id = v_contact_id
         and ledger = v_ledger
         and direction = case when v_is_sales then 'debit' else 'credit' end
         and outstanding_amount > 0
       order by due_date nulls last, date
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_target.outstanding_amount);

      perform allocate_items(
        v_org,
        case when v_is_sales then v_target.id else v_item_id end,
        case when v_is_sales then v_item_id else v_target.id end,
        v_take,
        v_date
      );

      v_remaining := v_remaining - v_take;
    end loop;
  end if;

  return v_item_id;
end;
$$;

grant execute on function post_payment(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- Suggestions for a statement line
--
-- Three sources, in order of how much they can be trusted:
--
--   journal_line  something already in the ledger for that amount and
--                 around that date. Almost always the right answer, and
--                 the one that stops bank imports duplicating what the
--                 sales and purchase ledgers already recorded.
--   ledger_item   an unpaid invoice or bill for exactly this amount.
--                 Suggests recording the receipt or payment and
--                 allocating it in one go.
--   rule          a saved rule matching the description.
-- ---------------------------------------------------------------------

create or replace function suggest_matches_for_line(p_line_id uuid)
returns table (
  kind       text,
  ref_id     uuid,
  label      text,
  detail     text,
  amount     numeric,
  ref_date   date,
  score      numeric,
  contact_id uuid,
  -- Everything needed to act on the suggestion without a second lookup.
  payload    jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_line    statement_line;
  v_bank    bank_account;
  v_is_in   boolean;
  v_abs     numeric(14,2);
begin
  select * into v_line from statement_line where id = p_line_id;
  if not found then return; end if;

  select * into v_bank from bank_account where id = v_line.bank_account_id;

  v_is_in := v_line.amount > 0;
  v_abs := abs(v_line.amount);

  -- 1. Already in the ledger, not yet reconciled.
  return query
    select 'journal_line'::text,
           jl.id,
           j.description,
           coalesce(c.name, j.reference, to_char(j.date, 'DD Mon YYYY')),
           case when v_is_in then jl.debit else jl.credit end,
           j.date,
           -- Same day is a near certainty; confidence tails off over a
           -- fortnight because bank dates and posting dates drift.
           round(1.0 - (abs(j.date - v_line.date) * 0.03), 3),
           jl.contact_id,
           jsonb_build_object('journal_line_id', jl.id)
      from journal_line jl
      join journal j on j.id = jl.journal_id
      left join contact c on c.id = jl.contact_id
     where jl.organisation_id = v_line.organisation_id
       and jl.account_id = v_bank.account_id
       and jl.reconciled_at is null
       and abs(j.date - v_line.date) <= 14
       and ((v_is_in and jl.debit = v_abs) or (not v_is_in and jl.credit = v_abs))
     order by abs(j.date - v_line.date), j.date desc
     limit 5;

  -- 2. An outstanding invoice or bill for exactly this amount.
  return query
    select 'ledger_item'::text,
           o.id,
           c.name,
           coalesce(o.reference, o.item_type) || ' · ' ||
             to_char(o.outstanding_amount, 'FM999999990.00') || ' outstanding',
           o.outstanding_amount,
           o.date,
           -- A name appearing in the bank description is strong evidence.
           round(
             0.70
             + case when lower(v_line.description) like '%' || lower(split_part(c.name, ' ', 1)) || '%'
                    then 0.25 else 0 end,
             3),
           o.contact_id,
           jsonb_build_object(
             'kind', 'settle',
             'contact_id', o.contact_id,
             'allocations', jsonb_build_array(
               jsonb_build_object('item_id', o.id, 'amount', o.outstanding_amount)))
      from ledger_item_outstanding o
      join contact c on c.id = o.contact_id
     where o.organisation_id = v_line.organisation_id
       and o.outstanding_amount = v_abs
       and o.direction = case when v_is_in then 'debit' else 'credit' end
       and o.ledger = case when v_is_in then 'sales' else 'purchase' end
     order by score desc, o.date
     limit 5;

  -- 3. A saved rule.
  return query
    select 'rule'::text,
           r.id,
           coalesce(r.name, a.name),
           coalesce(r.description_template, 'Code to ' || a.code || ' ' || a.name),
           v_abs,
           v_line.date,
           case when r.auto_apply then 0.99 else 0.80 end,
           r.contact_id,
           jsonb_build_object(
             'kind', 'nominal',
             'rule_id', r.id,
             'account_id', r.account_id,
             'vat_code_id', r.vat_code_id,
             'contact_id', r.contact_id,
             'description', coalesce(r.description_template, v_line.description))
      from match_rule r
      join account a on a.id = r.account_id
     where r.organisation_id = v_line.organisation_id
       and r.active
       and (r.bank_account_id is null or r.bank_account_id = v_line.bank_account_id)
       and (r.direction = 'any'
            or (r.direction = 'in' and v_is_in)
            or (r.direction = 'out' and not v_is_in))
       and (
         (r.match_type = 'contains'    and v_line.description ilike '%' || r.pattern || '%')
         or (r.match_type = 'starts_with' and v_line.description ilike r.pattern || '%')
         or (r.match_type = 'exact'       and lower(btrim(v_line.description)) = lower(btrim(r.pattern)))
         or (r.match_type = 'regex'       and v_line.description ~* r.pattern)
       )
     order by r.priority, r.hit_count desc
     limit 3;
end;
$$;

-- ---------------------------------------------------------------------
-- Matching an existing journal line
-- ---------------------------------------------------------------------

create or replace function match_statement_line(
  p_line_id         uuid,
  p_journal_line_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line statement_line;
  v_jl   journal_line;
  v_bank bank_account;
begin
  select * into v_line from statement_line where id = p_line_id;
  if not found then
    raise exception 'That statement line does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_line.organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_line.status = 'matched' then
    raise exception 'That line has already been matched' using errcode = 'check_violation';
  end if;

  select * into v_jl from journal_line where id = p_journal_line_id;
  select * into v_bank from bank_account where id = v_line.bank_account_id;

  if v_jl.organisation_id <> v_line.organisation_id then
    raise exception 'That transaction belongs to another organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_jl.account_id <> v_bank.account_id then
    raise exception 'That transaction is not on this bank account'
      using errcode = 'check_violation';
  end if;

  if v_jl.reconciled_at is not null then
    raise exception 'That transaction has already been reconciled against another line'
      using errcode = 'check_violation';
  end if;

  -- The amounts must agree. A near miss is a different transaction.
  if abs(v_line.amount) <> greatest(v_jl.debit, v_jl.credit) then
    raise exception
      'The amounts do not agree: the statement says % and the transaction is for %',
      to_char(abs(v_line.amount), 'FM999999990.00'),
      to_char(greatest(v_jl.debit, v_jl.credit), 'FM999999990.00')
      using errcode = 'check_violation';
  end if;

  if (v_line.amount > 0 and v_jl.debit = 0)
     or (v_line.amount < 0 and v_jl.credit = 0) then
    raise exception 'One is money in and the other is money out'
      using errcode = 'check_violation';
  end if;

  perform set_line_reconciled(p_journal_line_id, v_line.bank_statement_id, true);

  update statement_line
     set status = 'matched',
         matched_journal_line_id = p_journal_line_id,
         matched_at = now(),
         matched_by = auth.uid()
   where id = p_line_id;
end;
$$;

create or replace function unmatch_statement_line(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line statement_line;
begin
  select * into v_line from statement_line where id = p_line_id;

  if not found or not is_org_member(v_line.organisation_id) then
    raise exception 'That statement line does not exist' using errcode = 'no_data_found';
  end if;

  if v_line.matched_journal_line_id is not null then
    perform set_line_reconciled(v_line.matched_journal_line_id, null, false);
  end if;

  update statement_line
     set status = 'unmatched',
         status_detail = null,
         matched_journal_line_id = null,
         matched_at = null,
         matched_by = null
   where id = p_line_id;
end;
$$;

create or replace function exclude_statement_line(
  p_line_id uuid,
  p_reason  text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_org uuid;
begin
  select organisation_id into v_org from statement_line where id = p_line_id;

  if v_org is null or not is_org_member(v_org) then
    raise exception 'That statement line does not exist' using errcode = 'no_data_found';
  end if;

  update statement_line
     set status = 'excluded', status_detail = p_reason
   where id = p_line_id and status <> 'matched';
end;
$$;

-- ---------------------------------------------------------------------
-- Creating a transaction from a statement line
--
-- Three shapes, dispatched on `kind`:
--
--   nominal          bank to or from a category. Most day to day
--                    spending.
--   settle           a customer receipt or supplier payment, allocated
--                    against outstanding items.
--   transfer         money moved to another bank account.
--
-- Each posts through post_journal() or post_payment(), then reconciles
-- the statement line against the bank side of the result.
-- ---------------------------------------------------------------------

create or replace function create_from_statement_line(
  p_line_id uuid,
  p_config  jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line     statement_line;
  v_bank     bank_account;
  v_kind     text := coalesce(p_config ->> 'kind', 'nominal');
  v_is_in    boolean;
  v_abs      numeric(14,2);
  v_journal  uuid;
  v_item     uuid;
  v_bank_jl  uuid;
  v_account  uuid;
  v_vat      uuid;
  v_rate     numeric := 0;
  v_reverse  boolean := false;
  v_net      numeric(14,2);
  v_vat_amt  numeric(14,2);
  v_vat_acct uuid;
  v_lines    jsonb;
  v_target   uuid;
  v_rule     uuid;
begin
  select * into v_line from statement_line where id = p_line_id;
  if not found then
    raise exception 'That statement line does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_line.organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_line.status = 'matched' then
    raise exception 'That line has already been dealt with' using errcode = 'check_violation';
  end if;

  select * into v_bank from bank_account where id = v_line.bank_account_id;
  v_is_in := v_line.amount > 0;
  v_abs := abs(v_line.amount);

  -- ---------------- Settling an invoice or bill --------------------
  if v_kind = 'settle' then
    declare
      v_payload jsonb;
    begin
      v_payload := jsonb_build_object(
        'organisation_id', v_line.organisation_id,
        'ledger',          case when v_is_in then 'sales' else 'purchase' end,
        'contact_id',      p_config ->> 'contact_id',
        'bank_account_id', v_bank.account_id,
        'date',            v_line.date,
        'amount',          v_abs,
        'reference',       coalesce(nullif(p_config ->> 'reference', ''),
                                    v_line.reference, v_line.description)
      );

      -- Only send allocations when there are some. An empty array is not
      -- the same as "allocate these", and passing one would suppress
      -- automatic allocation.
      if jsonb_typeof(p_config -> 'allocations') = 'array'
         and jsonb_array_length(p_config -> 'allocations') > 0 then
        v_payload := v_payload || jsonb_build_object('allocations', p_config -> 'allocations');
      else
        v_payload := v_payload || jsonb_build_object('auto_allocate', true);
      end if;

      v_item := post_payment(v_payload);
    end;

    select journal_id into v_journal from ledger_item where id = v_item;

  -- ---------------- Transfer to another account -------------------
  elsif v_kind = 'transfer' then
    select account_id into v_target from bank_account
     where id = (p_config ->> 'to_bank_account_id')::uuid
       and organisation_id = v_line.organisation_id;

    if v_target is null then
      raise exception 'Choose the account the money went to'
        using errcode = 'no_data_found';
    end if;

    v_journal := post_journal(
      p_organisation_id => v_line.organisation_id,
      p_date            => v_line.date,
      p_description     => coalesce(nullif(p_config ->> 'description', ''),
                                    'Transfer — ' || v_line.description),
      p_lines           => jsonb_build_array(
        jsonb_build_object('account_id', v_bank.account_id,
          'description', v_line.description,
          'debit',  case when v_is_in then v_abs else 0 end,
          'credit', case when v_is_in then 0 else v_abs end),
        jsonb_build_object('account_id', v_target,
          'description', v_line.description,
          'debit',  case when v_is_in then 0 else v_abs end,
          'credit', case when v_is_in then v_abs else 0 end)
      ),
      p_reference       => v_line.reference,
      p_source_type     => 'bank_transfer',
      p_source_id       => p_line_id
    );

  -- ---------------- Straight to a category ------------------------
  else
    v_account := nullif(p_config ->> 'account_id', '')::uuid;
    v_vat := nullif(p_config ->> 'vat_code_id', '')::uuid;

    if v_account is null then
      raise exception 'Choose a category for this transaction'
        using errcode = 'check_violation';
    end if;

    -- The bank figure is gross, so VAT comes out of it rather than
    -- being added on. Getting this the wrong way round is the classic
    -- bank-coding error.
    if v_vat is not null then
      select rate, is_reverse_charge into v_rate, v_reverse
        from vat_code where id = v_vat;
    end if;

    if v_reverse then
      v_rate := 0;
    end if;

    v_net := round(v_abs / (1 + coalesce(v_rate, 0) / 100.0), 2);
    v_vat_amt := v_abs - v_net;

    select id into v_vat_acct from account
     where organisation_id = v_line.organisation_id
       and control_type = case when v_is_in then 'vat_output' else 'vat_input' end;

    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_bank.account_id,
        'description', v_line.description,
        'contact_id', nullif(p_config ->> 'contact_id', ''),
        'debit',  case when v_is_in then v_abs else 0 end,
        'credit', case when v_is_in then 0 else v_abs end),
      jsonb_build_object('account_id', v_account,
        'description', coalesce(nullif(p_config ->> 'description', ''), v_line.description),
        'contact_id', nullif(p_config ->> 'contact_id', ''),
        'vat_code_id', v_vat,
        'net_amount', v_net,
        'vat_amount', v_vat_amt,
        'debit',  case when v_is_in then 0 else v_net end,
        'credit', case when v_is_in then v_net else 0 end)
    );

    if v_vat_amt <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_vat_acct,
        'description', 'VAT',
        'debit',  case when v_is_in then 0 else v_vat_amt end,
        'credit', case when v_is_in then v_vat_amt else 0 end);
    end if;

    v_journal := post_journal(
      p_organisation_id => v_line.organisation_id,
      p_date            => v_line.date,
      p_description     => coalesce(nullif(p_config ->> 'description', ''), v_line.description),
      p_lines           => v_lines,
      p_reference       => v_line.reference,
      p_source_type     => case when v_is_in then 'bank_receipt' else 'bank_payment' end,
      p_source_id       => p_line_id
    );
  end if;

  -- Reconcile against the bank side of whatever was just posted.
  select id into v_bank_jl
    from journal_line
   where journal_id = v_journal
     and account_id = v_bank.account_id
   limit 1;

  perform match_statement_line(p_line_id, v_bank_jl);

  -- If a rule was used, count the hit so the useful ones float up.
  v_rule := nullif(p_config ->> 'rule_id', '')::uuid;
  if v_rule is not null then
    update match_rule
       set hit_count = hit_count + 1, last_used_at = now()
     where id = v_rule;
  end if;

  -- Optionally remember this coding as a rule for next time.
  if coalesce((p_config ->> 'remember')::boolean, false)
     and v_kind = 'nominal' then
    insert into match_rule (
      organisation_id, bank_account_id, name, match_type, pattern,
      direction, account_id, contact_id, vat_code_id
    ) values (
      v_line.organisation_id, v_line.bank_account_id,
      left(v_line.description, 60),
      'contains',
      -- The first few words are the stable part; card and reference
      -- numbers on the end change every time.
      left(regexp_replace(v_line.description, '\s+', ' ', 'g'), 20),
      case when v_is_in then 'in' else 'out' end,
      nullif(p_config ->> 'account_id', '')::uuid,
      nullif(p_config ->> 'contact_id', '')::uuid,
      nullif(p_config ->> 'vat_code_id', '')::uuid
    );
  end if;

  return v_journal;
end;
$$;

-- ---------------------------------------------------------------------
-- Reconciliation summary
--
-- The four figures that matter, and the difference between them.
-- ---------------------------------------------------------------------

create or replace function bank_reconciliation(
  p_bank_account_id uuid,
  p_as_at           date default null
) returns table (
  ledger_balance       numeric,
  reconciled_balance   numeric,
  unreconciled_total   numeric,
  unreconciled_count   int,
  statement_balance    numeric,
  unmatched_lines      int,
  unmatched_total      numeric,
  difference           numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_bank bank_account;
  v_as   date;
begin
  select * into v_bank from bank_account where id = p_bank_account_id;
  if not found then return; end if;

  v_as := coalesce(p_as_at, current_date);

  return query
  with jl as (
    select jl.debit, jl.credit, jl.reconciled_at
      from journal_line jl
      join journal j on j.id = jl.journal_id
     where jl.organisation_id = v_bank.organisation_id
       and jl.account_id = v_bank.account_id
       and j.date <= v_as
  ),
  sl as (
    select sl.amount, sl.status
      from statement_line sl
     where sl.bank_account_id = p_bank_account_id
       and sl.date <= v_as
  ),
  stmt as (
    select closing_balance
      from bank_statement
     where bank_account_id = p_bank_account_id
       and to_date <= v_as
       and closing_balance is not null
     order by to_date desc
     limit 1
  )
  select
    coalesce(sum(jl.debit - jl.credit), 0),
    coalesce(sum(case when jl.reconciled_at is not null then jl.debit - jl.credit else 0 end), 0),
    coalesce(sum(case when jl.reconciled_at is null then jl.debit - jl.credit else 0 end), 0),
    coalesce(count(*) filter (where jl.reconciled_at is null), 0)::int,
    (select closing_balance from stmt),
    (select count(*) from sl where sl.status = 'unmatched')::int,
    (select coalesce(sum(sl.amount), 0) from sl where sl.status = 'unmatched'),
    -- What the statement says, less what the ledger says. Should be nil
    -- once everything is matched.
    coalesce((select closing_balance from stmt), 0)
      - coalesce(sum(jl.debit - jl.credit), 0)
    from jl;
end;
$$;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------

do $$
declare r record;
begin
  for r in
    select tablename, policyname from pg_policies
     where schemaname = 'public'
       and tablename in ('bank_account', 'bank_statement', 'statement_line', 'match_rule')
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end;
$$;

alter table bank_account    enable row level security;
alter table bank_statement  enable row level security;
alter table statement_line  enable row level security;
alter table match_rule      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['bank_account', 'bank_statement', 'match_rule']
  loop
    execute format($f$
      create policy "members read %1$s" on %1$I
        for select to authenticated using (is_org_member(organisation_id));

      create policy "staff insert %1$s" on %1$I
        for insert to authenticated
        with check (has_org_role(organisation_id, array['owner','admin','bookkeeper']));

      create policy "staff update %1$s" on %1$I
        for update to authenticated
        using (has_org_role(organisation_id, array['owner','admin','bookkeeper']))
        with check (has_org_role(organisation_id, array['owner','admin','bookkeeper']));

      create policy "staff delete %1$s" on %1$I
        for delete to authenticated
        using (has_org_role(organisation_id, array['owner','admin','bookkeeper']));
    $f$, t);
  end loop;
end;
$$;

-- Statement lines are read only through the API. They are created by
-- import_statement() and only changed by the matching functions, because
-- a statement line whose status disagrees with the ledger is worse than
-- no statement line at all.
create policy "members read statement lines" on statement_line
  for select to authenticated using (is_org_member(organisation_id));

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

grant execute on function create_bank_account(jsonb) to authenticated;
grant execute on function import_statement(jsonb) to authenticated;
grant execute on function suggest_matches_for_line(uuid) to authenticated;
grant execute on function match_statement_line(uuid, uuid) to authenticated;
grant execute on function unmatch_statement_line(uuid) to authenticated;
grant execute on function exclude_statement_line(uuid, text) to authenticated;
grant execute on function create_from_statement_line(uuid, jsonb) to authenticated;
grant execute on function bank_reconciliation(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- Every bank nominal gets a bank_account row
--
-- Enforced by a trigger rather than by remembering to call a seed
-- function. The chart of accounts seeds four bank nominals at setup, and
-- anyone can add a fifth later; either way the banking screens find it.
--
-- create_bank_account() upserts, so it fills in the sort code and the
-- rest over the top of whatever the trigger created.
-- ---------------------------------------------------------------------

create or replace function ensure_bank_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_bank then
    insert into bank_account (organisation_id, account_id, name, type, currency_code)
    select new.organisation_id, new.id, coalesce(new.friendly_name, new.name),
           case
             when new.code = '1240' then 'credit_card'
             when new.code = '1230' then 'cash'
             when new.code = '1210' then 'savings'
             else 'current'
           end,
           o.base_currency_code
      from organisation o
     where o.id = new.organisation_id
    on conflict (organisation_id, account_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists account_ensure_bank_account on account;

create trigger account_ensure_bank_account
  after insert on account
  for each row execute function ensure_bank_account();

-- Backfill for organisations that existed before this migration.
insert into bank_account (organisation_id, account_id, name, type, currency_code)
select a.organisation_id, a.id, coalesce(a.friendly_name, a.name),
       case
         when a.code = '1240' then 'credit_card'
         when a.code = '1230' then 'cash'
         when a.code = '1210' then 'savings'
         else 'current'
       end,
       o.base_currency_code
  from account a
  join organisation o on o.id = a.organisation_id
 where a.is_bank
   and a.active
 on conflict (organisation_id, account_id) do nothing;

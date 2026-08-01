-- =====================================================================
-- 0011_fiscal_year.sql
--
-- Fixes the first financial year end.
--
-- The original rule was "the year end day and month, in the year the
-- books start, rolled forward if it has already passed". For a company
-- incorporated on 12 March 2026 with a 31 March year end that produced
-- a nineteen-day first year, which is wrong.
--
-- The real answer is genuinely ambiguous and the software should not
-- pretend otherwise. The same two inputs mean different things:
--
--   * A company incorporated on 12 March 2026 has a first Companies
--     House period ending 31 March 2027 — the last day of the month in
--     which the first anniversary falls. Around 12 and a half months.
--
--   * A business migrating from another system on 1 July 2026 with a
--     31 March year end wants a nine-month stub to 31 March 2027, not a
--     twenty-one month first year.
--
-- So: suggest a sensible default, show the user how long it is, and let
-- them change it. The rule for the default is that a first period of
-- under three months is almost never intended, so it rolls forward.
--
-- Later years are unambiguous and continue to be derived from the year
-- end day and month.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Date helpers
-- ---------------------------------------------------------------------

create or replace function month_end_day(p_year int, p_month int)
returns int
language sql
immutable
as $$
  select extract(day from
    (make_date(p_year, p_month, 1) + interval '1 month' - interval '1 day')
  )::int;
$$;

-- The year end falling in a given calendar year, clamped so that a
-- 31st year end still works in February.
create or replace function year_end_on(p_year int, p_day int, p_month int)
returns date
language sql
immutable
as $$
  select make_date(p_year, p_month, least(p_day, month_end_day(p_year, p_month)));
$$;

create or replace function suggest_first_year_end(
  p_start_date date,
  p_year_end_day int,
  p_year_end_month int
) returns date
language plpgsql
immutable
as $$
declare
  v_end date;
begin
  v_end := year_end_on(extract(year from p_start_date)::int, p_year_end_day, p_year_end_month);

  -- Already gone by the time the books start.
  if v_end < p_start_date then
    v_end := year_end_on(extract(year from p_start_date)::int + 1, p_year_end_day, p_year_end_month);
  end if;

  -- A first period of under three months is almost certainly not what
  -- was meant, so take the following year end instead.
  if v_end < p_start_date + interval '3 months' then
    v_end := year_end_on(extract(year from v_end)::int + 1, p_year_end_day, p_year_end_month);
  end if;

  return v_end;
end;
$$;

-- ---------------------------------------------------------------------
-- create_fiscal_year, now accepting an explicit end date
-- ---------------------------------------------------------------------

create or replace function create_fiscal_year(
  p_organisation_id uuid,
  p_start_date      date,
  p_end_date        date default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org      organisation;
  v_end      date;
  v_year_id  uuid;
  v_p_start  date;
  v_p_end    date;
  v_n        int := 1;
  v_months   numeric;
begin
  select * into v_org from organisation where id = p_organisation_id;

  if not found then
    raise exception 'That organisation does not exist' using errcode = 'no_data_found';
  end if;

  v_end := coalesce(
    p_end_date,
    suggest_first_year_end(p_start_date, v_org.year_end_day, v_org.year_end_month)
  );

  if v_end <= p_start_date then
    raise exception 'The year end must be after the start of the year'
      using errcode = 'check_violation';
  end if;

  -- Companies House allows a first accounting period of up to eighteen
  -- months. Beyond that something has been entered wrongly.
  -- Note: date minus date yields whole days, not an interval.
  v_months := (v_end - p_start_date) / 30.44;

  if v_months > 18.5 then
    raise exception
      'A financial year cannot run for longer than about eighteen months. % to % is roughly % months.',
      to_char(p_start_date, 'DD/MM/YYYY'),
      to_char(v_end, 'DD/MM/YYYY'),
      round(v_months)
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1 from fiscal_year
     where organisation_id = p_organisation_id
       and p_start_date <= end_date
       and v_end >= start_date
  ) then
    raise exception 'That overlaps a financial year that already exists'
      using errcode = 'unique_violation';
  end if;

  insert into fiscal_year (organisation_id, name, start_date, end_date)
  values (
    p_organisation_id,
    case
      when extract(year from v_end) <> extract(year from p_start_date)
        then to_char(p_start_date, 'YYYY') || '/' || to_char(v_end, 'YY')
      else to_char(v_end, 'YYYY')
    end,
    p_start_date, v_end
  )
  returning id into v_year_id;

  -- Monthly periods, tiling the year exactly. A year that is not a
  -- whole number of calendar months gets a short first period, which is
  -- usually what you want: it isolates the stub before trading settled
  -- into full months.
  v_p_start := p_start_date;

  while v_p_start <= v_end loop
    v_p_end := least(
      (date_trunc('month', v_p_start) + interval '1 month' - interval '1 day')::date,
      v_end
    );

    insert into period (
      organisation_id, fiscal_year_id, period_no, name, start_date, end_date
    ) values (
      p_organisation_id, v_year_id, v_n,
      to_char(v_p_start, 'Mon YYYY'), v_p_start, v_p_end
    );

    v_n := v_n + 1;
    v_p_start := v_p_end + 1;
  end loop;

  return v_year_id;
end;
$$;

-- ---------------------------------------------------------------------
-- create_organisation, now passing the chosen first year end through
-- ---------------------------------------------------------------------

create or replace function create_organisation(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id      uuid;
  v_user_id     uuid := auth.uid();
  v_books_start date;
  v_year_end    date;
begin
  if v_user_id is null then
    raise exception 'You must be signed in' using errcode = 'insufficient_privilege';
  end if;

  v_books_start := (p_config ->> 'books_start_date')::date;
  v_year_end    := nullif(p_config ->> 'first_year_end_date', '')::date;

  insert into organisation (
    name, trading_name, entity_type_code, base_currency_code,
    year_end_day, year_end_month, books_start_date,
    address_line_1, address_line_2, city, county, postcode, country,
    company_number, utr, vat_number, charity_number,
    email, phone, website, created_by, setup_completed_at
  ) values (
    p_config ->> 'name',
    nullif(p_config ->> 'trading_name', ''),
    p_config ->> 'entity_type_code',
    coalesce(nullif(p_config ->> 'base_currency_code', ''), 'GBP'),
    (p_config ->> 'year_end_day')::int,
    (p_config ->> 'year_end_month')::int,
    v_books_start,
    nullif(p_config ->> 'address_line_1', ''),
    nullif(p_config ->> 'address_line_2', ''),
    nullif(p_config ->> 'city', ''),
    nullif(p_config ->> 'county', ''),
    nullif(p_config ->> 'postcode', ''),
    coalesce(nullif(p_config ->> 'country', ''), 'United Kingdom'),
    nullif(p_config ->> 'company_number', ''),
    nullif(p_config ->> 'utr', ''),
    nullif(p_config ->> 'vat_number', ''),
    nullif(p_config ->> 'charity_number', ''),
    nullif(p_config ->> 'email', ''),
    nullif(p_config ->> 'phone', ''),
    nullif(p_config ->> 'website', ''),
    v_user_id,
    now()
  )
  returning id into v_org_id;

  insert into organisation_user (organisation_id, user_id, role)
  values (v_org_id, v_user_id, 'owner');

  insert into organisation_feature (
    organisation_id,
    vat_enabled, vat_scheme, flat_rate_percent, vat_registered_from,
    vat_return_frequency,
    holds_stock, stock_control_enabled, stock_valuation,
    multicurrency_enabled, departments_enabled, accountant_mode,
    show_nominal_codes
  ) values (
    v_org_id,
    coalesce((p_config ->> 'vat_enabled')::boolean, false),
    coalesce(nullif(p_config ->> 'vat_scheme', ''), 'standard'),
    nullif(p_config ->> 'flat_rate_percent', '')::numeric,
    nullif(p_config ->> 'vat_registered_from', '')::date,
    coalesce(nullif(p_config ->> 'vat_return_frequency', ''), 'quarterly'),
    coalesce((p_config ->> 'holds_stock')::boolean, false),
    coalesce((p_config ->> 'stock_control_enabled')::boolean, false),
    coalesce(nullif(p_config ->> 'stock_valuation', ''), 'fifo'),
    coalesce((p_config ->> 'multicurrency_enabled')::boolean, false),
    coalesce((p_config ->> 'departments_enabled')::boolean, false),
    coalesce((p_config ->> 'accountant_mode')::boolean, false),
    coalesce((p_config ->> 'accountant_mode')::boolean, false)
  );

  perform seed_chart_of_accounts(v_org_id, p_config ->> 'entity_type_code');
  perform seed_vat_codes(v_org_id);
  perform apply_default_vat_codes(v_org_id);
  perform create_fiscal_year(v_org_id, v_books_start, v_year_end);

  insert into number_sequence (organisation_id, sequence_type, prefix, next_number) values
    (v_org_id, 'sales_invoice',    'INV', 1),
    (v_org_id, 'sales_credit',     'CRN', 1),
    (v_org_id, 'quote',            'QUO', 1),
    (v_org_id, 'purchase_order',   'PO',  1),
    (v_org_id, 'customer',         'C',   1),
    (v_org_id, 'supplier',         'S',   1),
    (v_org_id, 'product',          'P',   1);

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_org_id, v_user_id, 'organisation', v_org_id::text, 'created', p_config);

  return v_org_id;
end;
$$;

grant execute on function suggest_first_year_end(date, int, int) to authenticated;
grant execute on function year_end_on(int, int, int) to authenticated;
grant execute on function month_end_day(int, int) to authenticated;
grant execute on function create_fiscal_year(uuid, date, date) to authenticated;
grant execute on function create_organisation(jsonb) to authenticated;

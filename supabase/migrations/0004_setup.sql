-- =====================================================================
-- 0004_setup.sql
-- Chart of accounts seeding and the one-call organisation setup.
--
-- The nominal code ranges follow the layout UK bookkeepers already
-- know (0xxx fixed assets, 1xxx current assets, 2xxx liabilities,
-- 3xxx capital, 4xxx sales, 5xxx cost of sales, 6xxx direct expenses,
-- 7xxx overheads, 8xxx depreciation, 9xxx reserves and suspense).
--
-- Every account also carries a friendly_name. When accountant mode is
-- off the interface shows the friendly name and hides the code
-- entirely, so a non-accountant picks "Rent" rather than "7100".
-- =====================================================================

create or replace function seed_chart_of_accounts(
  p_organisation_id uuid,
  p_entity_type     text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_capital_model text;
begin
  select capital_model into v_capital_model
    from entity_type where code = p_entity_type;

  -- ---------------- Fixed assets (0xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code, is_system) values
    (p_organisation_id, '0010', 'Freehold property',            'Property you own',        'fixed_asset_tangible', false),
    (p_organisation_id, '0020', 'Leasehold property',           'Leased premises',         'fixed_asset_tangible', false),
    (p_organisation_id, '0030', 'Plant and machinery',          'Machinery and equipment', 'fixed_asset_tangible', false),
    (p_organisation_id, '0040', 'Fixtures and fittings',        'Furniture and fittings',  'fixed_asset_tangible', false),
    (p_organisation_id, '0050', 'Motor vehicles',               'Vehicles',                'fixed_asset_tangible', false),
    (p_organisation_id, '0060', 'Computer equipment',           'Computers',               'fixed_asset_tangible', false),
    (p_organisation_id, '0070', 'Goodwill',                     'Goodwill',                'fixed_asset_intangible', false),
    (p_organisation_id, '0080', 'Software and licences',        'Software',                'fixed_asset_intangible', false),
    (p_organisation_id, '0031', 'Plant and machinery depreciation',   'Machinery wear and tear', 'depreciation_provision', false),
    (p_organisation_id, '0041', 'Fixtures and fittings depreciation', 'Fittings wear and tear',  'depreciation_provision', false),
    (p_organisation_id, '0051', 'Motor vehicles depreciation',        'Vehicle wear and tear',   'depreciation_provision', false),
    (p_organisation_id, '0061', 'Computer equipment depreciation',    'Computer wear and tear',  'depreciation_provision', false);

  -- ---------------- Current assets (1xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code, is_control, control_type, is_bank, is_system) values
    (p_organisation_id, '1000', 'Stock',                     'Stock',                'stock',               true,  'stock',            false, true),
    (p_organisation_id, '1100', 'Trade debtors',             'Money owed to you',    'debtors',             true,  'debtors',          false, true),
    (p_organisation_id, '1150', 'Prepayments',               'Paid in advance',      'other_current_asset', false, null,               false, false),
    (p_organisation_id, '1200', 'Bank current account',      'Bank account',         'bank',                false, null,               true,  false),
    (p_organisation_id, '1210', 'Bank deposit account',      'Savings account',      'bank',                false, null,               true,  false),
    (p_organisation_id, '1230', 'Petty cash',                'Cash in hand',         'bank',                false, null,               true,  false),
    (p_organisation_id, '1240', 'Credit card',               'Credit card',          'bank',                false, null,               true,  false),
    (p_organisation_id, '1270', 'Money in transit',          'Money moving between accounts', 'other_current_asset', false, null,      false, true);

  -- ---------------- Liabilities (2xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code, is_control, control_type, is_system) values
    (p_organisation_id, '2100', 'Trade creditors',       'Money you owe',           'creditors',                true,  'creditors',  true),
    (p_organisation_id, '2109', 'Accruals',              'Costs not yet billed',    'other_current_liability',  false, null,         false),
    (p_organisation_id, '2200', 'VAT on sales',          'VAT you have charged',    'vat_liability',            true,  'vat_output', true),
    (p_organisation_id, '2201', 'VAT on purchases',      'VAT you have paid',       'vat_liability',            true,  'vat_input',  true),
    (p_organisation_id, '2202', 'VAT liability',         'VAT owed to HMRC',        'vat_liability',            true,  'vat',        true),
    (p_organisation_id, '2210', 'PAYE and NI',           'Payroll tax owed',        'tax_liability',            false, null,         false),
    (p_organisation_id, '2230', 'Pension contributions', 'Pension owed',            'other_current_liability',  false, null,         false),
    (p_organisation_id, '2300', 'Loans',                 'Loans',                   'long_term_liability',      false, null,         false),
    (p_organisation_id, '2310', 'Hire purchase',         'Hire purchase',           'long_term_liability',      false, null,         false),
    (p_organisation_id, '2320', 'Directors loan account', 'Director''s loan',       'other_current_liability',  false, null,         false);

  -- Corporation tax only makes sense for a company
  if v_capital_model = 'shareholder' then
    insert into account (organisation_id, code, name, friendly_name, account_type_code) values
      (p_organisation_id, '2220', 'Corporation tax', 'Corporation tax owed', 'tax_liability');
  end if;

  -- ---------------- Capital (3xxx) ----------------
  if v_capital_model = 'shareholder' then
    insert into account (organisation_id, code, name, friendly_name, account_type_code, is_control, control_type, is_system) values
      (p_organisation_id, '3000', 'Ordinary share capital', 'Share capital',            'capital',           false, null,                false),
      (p_organisation_id, '3200', 'Retained earnings',      'Profit kept in the business','retained_earnings', true, 'retained_earnings', true),
      (p_organisation_id, '3260', 'Dividends',              'Dividends paid',           'drawings',          false, null,                false);
  elsif v_capital_model = 'members' then
    insert into account (organisation_id, code, name, friendly_name, account_type_code, is_control, control_type, is_system) values
      (p_organisation_id, '3000', 'Members capital',        'Members'' capital',        'capital',           false, null,                false),
      (p_organisation_id, '3200', 'Undrawn profits',        'Profit kept in the business','retained_earnings', true, 'retained_earnings', true),
      (p_organisation_id, '3260', 'Members drawings',       'Money taken out',          'drawings',          true,  'drawings',          false);
  elsif v_capital_model = 'fund' then
    insert into account (organisation_id, code, name, friendly_name, account_type_code, is_control, control_type, is_system) values
      (p_organisation_id, '3000', 'Unrestricted funds',     'General funds',            'capital',           false, null,                false),
      (p_organisation_id, '3100', 'Restricted funds',       'Restricted funds',         'capital',           false, null,                false),
      (p_organisation_id, '3200', 'Accumulated funds',      'Funds carried forward',    'retained_earnings', true,  'retained_earnings', true);
  else
    insert into account (organisation_id, code, name, friendly_name, account_type_code, is_control, control_type, is_system) values
      (p_organisation_id, '3000', 'Capital introduced',     'Money you put in',         'capital',           false, null,                false),
      (p_organisation_id, '3200', 'Retained profit',        'Profit kept in the business','retained_earnings', true, 'retained_earnings', true),
      (p_organisation_id, '3260', 'Drawings',               'Money you take out',       'drawings',          true,  'drawings',          false);
  end if;

  -- ---------------- Sales (4xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code) values
    (p_organisation_id, '4000', 'Sales',                'Sales',                  'sales'),
    (p_organisation_id, '4001', 'Sales - services',     'Services sold',          'sales'),
    (p_organisation_id, '4002', 'Sales - goods',        'Goods sold',             'sales'),
    (p_organisation_id, '4009', 'Discounts allowed',    'Discounts you gave',     'sales'),
    (p_organisation_id, '4900', 'Other income',         'Other money coming in',  'other_income'),
    (p_organisation_id, '4906', 'Bank interest received','Interest received',     'other_income');

  -- ---------------- Cost of sales (5xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code) values
    (p_organisation_id, '5000', 'Purchases',            'Things you buy to sell', 'cost_of_sales'),
    (p_organisation_id, '5001', 'Materials',            'Materials',              'cost_of_sales'),
    (p_organisation_id, '5002', 'Subcontractors',       'Subcontractors',         'cost_of_sales'),
    (p_organisation_id, '5009', 'Discounts received',   'Discounts you received', 'cost_of_sales'),
    (p_organisation_id, '5100', 'Carriage',             'Delivery costs',         'cost_of_sales'),
    (p_organisation_id, '5200', 'Opening stock',        'Stock at the start',     'cost_of_sales'),
    (p_organisation_id, '5201', 'Closing stock',        'Stock at the end',       'cost_of_sales');

  -- ---------------- Direct expenses (6xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code) values
    (p_organisation_id, '6000', 'Productive labour',    'Staff on jobs',          'direct_expense'),
    (p_organisation_id, '6200', 'Sales promotion',      'Promotion',              'direct_expense'),
    (p_organisation_id, '6201', 'Advertising',          'Advertising',            'direct_expense');

  -- ---------------- Overheads (7xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code) values
    (p_organisation_id, '7000', 'Wages and salaries',       'Wages',                  'overhead'),
    (p_organisation_id, '7006', 'Employers NI',             'Employer''s NI',         'overhead'),
    (p_organisation_id, '7007', 'Employers pension',        'Employer''s pension',    'overhead'),
    (p_organisation_id, '7100', 'Rent',                     'Rent',                   'overhead'),
    (p_organisation_id, '7102', 'Water rates',              'Water',                  'overhead'),
    (p_organisation_id, '7103', 'Business rates',           'Business rates',         'overhead'),
    (p_organisation_id, '7200', 'Electricity',              'Electricity',            'overhead'),
    (p_organisation_id, '7201', 'Gas',                      'Gas',                    'overhead'),
    (p_organisation_id, '7300', 'Fuel and oil',             'Fuel',                   'overhead'),
    (p_organisation_id, '7301', 'Vehicle repairs',          'Vehicle repairs',        'overhead'),
    (p_organisation_id, '7303', 'Vehicle insurance',        'Vehicle insurance',      'overhead'),
    (p_organisation_id, '7304', 'Vehicle licences',         'Road tax',               'overhead'),
    (p_organisation_id, '7400', 'Travel',                   'Travel',                 'overhead'),
    (p_organisation_id, '7402', 'Subsistence',              'Meals while working',    'overhead'),
    (p_organisation_id, '7403', 'Entertaining',             'Entertaining',           'overhead'),
    (p_organisation_id, '7500', 'Printing and stationery',  'Printing and stationery','overhead'),
    (p_organisation_id, '7501', 'Postage',                  'Postage',                'overhead'),
    (p_organisation_id, '7502', 'Telephone and broadband',  'Phone and internet',     'overhead'),
    (p_organisation_id, '7504', 'Software subscriptions',   'Software',               'overhead'),
    (p_organisation_id, '7600', 'Legal fees',               'Legal fees',             'overhead'),
    (p_organisation_id, '7601', 'Accountancy fees',         'Accountancy fees',       'overhead'),
    (p_organisation_id, '7602', 'Consultancy fees',         'Consultants',            'overhead'),
    (p_organisation_id, '7700', 'Equipment hire',           'Equipment hire',         'overhead'),
    (p_organisation_id, '7701', 'Repairs and maintenance',  'Repairs',                'overhead'),
    (p_organisation_id, '7800', 'Cleaning',                 'Cleaning',               'overhead'),
    (p_organisation_id, '7801', 'Insurance',                'Insurance',              'overhead'),
    (p_organisation_id, '7802', 'Training',                 'Training',               'overhead'),
    (p_organisation_id, '7803', 'Subscriptions',            'Memberships',            'overhead'),
    (p_organisation_id, '7900', 'Bank charges',             'Bank charges',           'finance_cost'),
    (p_organisation_id, '7901', 'Loan interest',            'Interest paid',          'finance_cost'),
    (p_organisation_id, '7902', 'Credit card charges',      'Card charges',           'finance_cost'),
    (p_organisation_id, '7950', 'Bad debts written off',    'Unpaid invoices written off', 'overhead');

  -- ---------------- Depreciation and tax (8xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code) values
    (p_organisation_id, '8000', 'Depreciation',             'Wear and tear this year','depreciation_expense'),
    (p_organisation_id, '8100', 'Profit or loss on disposal','Profit on selling assets','other_income');

  if v_capital_model = 'shareholder' then
    insert into account (organisation_id, code, name, friendly_name, account_type_code) values
      (p_organisation_id, '8500', 'Corporation tax', 'Corporation tax', 'taxation');
  end if;

  -- ---------------- Housekeeping (9xxx) ----------------
  insert into account (organisation_id, code, name, friendly_name, account_type_code, is_control, control_type, is_system) values
    (p_organisation_id, '9998', 'Suspense',               'Not yet sorted',      'suspense',      true, 'suspense',            true),
    (p_organisation_id, '9997', 'Opening balances',       'Opening balances',    'suspense',      true, 'opening_balance',     true),
    (p_organisation_id, '9996', 'Exchange differences',   'Currency differences','finance_cost',  true, 'exchange_difference', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Financial year generation
--
-- Given a year end day/month, build the year containing p_start and
-- its twelve monthly periods. Called at setup and again each year end.
-- ---------------------------------------------------------------------

create or replace function create_fiscal_year(
  p_organisation_id uuid,
  p_start_date      date
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org        organisation;
  v_end        date;
  v_year_id    uuid;
  v_p_start    date;
  v_p_end      date;
  v_n          int := 1;
begin
  select * into v_org from organisation where id = p_organisation_id;

  -- Year end is the configured day/month on or after the start date.
  v_end := make_date(
    extract(year from p_start_date)::int, v_org.year_end_month,
    least(v_org.year_end_day,
          extract(day from (make_date(extract(year from p_start_date)::int,
                                      v_org.year_end_month, 1)
                            + interval '1 month - 1 day'))::int)
  );

  if v_end < p_start_date then
    v_end := (v_end + interval '1 year')::date;
  end if;

  insert into fiscal_year (organisation_id, name, start_date, end_date)
  values (
    p_organisation_id,
    to_char(p_start_date, 'YYYY') ||
      case when extract(year from v_end) <> extract(year from p_start_date)
           then '/' || to_char(v_end, 'YY') else '' end,
    p_start_date, v_end
  )
  returning id into v_year_id;

  -- Monthly periods. The final period absorbs any short or long stub
  -- so the periods always tile the year exactly.
  v_p_start := p_start_date;
  while v_p_start <= v_end loop
    v_p_end := least((date_trunc('month', v_p_start) + interval '1 month - 1 day')::date, v_end);

    insert into period (organisation_id, fiscal_year_id, period_no, name, start_date, end_date)
    values (p_organisation_id, v_year_id, v_n,
            to_char(v_p_start, 'Mon YYYY'), v_p_start, v_p_end);

    v_n := v_n + 1;
    v_p_start := v_p_end + 1;
  end loop;

  return v_year_id;
end;
$$;

-- ---------------------------------------------------------------------
-- create_organisation
--
-- Everything the setup wizard needs, in one atomic call. Either the
-- whole organisation exists correctly or none of it does.
-- ---------------------------------------------------------------------

create or replace function create_organisation(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id     uuid;
  v_user_id    uuid := auth.uid();
  v_books_start date;
begin
  if v_user_id is null then
    raise exception 'You must be signed in' using errcode = 'insufficient_privilege';
  end if;

  v_books_start := (p_config ->> 'books_start_date')::date;

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
  perform create_fiscal_year(v_org_id, v_books_start);

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

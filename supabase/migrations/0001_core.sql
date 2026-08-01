-- =====================================================================
-- 0001_core.sql
-- Tenancy, reference data and per-organisation configuration.
--
-- Design notes:
--   * Every business table carries organisation_id. This is a
--     multi-tenant schema from day one because retrofitting tenancy is
--     the single most expensive change you can make to a ledger.
--   * Entity types and currencies are lookup TABLES, not enums, so new
--     ones can be added without a migration.
--   * Optional features (VAT, stock, multi-currency, departments) are
--     flags. The schema always carries the columns; the interface hides
--     them until the flag is on. Turning a feature on later must never
--     require a data migration.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Reference data (global, not per-organisation)
-- ---------------------------------------------------------------------

create table entity_type (
  code          text primary key,
  name          text not null,
  description   text,
  -- Drives the capital section of the balance sheet and the year-end
  -- close routine: a sole trader's profit goes to capital/drawings, a
  -- company's goes to retained earnings.
  capital_model text not null check (capital_model in ('proprietor', 'shareholder', 'members', 'fund')),
  sort_order    int not null default 0
);

insert into entity_type (code, name, description, capital_model, sort_order) values
  ('sole_trader',     'Sole trader',      'One self-employed individual',                'proprietor',  10),
  ('partnership',     'Partnership',      'Two or more individuals in business together','proprietor',  20),
  ('limited_company', 'Limited company',  'A company registered at Companies House',     'shareholder', 30),
  ('llp',             'Limited liability partnership', 'An LLP registered at Companies House', 'members', 40),
  ('charity',         'Charity',          'A charity or not-for-profit',                 'fund',        50);

create table currency (
  code        text primary key,
  name        text not null,
  symbol      text not null,
  minor_units int  not null default 2,
  sort_order  int  not null default 100
);

insert into currency (code, name, symbol, sort_order) values
  ('GBP', 'Pound sterling',  '£', 1),
  ('EUR', 'Euro',            '€', 2),
  ('USD', 'US dollar',       '$', 3),
  ('AUD', 'Australian dollar', 'A$', 10),
  ('CAD', 'Canadian dollar', 'C$', 10),
  ('CHF', 'Swiss franc',     'CHF', 10),
  ('JPY', 'Japanese yen',    '¥', 10),
  ('NZD', 'New Zealand dollar', 'NZ$', 10),
  ('SEK', 'Swedish krona',   'kr', 10),
  ('NOK', 'Norwegian krone', 'kr', 10),
  ('DKK', 'Danish krone',    'kr', 10),
  ('PLN', 'Polish zloty',    'zł', 10),
  ('ZAR', 'South African rand', 'R', 10),
  ('INR', 'Indian rupee',    '₹', 10),
  ('AED', 'UAE dirham',      'AED', 10);

update currency set minor_units = 0 where code = 'JPY';

-- ---------------------------------------------------------------------
-- Organisations
-- ---------------------------------------------------------------------

create table organisation (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null,
  trading_name       text,
  entity_type_code   text not null references entity_type(code),
  base_currency_code text not null references currency(code) default 'GBP',

  -- Year end is captured as day + month so it rolls forward for ever
  -- without the user re-entering it each year.
  year_end_day       int not null check (year_end_day between 1 and 31),
  year_end_month     int not null check (year_end_month between 1 and 12),
  books_start_date   date not null,

  address_line_1     text,
  address_line_2     text,
  city               text,
  county             text,
  postcode           text,
  country            text default 'United Kingdom',

  company_number     text,
  utr                text,
  vat_number         text,
  charity_number     text,

  email              text,
  phone              text,
  website            text,
  logo_path          text,

  setup_completed_at timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid not null references auth.users(id)
);

create index organisation_created_by_idx on organisation (created_by);

create table organisation_user (
  organisation_id uuid not null references organisation(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  role            text not null default 'owner'
                    check (role in ('owner', 'admin', 'bookkeeper', 'viewer')),
  display_name    text,
  invited_at      timestamptz,
  accepted_at     timestamptz default now(),
  created_at      timestamptz not null default now(),
  primary key (organisation_id, user_id)
);

create index organisation_user_user_idx on organisation_user (user_id);

-- ---------------------------------------------------------------------
-- Feature configuration
--
-- Chosen at setup, changeable at any time. Nothing here alters the
-- shape of the database; it only alters what the interface offers and
-- which posting paths are available.
-- ---------------------------------------------------------------------

create table organisation_feature (
  organisation_id       uuid primary key references organisation(id) on delete cascade,

  -- VAT ------------------------------------------------------------
  vat_enabled           boolean not null default false,
  vat_scheme            text    not null default 'standard'
                          check (vat_scheme in ('standard', 'cash', 'flat_rate')),
  flat_rate_percent     numeric(5,2),
  vat_registered_from   date,
  vat_return_frequency  text    not null default 'quarterly'
                          check (vat_return_frequency in ('monthly', 'quarterly', 'annual')),
  vat_first_period_end  date,

  -- Stock ----------------------------------------------------------
  -- holds_stock: the business owns stock (may still track it on paper)
  -- stock_control_enabled: track it in this software
  holds_stock           boolean not null default false,
  stock_control_enabled boolean not null default false,
  stock_valuation       text    not null default 'fifo'
                          check (stock_valuation in ('fifo', 'average')),

  -- Currency -------------------------------------------------------
  multicurrency_enabled boolean not null default false,

  -- Analysis -------------------------------------------------------
  departments_enabled   boolean not null default false,
  projects_enabled      boolean not null default false,

  -- Interface ------------------------------------------------------
  -- Off by default: hides nominal codes, journals and debit/credit
  -- language from people who do not want to see them.
  accountant_mode       boolean not null default false,
  show_nominal_codes    boolean not null default false,

  updated_at            timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Document numbering
-- ---------------------------------------------------------------------

create table number_sequence (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  sequence_type   text not null,
  prefix          text not null default '',
  next_number     bigint not null default 1,
  padding         int not null default 4,
  unique (organisation_id, sequence_type)
);

-- Atomically claim the next number in a sequence.
create or replace function next_document_number(
  p_organisation_id uuid,
  p_sequence_type   text
) returns text
language plpgsql
as $$
declare
  v_prefix  text;
  v_number  bigint;
  v_padding int;
begin
  update number_sequence
     set next_number = next_number + 1
   where organisation_id = p_organisation_id
     and sequence_type   = p_sequence_type
  returning prefix, next_number - 1, padding
       into v_prefix, v_number, v_padding;

  if not found then
    raise exception 'No % sequence configured for this organisation', p_sequence_type
      using errcode = 'no_data_found';
  end if;

  return v_prefix || lpad(v_number::text, v_padding, '0');
end;
$$;

-- ---------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------

create table audit_log (
  id              bigserial primary key,
  organisation_id uuid references organisation(id) on delete cascade,
  user_id         uuid references auth.users(id),
  table_name      text not null,
  record_id       text,
  action          text not null,
  detail          jsonb,
  created_at      timestamptz not null default now()
);

create index audit_log_org_created_idx on audit_log (organisation_id, created_at desc);

-- ---------------------------------------------------------------------
-- Membership helper
--
-- Defined here because every RLS policy and every posting function
-- depends on it. SECURITY DEFINER so that the policy on
-- organisation_user does not recurse into itself.
-- ---------------------------------------------------------------------

create or replace function is_org_member(p_organisation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from organisation_user
     where organisation_id = p_organisation_id
       and user_id = auth.uid()
  );
$$;

create or replace function has_org_role(p_organisation_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from organisation_user
     where organisation_id = p_organisation_id
       and user_id = auth.uid()
       and role = any(p_roles)
  );
$$;

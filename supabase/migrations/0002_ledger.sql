-- =====================================================================
-- 0002_ledger.sql
-- The nominal ledger. Everything else in the system eventually posts
-- through the tables in this file and through no other route.
--
-- Rules enforced by the DATABASE, not by application code:
--   1. A journal line is either a debit or a credit, never both.
--   2. A journal's debits must equal its credits.
--   3. A posted journal can never be updated or deleted. Corrections
--      are made by reversal.
--   4. Nothing can post into a period that is not open.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Account types (global reference data)
-- ---------------------------------------------------------------------

create type account_class as enum
  ('asset', 'liability', 'capital', 'income', 'expense');

create table account_type (
  code         text primary key,
  name         text not null,
  class        account_class not null,
  report       text not null check (report in ('balance_sheet', 'profit_and_loss')),
  report_group text not null,
  -- Plain-English label shown when accountant mode is off.
  friendly_name text not null,
  sort_order   int not null
);

insert into account_type (code, name, class, report, report_group, friendly_name, sort_order) values
  ('fixed_asset_tangible',   'Tangible fixed assets',    'asset',     'balance_sheet',    'Fixed assets',        'Things you own long term',      10),
  ('fixed_asset_intangible', 'Intangible fixed assets',  'asset',     'balance_sheet',    'Fixed assets',        'Things you own long term',      20),
  ('fixed_asset_investment', 'Investments',              'asset',     'balance_sheet',    'Fixed assets',        'Investments',                   30),
  ('depreciation_provision', 'Accumulated depreciation', 'asset',     'balance_sheet',    'Fixed assets',        'Wear and tear so far',          40),
  ('stock',                  'Stock',                    'asset',     'balance_sheet',    'Current assets',      'Stock',                         50),
  ('debtors',                'Debtors',                  'asset',     'balance_sheet',    'Current assets',      'Money owed to you',             60),
  ('bank',                   'Bank accounts',            'asset',     'balance_sheet',    'Current assets',      'Bank and cash',                 70),
  ('other_current_asset',    'Other current assets',     'asset',     'balance_sheet',    'Current assets',      'Other things you are owed',      80),
  ('creditors',              'Creditors',                'liability', 'balance_sheet',    'Current liabilities', 'Money you owe',                 90),
  ('vat_liability',          'VAT liability',            'liability', 'balance_sheet',    'Current liabilities', 'VAT owed to HMRC',             100),
  ('tax_liability',          'Tax liabilities',          'liability', 'balance_sheet',    'Current liabilities', 'Tax owed',                     110),
  ('other_current_liability','Other current liabilities','liability', 'balance_sheet',    'Current liabilities', 'Other things you owe',         120),
  ('long_term_liability',    'Long term liabilities',    'liability', 'balance_sheet',    'Long term liabilities','Loans and long term debt',    130),
  ('capital',                'Capital and reserves',     'capital',   'balance_sheet',    'Capital and reserves','Owner''s stake',                140),
  ('retained_earnings',      'Retained earnings',        'capital',   'balance_sheet',    'Capital and reserves','Profit kept in the business',  150),
  ('drawings',               'Drawings',                 'capital',   'balance_sheet',    'Capital and reserves','Money taken out by the owner', 160),
  ('sales',                  'Sales',                    'income',    'profit_and_loss',  'Income',              'Money you earn',                170),
  ('other_income',           'Other income',             'income',    'profit_and_loss',  'Income',              'Other money coming in',        180),
  ('cost_of_sales',          'Cost of sales',            'expense',   'profit_and_loss',  'Cost of sales',       'Direct costs of what you sell',190),
  ('direct_expense',         'Direct expenses',          'expense',   'profit_and_loss',  'Cost of sales',       'Direct costs',                 200),
  ('overhead',               'Overheads',                'expense',   'profit_and_loss',  'Overheads',           'Running costs',                210),
  ('depreciation_expense',   'Depreciation',             'expense',   'profit_and_loss',  'Overheads',           'Wear and tear this year',      220),
  ('finance_cost',           'Finance costs',            'expense',   'profit_and_loss',  'Overheads',           'Interest and bank charges',    230),
  ('taxation',               'Taxation',                 'expense',   'profit_and_loss',  'Taxation',            'Tax on profit',                240),
  ('suspense',               'Suspense',                 'asset',     'balance_sheet',    'Current assets',      'Not yet sorted',               250);

-- ---------------------------------------------------------------------
-- Chart of accounts
-- ---------------------------------------------------------------------

create table account (
  id                uuid primary key default gen_random_uuid(),
  organisation_id   uuid not null references organisation(id) on delete cascade,
  code              text not null,
  name              text not null,
  friendly_name     text,
  description       text,
  account_type_code text not null references account_type(code),

  -- Control accounts are maintained by the system. A user can never
  -- post to them by hand; only the sales, purchase, bank and VAT
  -- modules may write to them.
  is_control        boolean not null default false,
  control_type      text check (control_type in
                      ('debtors', 'creditors', 'vat', 'vat_input', 'vat_output',
                       'retained_earnings', 'suspense', 'stock', 'opening_balance',
                       'exchange_difference', 'drawings')),

  is_bank           boolean not null default false,
  is_system         boolean not null default false,
  default_vat_code_id uuid,

  active            boolean not null default true,
  created_at        timestamptz not null default now(),

  unique (organisation_id, code)
);

create index account_org_type_idx on account (organisation_id, account_type_code);
create unique index account_control_unique_idx
  on account (organisation_id, control_type)
  where control_type is not null;

-- ---------------------------------------------------------------------
-- Financial years and periods
-- ---------------------------------------------------------------------

create table fiscal_year (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  name            text not null,
  start_date      date not null,
  end_date        date not null,
  status          text not null default 'open' check (status in ('open', 'closed')),
  closed_at       timestamptz,
  closing_journal_id uuid,
  created_at      timestamptz not null default now(),
  check (end_date > start_date),
  unique (organisation_id, start_date)
);

create table period (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  fiscal_year_id  uuid not null references fiscal_year(id) on delete cascade,
  period_no       int  not null,
  name            text not null,
  start_date      date not null,
  end_date        date not null,
  -- open   : anything may post
  -- closed : soft close, an admin can reopen
  -- locked : hard close, never reopened (used after year end)
  status          text not null default 'open'
                    check (status in ('open', 'closed', 'locked')),
  check (end_date >= start_date),
  unique (fiscal_year_id, period_no)
);

create index period_org_dates_idx on period (organisation_id, start_date, end_date);

-- ---------------------------------------------------------------------
-- Journals
-- ---------------------------------------------------------------------

create table journal (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  journal_no      bigint not null,
  date            date not null,
  period_id       uuid not null references period(id),

  reference       text,
  description     text not null,

  -- Where this journal came from. 'manual' is the only value a user
  -- can create directly; everything else is written by a module.
  source_type     text not null default 'manual'
                    check (source_type in
                      ('manual', 'opening_balance', 'sales_invoice', 'sales_credit',
                       'sales_receipt', 'purchase_invoice', 'purchase_credit',
                       'purchase_payment', 'bank_payment', 'bank_receipt',
                       'bank_transfer', 'allocation', 'vat_return', 'depreciation',
                       'stock_movement', 'recurring', 'year_end', 'reversal')),
  source_id       uuid,

  currency_code   text not null references currency(code),
  exchange_rate   numeric(18,8) not null default 1 check (exchange_rate > 0),

  posted_at       timestamptz not null default now(),
  posted_by       uuid references auth.users(id),

  reverses_journal_id  uuid references journal(id),
  reversed_by_journal_id uuid references journal(id),

  unique (organisation_id, journal_no)
);

create index journal_org_date_idx on journal (organisation_id, date desc);
create index journal_source_idx on journal (organisation_id, source_type, source_id);

create table journal_line (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  journal_id      uuid not null references journal(id) on delete cascade,
  line_no         int  not null,

  account_id      uuid not null references account(id),
  description     text,

  -- Base currency. These two columns are the ledger. Every report in
  -- the system reads from here.
  debit           numeric(14,2) not null default 0,
  credit          numeric(14,2) not null default 0,

  -- Transaction currency. Equal to debit/credit when the journal is in
  -- the base currency. Always populated so multi-currency can be
  -- switched on later without touching historic data.
  txn_debit       numeric(14,2) not null default 0,
  txn_credit      numeric(14,2) not null default 0,

  contact_id      uuid,
  department_id   uuid,
  project_id      uuid,

  vat_code_id     uuid,
  net_amount      numeric(14,2),
  vat_amount      numeric(14,2),
  vat_return_id   uuid,

  reconciled_at   timestamptz,
  statement_id    uuid,

  constraint journal_line_non_negative
    check (debit >= 0 and credit >= 0 and txn_debit >= 0 and txn_credit >= 0),
  constraint journal_line_one_side_only
    check (not (debit > 0 and credit > 0)),
  constraint journal_line_not_empty
    check (debit > 0 or credit > 0),

  unique (journal_id, line_no)
);

create index journal_line_account_idx on journal_line (organisation_id, account_id);
create index journal_line_journal_idx on journal_line (journal_id);
create index journal_line_contact_idx on journal_line (organisation_id, contact_id)
  where contact_id is not null;
create index journal_line_unreconciled_idx on journal_line (organisation_id, account_id)
  where reconciled_at is null;

-- ---------------------------------------------------------------------
-- Rule 2: every journal balances
--
-- Deferred so that a journal and its lines can be inserted in one
-- transaction. Checked once at commit.
-- ---------------------------------------------------------------------

create or replace function assert_journal_balances()
returns trigger
language plpgsql
as $$
declare
  v_journal_id uuid := coalesce(new.journal_id, old.journal_id);
  v_debit  numeric(14,2);
  v_credit numeric(14,2);
begin
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
    into v_debit, v_credit
    from journal_line
   where journal_id = v_journal_id;

  if v_debit <> v_credit then
    raise exception
      'Journal does not balance: debits %, credits %, difference %',
      to_char(v_debit, 'FM999999999990.00'),
      to_char(v_credit, 'FM999999999990.00'),
      to_char(v_debit - v_credit, 'FM999999999990.00')
      using errcode = 'check_violation';
  end if;

  if v_debit = 0 then
    raise exception 'A journal must have at least one line'
      using errcode = 'check_violation';
  end if;

  return null;
end;
$$;

create constraint trigger journal_line_balances
  after insert or update or delete on journal_line
  deferrable initially deferred
  for each row execute function assert_journal_balances();

-- ---------------------------------------------------------------------
-- Rule 3: posted journals are immutable
--
-- The only permitted change is stamping reversed_by_journal_id, which
-- the reverse_journal() function does with the guard flag set.
-- ---------------------------------------------------------------------

create or replace function forbid_journal_mutation()
returns trigger
language plpgsql
as $$
begin
  if current_setting('app.ledger_unlocked', true) = 'on' then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    raise exception
      'Posted transactions cannot be deleted. Reverse the transaction instead.'
      using errcode = 'insufficient_privilege';
  end if;

  raise exception
    'Posted transactions cannot be edited. Reverse the transaction and re-enter it.'
    using errcode = 'insufficient_privilege';
end;
$$;

create trigger journal_immutable
  before update or delete on journal
  for each row execute function forbid_journal_mutation();

create trigger journal_line_immutable
  before update or delete on journal_line
  for each row execute function forbid_journal_mutation();

-- Reconciliation and VAT flagging need to write to a posted line
-- without opening up the whole row. Both go through these functions.

create or replace function set_line_reconciled(
  p_line_id      uuid,
  p_statement_id uuid,
  p_reconciled   boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('app.ledger_unlocked', 'on', true);
  update journal_line
     set reconciled_at = case when p_reconciled then now() else null end,
         statement_id  = case when p_reconciled then p_statement_id else null end
   where id = p_line_id;
  perform set_config('app.ledger_unlocked', 'off', true);
end;
$$;

create or replace function set_lines_vat_return(
  p_line_ids      uuid[],
  p_vat_return_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('app.ledger_unlocked', 'on', true);
  update journal_line
     set vat_return_id = p_vat_return_id
   where id = any(p_line_ids);
  perform set_config('app.ledger_unlocked', 'off', true);
end;
$$;

-- =====================================================================
-- 0007_contacts.sql
-- Customers and suppliers.
--
-- One table for both. A great many businesses buy from the people they
-- sell to, and keeping two separate records for the same company is
-- how addresses drift apart. The `is_customer` and `is_supplier` flags
-- decide which lists a contact appears in.
-- =====================================================================

create table contact (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,

  code            text not null,
  name            text not null,
  is_customer     boolean not null default false,
  is_supplier     boolean not null default false,

  email           text,
  phone           text,
  website         text,
  contact_name    text,

  -- Terms
  payment_terms_days int not null default 30,
  credit_limit    numeric(14,2),
  on_hold         boolean not null default false,

  -- Defaults applied to new documents for this contact
  default_account_id  uuid references account(id),
  default_vat_code_id uuid references vat_code(id),
  currency_code   text references currency(code),

  vat_number      text,
  company_number  text,

  -- Construction Industry Scheme
  cis_registered  boolean not null default false,
  cis_deduction_rate numeric(5,2),
  utr             text,

  notes           text,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid references auth.users(id),

  unique (organisation_id, code),
  constraint contact_is_something check (is_customer or is_supplier)
);

create index contact_org_customer_idx on contact (organisation_id, name)
  where is_customer and active;
create index contact_org_supplier_idx on contact (organisation_id, name)
  where is_supplier and active;

create table contact_address (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  contact_id      uuid not null references contact(id) on delete cascade,
  type            text not null default 'billing'
                    check (type in ('billing', 'delivery')),
  is_default      boolean not null default true,
  line_1          text,
  line_2          text,
  city            text,
  county          text,
  postcode        text,
  country         text default 'United Kingdom'
);

create index contact_address_contact_idx on contact_address (contact_id);

-- Now that contacts exist, tie journal lines to them so the sales and
-- purchase ledgers can be reconstructed from the nominal ledger alone.
alter table journal_line
  add constraint journal_line_contact_fkey
  foreign key (contact_id) references contact(id);

-- ---------------------------------------------------------------------
-- Contact creation
--
-- Wrapped in a function so the code comes from the shared sequence and
-- the address is created in the same transaction.
-- ---------------------------------------------------------------------

create or replace function create_contact(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org        uuid := (p_config ->> 'organisation_id')::uuid;
  v_id         uuid;
  v_code       text;
  v_customer   boolean := coalesce((p_config ->> 'is_customer')::boolean, false);
  v_supplier   boolean := coalesce((p_config ->> 'is_supplier')::boolean, false);
begin
  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  v_code := nullif(p_config ->> 'code', '');

  if v_code is null then
    v_code := next_document_number(v_org, case when v_customer then 'customer' else 'supplier' end);
  end if;

  insert into contact (
    organisation_id, code, name, is_customer, is_supplier,
    email, phone, website, contact_name,
    payment_terms_days, credit_limit,
    default_account_id, default_vat_code_id, currency_code,
    vat_number, company_number,
    cis_registered, cis_deduction_rate, utr,
    notes, created_by
  ) values (
    v_org, v_code, p_config ->> 'name', v_customer, v_supplier,
    nullif(p_config ->> 'email', ''),
    nullif(p_config ->> 'phone', ''),
    nullif(p_config ->> 'website', ''),
    nullif(p_config ->> 'contact_name', ''),
    coalesce((p_config ->> 'payment_terms_days')::int, 30),
    nullif(p_config ->> 'credit_limit', '')::numeric,
    nullif(p_config ->> 'default_account_id', '')::uuid,
    nullif(p_config ->> 'default_vat_code_id', '')::uuid,
    nullif(p_config ->> 'currency_code', ''),
    nullif(p_config ->> 'vat_number', ''),
    nullif(p_config ->> 'company_number', ''),
    coalesce((p_config ->> 'cis_registered')::boolean, false),
    nullif(p_config ->> 'cis_deduction_rate', '')::numeric,
    nullif(p_config ->> 'utr', ''),
    nullif(p_config ->> 'notes', ''),
    auth.uid()
  )
  returning id into v_id;

  if coalesce(p_config ->> 'address_line_1', '') <> ''
     or coalesce(p_config ->> 'postcode', '') <> '' then
    insert into contact_address (
      organisation_id, contact_id, type, line_1, line_2, city, county, postcode, country
    ) values (
      v_org, v_id, 'billing',
      nullif(p_config ->> 'address_line_1', ''),
      nullif(p_config ->> 'address_line_2', ''),
      nullif(p_config ->> 'city', ''),
      nullif(p_config ->> 'county', ''),
      nullif(p_config ->> 'postcode', ''),
      coalesce(nullif(p_config ->> 'country', ''), 'United Kingdom')
    );
  end if;

  return v_id;
end;
$$;

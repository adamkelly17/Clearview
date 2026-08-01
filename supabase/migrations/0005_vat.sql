-- =====================================================================
-- 0005_vat.sql
-- VAT codes and their return box mapping.
--
-- The box mapping lives on the code, not in the return logic. Adding a
-- new VAT treatment later is a row, not a code change. This is the
-- difference between a system that can follow HMRC's rules as they
-- change and one that needs a developer every time they do.
-- =====================================================================

create table vat_code (
  id                uuid primary key default gen_random_uuid(),
  organisation_id   uuid not null references organisation(id) on delete cascade,
  code              text not null,
  name              text not null,
  friendly_name     text not null,
  rate              numeric(5,2) not null default 0,

  -- Which box of the VAT return the net and VAT amounts feed.
  -- null means the amount does not appear on the return at all.
  sales_net_box     int check (sales_net_box between 1 and 9),
  sales_vat_box     int check (sales_vat_box between 1 and 9),
  purchase_net_box  int check (purchase_net_box between 1 and 9),
  purchase_vat_box  int check (purchase_vat_box between 1 and 9),

  -- Reverse charge posts VAT to both the input and output accounts,
  -- so the net effect on the liability is nil but both boxes move.
  is_reverse_charge boolean not null default false,
  is_outside_scope  boolean not null default false,
  is_exempt         boolean not null default false,
  is_zero_rated     boolean not null default false,
  is_default_sales     boolean not null default false,
  is_default_purchase  boolean not null default false,

  active            boolean not null default true,
  sort_order        int not null default 100,

  unique (organisation_id, code)
);

create index vat_code_org_idx on vat_code (organisation_id, active);

create or replace function seed_vat_codes(p_organisation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into vat_code (
    organisation_id, code, name, friendly_name, rate,
    sales_net_box, sales_vat_box, purchase_net_box, purchase_vat_box,
    is_reverse_charge, is_outside_scope, is_exempt, is_zero_rated,
    is_default_sales, is_default_purchase, sort_order
  ) values
    (p_organisation_id, 'T0', 'Zero rated',            'Zero rated (0%)',        0.00,
      6, null, 7, null, false, false, false, true,  false, false, 10),

    (p_organisation_id, 'T1', 'Standard rated',        'Standard rate (20%)',   20.00,
      6, 1,    7, 4,    false, false, false, false, true,  true,  20),

    (p_organisation_id, 'T2', 'Exempt',                'Exempt from VAT',        0.00,
      6, null, 7, null, false, false, true,  false, false, false, 30),

    (p_organisation_id, 'T5', 'Reduced rated',         'Reduced rate (5%)',      5.00,
      6, 1,    7, 4,    false, false, false, false, false, false, 40),

    (p_organisation_id, 'T9', 'Outside the scope',     'No VAT',                 0.00,
      null, null, null, null, false, true, false, false, false, false, 50),

    (p_organisation_id, 'T20', 'Domestic reverse charge - sales',
       'Reverse charge - work you sold (CIS)', 20.00,
      6, null, null, null, true,  false, false, false, false, false, 60),

    (p_organisation_id, 'T21', 'Domestic reverse charge - purchases',
       'Reverse charge - work you bought (CIS)', 20.00,
      null, 1,  7, 4,   true,  false, false, false, false, false, 70),

    (p_organisation_id, 'T22', 'Goods to EU',          'Goods sold to the EU',   0.00,
      6, null, null, null, false, false, false, true, false, false, 80),

    (p_organisation_id, 'T24', 'Imported goods - postponed VAT',
       'Imports (postponed VAT)', 20.00,
      null, 1,  7, 4,   true,  false, false, false, false, false, 90);
end;
$$;

-- Wire the default VAT code onto the sales and purchase nominals once
-- both exist.
create or replace function apply_default_vat_codes(p_organisation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sales    uuid;
  v_purchase uuid;
begin
  select id into v_sales from vat_code
   where organisation_id = p_organisation_id and is_default_sales limit 1;
  select id into v_purchase from vat_code
   where organisation_id = p_organisation_id and is_default_purchase limit 1;

  update account a
     set default_vat_code_id = v_sales
    from account_type t
   where a.account_type_code = t.code
     and a.organisation_id = p_organisation_id
     and t.class = 'income';

  update account a
     set default_vat_code_id = v_purchase
    from account_type t
   where a.account_type_code = t.code
     and a.organisation_id = p_organisation_id
     and t.class = 'expense';
end;
$$;

alter table account
  add constraint account_default_vat_code_fkey
  foreign key (default_vat_code_id) references vat_code(id);

alter table journal_line
  add constraint journal_line_vat_code_fkey
  foreign key (vat_code_id) references vat_code(id);

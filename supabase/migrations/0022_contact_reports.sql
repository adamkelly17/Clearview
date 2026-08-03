-- =====================================================================
-- 0022_contact_reports.sql
--
-- One summary per contact for the list screen, one row per outstanding
-- item for the detailed reports, and the ability to change a contact
-- after it has been set up.
--
-- The list and the summary report come from the same function on purpose.
-- A report that disagrees with the screen it was downloaded from is worse
-- than no report.
-- =====================================================================

-- ---------------------------------------------------------------------
-- One row per contact
--
-- Counts as well as amounts. "£4,200 overdue" and "£4,200 overdue across
-- eleven invoices" call for quite different phone calls.
-- ---------------------------------------------------------------------

create or replace function contact_summary(
  p_organisation_id uuid,
  p_ledger          text default 'sales',
  p_as_at           date default null
) returns table (
  contact_id       uuid,
  code             text,
  name             text,
  email            text,
  phone            text,
  credit_limit     numeric,
  on_hold          boolean,
  active           boolean,
  cis_registered   boolean,
  total_due        numeric,
  outstanding_count int,
  overdue_amount   numeric,
  overdue_count    int,
  current_amount   numeric,
  days_30          numeric,
  days_60          numeric,
  days_90          numeric,
  older            numeric,
  oldest_due       date,
  oldest_days      int,
  over_limit       boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with as_at as (select coalesce(p_as_at, current_date) as d),
  items as (
    select o.contact_id,
           -- Positive means owed to you on the sales ledger, owed by you
           -- on the purchase ledger. Nobody wants to read a customer
           -- list in signed balances.
           case when o.direction = (case when p_ledger = 'sales' then 'debit' else 'credit' end)
                then o.outstanding_amount else -o.outstanding_amount end as amount,
           coalesce(o.due_date, o.date) as due,
           (select d from as_at) - coalesce(o.due_date, o.date) as age,
           o.item_type
      from ledger_item_outstanding o
     where o.organisation_id = p_organisation_id
       and o.ledger = p_ledger
       and o.outstanding_amount > 0
       and o.date <= (select d from as_at)
  ),
  agg as (
    select i.contact_id,
           coalesce(sum(i.amount), 0) as total_due,
           count(*) filter (where i.amount > 0)::int as outstanding_count,
           coalesce(sum(i.amount) filter (where i.age > 0 and i.amount > 0), 0) as overdue_amount,
           count(*) filter (where i.age > 0 and i.amount > 0)::int as overdue_count,
           coalesce(sum(i.amount) filter (where i.age <= 0), 0) as current_amount,
           coalesce(sum(i.amount) filter (where i.age between 1 and 30), 0) as days_30,
           coalesce(sum(i.amount) filter (where i.age between 31 and 60), 0) as days_60,
           coalesce(sum(i.amount) filter (where i.age between 61 and 90), 0) as days_90,
           coalesce(sum(i.amount) filter (where i.age > 90), 0) as older,
           min(i.due) filter (where i.amount > 0) as oldest_due,
           max(i.age) filter (where i.amount > 0)::int as oldest_days
      from items i
     group by i.contact_id
  )
  select c.id, c.code, c.name, c.email, c.phone,
         c.credit_limit, c.on_hold, c.active, c.cis_registered,
         coalesce(a.total_due, 0),
         coalesce(a.outstanding_count, 0),
         coalesce(a.overdue_amount, 0),
         coalesce(a.overdue_count, 0),
         coalesce(a.current_amount, 0),
         coalesce(a.days_30, 0),
         coalesce(a.days_60, 0),
         coalesce(a.days_90, 0),
         coalesce(a.older, 0),
         a.oldest_due,
         coalesce(a.oldest_days, 0),
         c.credit_limit is not null and coalesce(a.total_due, 0) > c.credit_limit
    from contact c
    left join agg a on a.contact_id = c.id
   where c.organisation_id = p_organisation_id
     and (p_ledger = 'sales' and c.is_customer or p_ledger = 'purchase' and c.is_supplier)
   order by c.name;
$$;

grant execute on function contact_summary(uuid, text, date) to authenticated;

-- ---------------------------------------------------------------------
-- One row per outstanding item, for the detailed reports
--
-- Carries the ageing bucket as a label as well as the day count, so a
-- spreadsheet can be pivoted on it without anyone having to rebuild the
-- bucket logic in Excel and get it subtly different.
-- ---------------------------------------------------------------------

create or replace function outstanding_items(
  p_organisation_id uuid,
  p_ledger          text default 'sales',
  p_overdue_only    boolean default false,
  p_as_at           date default null
) returns table (
  contact_id       uuid,
  contact_code     text,
  contact_name     text,
  item_type        text,
  reference        text,
  document_number  text,
  item_date        date,
  due_date         date,
  gross_amount     numeric,
  outstanding_amount numeric,
  days_overdue     int,
  bucket           text,
  current_amount   numeric,
  days_30          numeric,
  days_60          numeric,
  days_90          numeric,
  older            numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with as_at as (select coalesce(p_as_at, current_date) as d),
  items as (
    select o.contact_id, c.code, c.name, o.item_type, o.reference,
           d.number as document_number,
           o.date, coalesce(o.due_date, o.date) as due,
           o.gross_amount, o.outstanding_amount,
           greatest(0, (select d from as_at) - coalesce(o.due_date, o.date))::int as age,
           o.direction
      from ledger_item_outstanding o
      join contact c on c.id = o.contact_id
      left join document d on d.id = o.document_id
     where o.organisation_id = p_organisation_id
       and o.ledger = p_ledger
       and o.outstanding_amount > 0
       and o.date <= (select d from as_at)
       and o.direction = (case when p_ledger = 'sales' then 'debit' else 'credit' end)
  )
  select i.contact_id, i.code, i.name, i.item_type, i.reference, i.document_number,
         i.date, i.due, i.gross_amount, i.outstanding_amount, i.age,
         case
           when i.age <= 0 then 'Current'
           when i.age <= 30 then '1-30 days'
           when i.age <= 60 then '31-60 days'
           when i.age <= 90 then '61-90 days'
           else 'Over 90 days'
         end,
         case when i.age <= 0 then i.outstanding_amount else 0 end,
         case when i.age between 1 and 30 then i.outstanding_amount else 0 end,
         case when i.age between 31 and 60 then i.outstanding_amount else 0 end,
         case when i.age between 61 and 90 then i.outstanding_amount else 0 end,
         case when i.age > 90 then i.outstanding_amount else 0 end
    from items i
   where not p_overdue_only or i.age > 0
   order by i.name, i.due, i.reference;
$$;

grant execute on function outstanding_items(uuid, text, boolean, date) to authenticated;

-- ---------------------------------------------------------------------
-- Changing a contact
--
-- Wrapped rather than left as a plain table update so the address goes
-- with it. A customer whose name changed but whose address did not
-- follow is a support call waiting to happen.
-- ---------------------------------------------------------------------

create or replace function update_contact(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id  uuid := (p_config ->> 'id')::uuid;
  v_org uuid;
  v_addr uuid;
  v_has_address boolean;
begin
  select organisation_id into v_org from contact where id = v_id;

  if v_org is null then
    raise exception 'That contact does not exist' using errcode = 'no_data_found';
  end if;

  if not has_org_role(v_org, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to change this contact'
      using errcode = 'insufficient_privilege';
  end if;

  update contact
     set name = coalesce(nullif(p_config ->> 'name', ''), name),
         code = coalesce(nullif(p_config ->> 'code', ''), code),
         is_customer = coalesce((p_config ->> 'is_customer')::boolean, is_customer),
         is_supplier = coalesce((p_config ->> 'is_supplier')::boolean, is_supplier),
         email = nullif(p_config ->> 'email', ''),
         phone = nullif(p_config ->> 'phone', ''),
         website = nullif(p_config ->> 'website', ''),
         contact_name = nullif(p_config ->> 'contact_name', ''),
         payment_terms_days = coalesce((p_config ->> 'payment_terms_days')::int, payment_terms_days),
         credit_limit = nullif(p_config ->> 'credit_limit', '')::numeric,
         on_hold = coalesce((p_config ->> 'on_hold')::boolean, on_hold),
         default_account_id = nullif(p_config ->> 'default_account_id', '')::uuid,
         default_vat_code_id = nullif(p_config ->> 'default_vat_code_id', '')::uuid,
         vat_number = nullif(p_config ->> 'vat_number', ''),
         company_number = nullif(p_config ->> 'company_number', ''),
         cis_registered = coalesce((p_config ->> 'cis_registered')::boolean, cis_registered),
         cis_deduction_rate = nullif(p_config ->> 'cis_deduction_rate', '')::numeric,
         notes = nullif(p_config ->> 'notes', ''),
         active = coalesce((p_config ->> 'active')::boolean, active)
   where id = v_id;

  v_has_address :=
    coalesce(p_config ->> 'address_line_1', '') <> ''
    or coalesce(p_config ->> 'city', '') <> ''
    or coalesce(p_config ->> 'postcode', '') <> '';

  if v_has_address then
    select id into v_addr from contact_address
     where contact_id = v_id and type = 'billing' limit 1;

    if v_addr is null then
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
    else
      update contact_address
         set line_1 = nullif(p_config ->> 'address_line_1', ''),
             line_2 = nullif(p_config ->> 'address_line_2', ''),
             city = nullif(p_config ->> 'city', ''),
             county = nullif(p_config ->> 'county', ''),
             postcode = nullif(p_config ->> 'postcode', ''),
             country = coalesce(nullif(p_config ->> 'country', ''), 'United Kingdom')
       where id = v_addr;
    end if;
  end if;

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_org, auth.uid(), 'contact', v_id::text, 'updated', p_config);

  return v_id;
end;
$$;

grant execute on function update_contact(jsonb) to authenticated;

-- Reading a contact back for editing, address included.
create or replace function contact_for_edit(p_contact_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_c contact;
  v_a contact_address;
begin
  select * into v_c from contact where id = p_contact_id;

  if not found or not is_org_member(v_c.organisation_id) then
    raise exception 'That contact does not exist' using errcode = 'no_data_found';
  end if;

  select * into v_a from contact_address
   where contact_id = p_contact_id and type = 'billing' limit 1;

  return jsonb_build_object(
    'id', v_c.id,
    'code', v_c.code,
    'name', v_c.name,
    'is_customer', v_c.is_customer,
    'is_supplier', v_c.is_supplier,
    'email', v_c.email,
    'phone', v_c.phone,
    'website', v_c.website,
    'contact_name', v_c.contact_name,
    'payment_terms_days', v_c.payment_terms_days,
    'credit_limit', v_c.credit_limit,
    'on_hold', v_c.on_hold,
    'default_account_id', v_c.default_account_id,
    'default_vat_code_id', v_c.default_vat_code_id,
    'vat_number', v_c.vat_number,
    'company_number', v_c.company_number,
    'cis_registered', v_c.cis_registered,
    'cis_deduction_rate', v_c.cis_deduction_rate,
    'notes', v_c.notes,
    'active', v_c.active,
    'address_line_1', v_a.line_1,
    'address_line_2', v_a.line_2,
    'city', v_a.city,
    'county', v_a.county,
    'postcode', v_a.postcode,
    'country', v_a.country
  );
end;
$$;

grant execute on function contact_for_edit(uuid) to authenticated;

-- =====================================================================
-- 0008_trading.sql
-- Documents and the settlement layer.
--
-- Two ideas here, and the second one is the important one.
--
-- `document` is one table for invoices, credit notes, bills, purchase
-- credits, quotes and purchase orders. They differ by a type column,
-- not by having six near-identical pairs of tables.
--
-- `ledger_item` and `allocation` are the settlement layer. One
-- ledger_item exists for every single thing that can be settled: an
-- invoice, a credit note, a receipt, a payment on account. An
-- allocation links a debit item to a credit item for an amount.
-- Outstanding balance is gross_amount less what has been allocated.
--
-- Aged debtors, aged creditors, statements, remittances and credit
-- control all come out of these two tables. Getting this shape right
-- means never writing "how much does this customer owe" twice.
-- =====================================================================

create table document (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,

  -- SI sales invoice     SC sales credit note
  -- PI purchase invoice  PC purchase credit note
  -- QU quote             PO purchase order
  doc_type        text not null check (doc_type in ('SI', 'SC', 'PI', 'PC', 'QU', 'PO')),
  contact_id      uuid not null references contact(id),

  number          text not null,
  date            date not null,
  due_date        date,
  their_reference text,

  -- draft   : nothing posted, freely editable
  -- posted  : in the ledger, immutable
  -- void    : reversed out
  status          text not null default 'draft'
                    check (status in ('draft', 'posted', 'void')),

  currency_code   text not null references currency(code),
  exchange_rate   numeric(18,8) not null default 1,

  net_total       numeric(14,2) not null default 0,
  vat_total       numeric(14,2) not null default 0,
  gross_total     numeric(14,2) not null default 0,

  notes           text,
  terms           text,

  journal_id      uuid references journal(id),
  ledger_item_id  uuid,
  pdf_path        text,

  posted_at       timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid references auth.users(id),

  unique (organisation_id, doc_type, number)
);

create index document_org_type_date_idx on document (organisation_id, doc_type, date desc);
create index document_contact_idx on document (organisation_id, contact_id);
create index document_status_idx on document (organisation_id, status);

create table document_line (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  document_id     uuid not null references document(id) on delete cascade,
  line_no         int  not null,

  description     text not null,
  quantity        numeric(14,4) not null default 1,
  unit_price      numeric(14,4) not null default 0,
  discount_percent numeric(5,2) not null default 0,

  account_id      uuid not null references account(id),
  vat_code_id     uuid references vat_code(id),
  department_id   uuid,
  project_id      uuid,

  net_amount      numeric(14,2) not null default 0,
  vat_amount      numeric(14,2) not null default 0,
  -- Reverse charge VAT: not charged to the customer, but still
  -- reported. Held separately so gross totals stay correct.
  notional_vat    numeric(14,2) not null default 0,

  unique (document_id, line_no)
);

create index document_line_document_idx on document_line (document_id);

-- ---------------------------------------------------------------------
-- The settlement layer
-- ---------------------------------------------------------------------

create table ledger_item (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  contact_id      uuid not null references contact(id),

  ledger          text not null check (ledger in ('sales', 'purchase')),

  item_type       text not null check (item_type in
                    ('invoice', 'credit_note', 'payment', 'payment_on_account',
                     'write_off', 'discount', 'opening_balance', 'contra')),

  -- Always a positive magnitude. Direction says which way it moves the
  -- account. For the sales ledger, debit increases what the customer
  -- owes; for the purchase ledger, credit increases what you owe.
  direction       text not null check (direction in ('debit', 'credit')),
  gross_amount    numeric(14,2) not null check (gross_amount > 0),

  date            date not null,
  due_date        date,
  reference       text,
  description     text,

  currency_code   text not null references currency(code),
  exchange_rate   numeric(18,8) not null default 1,

  journal_id      uuid not null references journal(id),
  document_id     uuid references document(id),

  created_at      timestamptz not null default now()
);

create index ledger_item_contact_idx on ledger_item (organisation_id, contact_id, date);
create index ledger_item_ledger_idx on ledger_item (organisation_id, ledger, date);
create index ledger_item_document_idx on ledger_item (document_id);

alter table document
  add constraint document_ledger_item_fkey
  foreign key (ledger_item_id) references ledger_item(id);

create table allocation (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  debit_item_id   uuid not null references ledger_item(id) on delete cascade,
  credit_item_id  uuid not null references ledger_item(id) on delete cascade,
  amount          numeric(14,2) not null check (amount > 0),
  date            date not null,
  journal_id      uuid references journal(id),
  created_at      timestamptz not null default now(),
  created_by      uuid references auth.users(id),

  constraint allocation_distinct_items check (debit_item_id <> credit_item_id)
);

create index allocation_debit_idx on allocation (debit_item_id);
create index allocation_credit_idx on allocation (credit_item_id);

-- ---------------------------------------------------------------------
-- Outstanding balances
--
-- One view, and everything that asks "what is still owed" reads it.
-- ---------------------------------------------------------------------

create view ledger_item_outstanding as
select li.*,
       coalesce(alloc.allocated, 0) as allocated_amount,
       li.gross_amount - coalesce(alloc.allocated, 0) as outstanding_amount,
       case
         when li.gross_amount - coalesce(alloc.allocated, 0) <= 0 then 'settled'
         when coalesce(alloc.allocated, 0) > 0 then 'part_settled'
         else 'outstanding'
       end as settlement_status,
       greatest(0, current_date - coalesce(li.due_date, li.date)) as days_overdue
  from ledger_item li
  left join (
    -- An item can appear on either side of an allocation, so both
    -- sides are summed into one figure per item.
    select item_id, sum(allocated) as allocated
      from (
        select debit_item_id as item_id, sum(amount) as allocated
          from allocation group by debit_item_id
        union all
        select credit_item_id as item_id, sum(amount) as allocated
          from allocation group by credit_item_id
      ) both_sides
     group by item_id
  ) alloc on alloc.item_id = li.id;

-- ---------------------------------------------------------------------
-- Aged analysis
--
-- Standard 30/60/90 buckets measured from the due date. Credit notes
-- and unallocated payments sit in the current column as negatives, so
-- the total always agrees with the control account.
-- ---------------------------------------------------------------------

create or replace function aged_analysis(
  p_organisation_id uuid,
  p_ledger          text,
  p_as_at           date default null
) returns table (
  contact_id     uuid,
  contact_code   text,
  contact_name   text,
  current_amount numeric,
  days_30        numeric,
  days_60        numeric,
  days_90        numeric,
  older          numeric,
  total          numeric,
  credit_limit   numeric,
  oldest_due     date
)
language sql
stable
security definer
set search_path = public
as $$
  with as_at as (select coalesce(p_as_at, current_date) as d),
  items as (
    select o.contact_id,
           case when o.direction = (case when p_ledger = 'sales' then 'debit' else 'credit' end)
                then o.outstanding_amount
                else -o.outstanding_amount
           end as amount,
           coalesce(o.due_date, o.date) as due,
           (select d from as_at) - coalesce(o.due_date, o.date) as age
      from ledger_item_outstanding o
     where o.organisation_id = p_organisation_id
       and o.ledger = p_ledger
       and o.outstanding_amount > 0
       and o.date <= (select d from as_at)
  )
  select c.id, c.code, c.name,
         coalesce(sum(i.amount) filter (where i.age <= 0), 0),
         coalesce(sum(i.amount) filter (where i.age between 1 and 30), 0),
         coalesce(sum(i.amount) filter (where i.age between 31 and 60), 0),
         coalesce(sum(i.amount) filter (where i.age between 61 and 90), 0),
         coalesce(sum(i.amount) filter (where i.age > 90), 0),
         coalesce(sum(i.amount), 0),
         c.credit_limit,
         min(i.due) filter (where i.amount > 0)
    from items i
    join contact c on c.id = i.contact_id
   group by c.id, c.code, c.name, c.credit_limit
  having coalesce(sum(i.amount), 0) <> 0
   order by c.name;
$$;

-- ---------------------------------------------------------------------
-- Contact statement: every item and every settlement, in date order.
-- ---------------------------------------------------------------------

create or replace function contact_statement(
  p_organisation_id uuid,
  p_contact_id      uuid,
  p_from_date       date default null,
  p_to_date         date default null
) returns table (
  item_id      uuid,
  date         date,
  due_date     date,
  item_type    text,
  direction    text,
  reference    text,
  description  text,
  gross_amount numeric,
  outstanding_amount numeric,
  document_id  uuid,
  running_balance numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with rows as (
    select o.id, o.date, o.due_date, o.item_type, o.direction,
           o.reference, o.description, o.gross_amount, o.outstanding_amount,
           o.document_id,
           case when o.direction = 'debit' then o.gross_amount else -o.gross_amount end as signed
      from ledger_item_outstanding o
     where o.organisation_id = p_organisation_id
       and o.contact_id = p_contact_id
       and (p_from_date is null or o.date >= p_from_date)
       and (p_to_date   is null or o.date <= p_to_date)
  )
  select r.id, r.date, r.due_date, r.item_type, r.direction,
         r.reference, r.description, r.gross_amount, r.outstanding_amount,
         r.document_id,
         sum(r.signed) over (order by r.date, r.id
                             rows between unbounded preceding and current row)
    from rows r
   order by r.date, r.id;
$$;

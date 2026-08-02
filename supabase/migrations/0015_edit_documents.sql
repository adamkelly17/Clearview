-- =====================================================================
-- 0015_edit_documents.sql
--
-- Editing a posted invoice or bill.
--
-- A posted document still cannot be altered — that rule does not bend,
-- because an audit trail where figures can change silently is not an
-- audit trail. Editing is implemented as void and replace:
--
--   1. The original is voided. Its journal is reversed. Both entries
--      stay in the transaction list for ever.
--   2. A new document is posted with the corrected details.
--   3. The two are linked in both directions, and the original records
--      "Replaced by INV0007" against it.
--
-- The result behaves like an edit from the user's side and reads like a
-- correction from an auditor's side, which is exactly what it is.
--
-- Everything can change: supplier, date, number, lines, categories, VAT
-- treatment. The new document is posted from scratch, so there is no
-- field that is quietly carried over and no partial update to get wrong.
-- =====================================================================

alter table document add column if not exists replaced_by_document_id uuid references document(id);
alter table document add column if not exists replaces_document_id    uuid references document(id);

create index if not exists document_replaces_idx
  on document (replaces_document_id) where replaces_document_id is not null;

-- ---------------------------------------------------------------------
-- Document numbers may be reused once the original is void
--
-- Correcting INV0006 should produce INV0006, not INV0007 — the customer
-- has the first one and the numbering should not develop gaps. The
-- uniqueness rule therefore applies only to documents that still count.
-- ---------------------------------------------------------------------

do $$
declare
  v_constraint text;
begin
  select conname into v_constraint
    from pg_constraint
   where conrelid = 'document'::regclass
     and contype = 'u'
     and pg_get_constraintdef(oid) like '%doc_type, number%';

  if v_constraint is not null then
    execute format('alter table document drop constraint %I', v_constraint);
  end if;
end;
$$;

drop index if exists document_number_live_idx;

create unique index document_number_live_idx
  on document (organisation_id, doc_type, number)
  where status <> 'void';

-- ---------------------------------------------------------------------
-- replace_document
--
-- p_config is exactly what post_document() takes. The organisation is
-- inherited from the original, so a document cannot be moved between
-- organisations by editing it.
-- ---------------------------------------------------------------------

create or replace function replace_document(
  p_document_id uuid,
  p_config      jsonb,
  p_reason      text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old      document;
  v_out      record;
  v_new_id   uuid;
  v_new_num  text;
  v_config   jsonb;
begin
  select * into v_old from document where id = p_document_id;

  if not found then
    raise exception 'That document does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_old.organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_old.status <> 'posted' then
    raise exception 'Only a posted document can be edited'
      using errcode = 'check_violation';
  end if;

  -- Same reasoning as voiding: a payment against this is real, and
  -- editing around it would leave the control account disagreeing with
  -- the sub-ledger.
  if v_old.ledger_item_id is not null then
    select * into v_out from ledger_item_outstanding where id = v_old.ledger_item_id;

    if v_out.allocated_amount > 0 then
      raise exception
        'This has % settled against it. Unallocate the payment first, then edit it.',
        to_char(v_out.allocated_amount, 'FM999999990.00')
        using errcode = 'check_violation';
    end if;
  end if;

  -- Void first. That frees the document number, because the uniqueness
  -- index ignores voided documents.
  perform void_document(p_document_id, coalesce(p_reason, 'Edited'));

  -- Keep the original number unless the caller supplied a different one.
  v_config := jsonb_build_object('organisation_id', v_old.organisation_id)
              || p_config;

  if not (v_config ? 'number') or nullif(v_config ->> 'number', '') is null then
    v_config := v_config || jsonb_build_object('number', v_old.number);
  end if;

  if not (v_config ? 'doc_type') then
    v_config := v_config || jsonb_build_object('doc_type', v_old.doc_type);
  end if;

  v_new_id := post_document(v_config);

  select number into v_new_num from document where id = v_new_id;

  perform set_config('app.ledger_unlocked', 'on', true);

  update document
     set replaced_by_document_id = v_new_id,
         void_reason = 'Replaced by ' || v_new_num ||
           case when p_reason is null or p_reason = 'Edited'
                then '' else ' — ' || p_reason end
   where id = p_document_id;

  update document
     set replaces_document_id = p_document_id
   where id = v_new_id;

  perform set_config('app.ledger_unlocked', 'off', true);

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_old.organisation_id, auth.uid(), 'document', p_document_id::text, 'replaced',
          jsonb_build_object(
            'old_number', v_old.number,
            'old_gross', v_old.gross_total,
            'new_document', v_new_id,
            'new_number', v_new_num,
            'reason', p_reason));

  return v_new_id;
end;
$$;

grant execute on function replace_document(uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- Reading a document back for editing
--
-- One call, so the edit screen does not have to stitch four queries
-- together and risk showing a line that belongs to something else.
-- ---------------------------------------------------------------------

create or replace function document_for_edit(p_document_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_doc   document;
  v_lines jsonb;
begin
  select * into v_doc from document where id = p_document_id;

  if not found or not is_org_member(v_doc.organisation_id) then
    raise exception 'That document does not exist' using errcode = 'no_data_found';
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'description',      dl.description,
             'quantity',         dl.quantity,
             'unit_price',       dl.unit_price,
             'discount_percent', dl.discount_percent,
             'account_id',       dl.account_id,
             'vat_code_id',      dl.vat_code_id,
             'department_id',    dl.department_id
           ) order by dl.line_no), '[]'::jsonb)
    into v_lines
    from document_line dl
   where dl.document_id = p_document_id;

  return jsonb_build_object(
    'id',              v_doc.id,
    'doc_type',        v_doc.doc_type,
    'contact_id',      v_doc.contact_id,
    'number',          v_doc.number,
    'date',            v_doc.date,
    'due_date',        v_doc.due_date,
    'their_reference', v_doc.their_reference,
    'notes',           v_doc.notes,
    'currency_code',   v_doc.currency_code,
    'status',          v_doc.status,
    'net_total',       v_doc.net_total,
    'vat_total',       v_doc.vat_total,
    'gross_total',     v_doc.gross_total,
    'lines',           v_lines
  );
end;
$$;

grant execute on function document_for_edit(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Contact activity
--
-- Powers the customer and supplier screens. Two modes:
--
--   outstanding only  what is still unpaid, which is the question being
--                     asked ninety per cent of the time
--   everything        the full statement including settled items,
--                     voided documents and their reversals
--
-- The running balance is only meaningful over the full list, so it is
-- returned but the interface only shows it in the second mode.
-- ---------------------------------------------------------------------

create or replace function contact_activity(
  p_organisation_id  uuid,
  p_contact_id       uuid,
  p_outstanding_only boolean default true,
  p_from_date        date default null,
  p_to_date          date default null
) returns table (
  item_id            uuid,
  date               date,
  due_date           date,
  item_type          text,
  ledger             text,
  direction          text,
  reference          text,
  description        text,
  gross_amount       numeric,
  outstanding_amount numeric,
  settlement_status  text,
  days_overdue       int,
  document_id        uuid,
  document_status    text,
  replaced_by        text,
  running_balance    numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with rows as (
    select o.id, o.date, o.due_date, o.item_type, o.ledger, o.direction,
           o.reference, o.description, o.gross_amount, o.outstanding_amount,
           o.settlement_status, o.days_overdue, o.document_id,
           d.status as document_status,
           r.number as replaced_by,
           case when o.direction = 'debit' then o.gross_amount else -o.gross_amount end as signed
      from ledger_item_outstanding o
      left join document d on d.id = o.document_id
      left join document r on r.id = d.replaced_by_document_id
     where o.organisation_id = p_organisation_id
       and o.contact_id = p_contact_id
       and (p_from_date is null or o.date >= p_from_date)
       and (p_to_date   is null or o.date <= p_to_date)
  ),
  with_balance as (
    select r.*,
           sum(r.signed) over (order by r.date, r.id
                               rows between unbounded preceding and current row) as running_balance
      from rows r
  )
  select w.id, w.date, w.due_date, w.item_type, w.ledger, w.direction,
         w.reference, w.description, w.gross_amount, w.outstanding_amount,
         w.settlement_status, w.days_overdue, w.document_id,
         w.document_status, w.replaced_by, w.running_balance
    from with_balance w
   where not p_outstanding_only
      or (w.outstanding_amount > 0 and coalesce(w.document_status, 'posted') <> 'void')
   order by w.date, w.id;
$$;

grant execute on function contact_activity(uuid, uuid, boolean, date, date) to authenticated;

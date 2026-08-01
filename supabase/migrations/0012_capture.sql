-- =====================================================================
-- 0012_capture.sql
-- Invoice capture.
--
-- The governing rule: extraction produces a DRAFT, never a posting.
--
-- A model that misreads a VAT figure and posts straight to the ledger
-- produces a wrong VAT return, and there is no way to tell afterwards
-- whether a figure was read or checked. So nothing here writes to the
-- ledger. `approve_capture()` takes what a human confirmed on screen and
-- hands it to post_document(), which is still the only door in.
--
-- The original file is kept and linked to the posted document for as
-- long as the record is retained, because HMRC expects you to be able
-- to produce the paperwork behind any entry.
-- =====================================================================

create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------
-- The uploaded file
-- ---------------------------------------------------------------------

create table if not exists capture_document (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,

  storage_path    text not null,
  file_name       text not null,
  mime_type       text not null,
  file_size       bigint,
  page_count      int,

  -- A hash of the file itself. Catches the same PDF being uploaded
  -- twice, which is different from and cheaper than catching the same
  -- invoice arriving as two different files.
  file_hash       text,

  source          text not null default 'upload'
                    check (source in ('upload', 'email', 'api')),
  source_detail   text,

  -- Capture is built for purchases first. Sales invoices arriving as
  -- files are rarer but the column keeps the door open.
  ledger          text not null default 'purchase'
                    check (ledger in ('purchase', 'sales')),

  status          text not null default 'uploaded'
                    check (status in ('uploaded', 'extracting', 'extracted',
                                      'failed', 'approved', 'rejected')),
  status_detail   text,

  -- Set once approved and posted.
  document_id     uuid references document(id),

  uploaded_by     uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  extracted_at    timestamptz,
  resolved_at     timestamptz,
  resolved_by     uuid references auth.users(id),

  unique (organisation_id, storage_path)
);

create index if not exists capture_document_org_status_idx
  on capture_document (organisation_id, status, created_at desc);
create index if not exists capture_document_hash_idx
  on capture_document (organisation_id, file_hash)
  where file_hash is not null;

-- ---------------------------------------------------------------------
-- What the model read
--
-- Kept separately from the file so a document can be re-extracted with
-- a better model later without losing what the previous one said. The
-- provider and model are recorded because "which version read this"
-- becomes a real question the first time a figure is disputed.
-- ---------------------------------------------------------------------

create table if not exists capture_extraction (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  capture_document_id uuid not null references capture_document(id) on delete cascade,

  provider        text not null,
  model           text not null,
  extracted_at    timestamptz not null default now(),
  duration_ms     int,

  supplier_name       text,
  supplier_vat_number text,
  supplier_address    text,

  invoice_number  text,
  invoice_date    date,
  due_date        date,
  currency_code   text,

  net_total       numeric(14,2),
  vat_total       numeric(14,2),
  gross_total     numeric(14,2),

  -- Per-field confidence, e.g. {"invoice_number": 0.97, "vat_total": 0.62}
  field_confidence jsonb not null default '{}'::jsonb,
  overall_confidence numeric(4,3),

  raw_response    jsonb,

  -- Results of matching and checking, computed once and stored so the
  -- review screen does not have to redo the work on every render.
  matched_contact_id uuid references contact(id),
  match_method    text check (match_method in ('vat_number', 'exact_name', 'similar_name', 'none')),
  match_score     numeric(4,3),

  arithmetic_ok   boolean,
  validation_notes jsonb not null default '[]'::jsonb,
  duplicate_of_document_id uuid references document(id),

  is_current      boolean not null default true,
  created_at      timestamptz not null default now()
);

create index if not exists capture_extraction_doc_idx
  on capture_extraction (capture_document_id, is_current);

create table if not exists capture_extraction_line (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  capture_extraction_id uuid not null references capture_extraction(id) on delete cascade,
  line_no         int not null,

  description     text,
  quantity        numeric(14,4),
  unit_price      numeric(14,4),
  net_amount      numeric(14,2),
  vat_rate        numeric(5,2),
  vat_amount      numeric(14,2),

  -- Suggestions, not decisions. The reviewer can change either.
  suggested_account_id  uuid references account(id),
  suggested_vat_code_id uuid references vat_code(id),
  confidence      numeric(4,3),

  unique (capture_extraction_id, line_no)
);

create index if not exists capture_extraction_line_extraction_idx
  on capture_extraction_line (capture_extraction_id, line_no);

-- ---------------------------------------------------------------------
-- Supplier matching
--
-- VAT number first, because names are inconsistent and VAT numbers are
-- not. Then an exact name match, then a fuzzy one. A fuzzy match is
-- offered as a suggestion the reviewer confirms, never applied silently.
-- ---------------------------------------------------------------------

create or replace function match_contact(
  p_organisation_id uuid,
  p_name            text,
  p_vat_number      text default null,
  p_is_supplier     boolean default true
) returns table (
  contact_id uuid,
  method     text,
  score      numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_clean_vat  text;
  v_clean_name text;
  v_id         uuid;
  v_score      numeric;
begin
  -- Strip spaces and a leading GB so 'GB 123 4567 89' matches 'GB123456789'
  v_clean_vat := nullif(regexp_replace(upper(coalesce(p_vat_number, '')), '[^0-9]', '', 'g'), '');
  v_clean_name := lower(btrim(coalesce(p_name, '')));

  if v_clean_vat is not null then
    select c.id into v_id
      from contact c
     where c.organisation_id = p_organisation_id
       and c.active
       and (p_is_supplier and c.is_supplier or not p_is_supplier and c.is_customer)
       and nullif(regexp_replace(upper(coalesce(c.vat_number, '')), '[^0-9]', '', 'g'), '') = v_clean_vat
     limit 1;

    if v_id is not null then
      return query select v_id, 'vat_number'::text, 1.0::numeric;
      return;
    end if;
  end if;

  if v_clean_name <> '' then
    select c.id into v_id
      from contact c
     where c.organisation_id = p_organisation_id
       and c.active
       and (p_is_supplier and c.is_supplier or not p_is_supplier and c.is_customer)
       and lower(btrim(c.name)) = v_clean_name
     limit 1;

    if v_id is not null then
      return query select v_id, 'exact_name'::text, 1.0::numeric;
      return;
    end if;

    -- Fuzzy. 0.45 is deliberately generous because the reviewer confirms
    -- it; a near miss shown and rejected costs less than no suggestion.
    select c.id, similarity(lower(c.name), v_clean_name)
      into v_id, v_score
      from contact c
     where c.organisation_id = p_organisation_id
       and c.active
       and (p_is_supplier and c.is_supplier or not p_is_supplier and c.is_customer)
       and similarity(lower(c.name), v_clean_name) > 0.45
     order by similarity(lower(c.name), v_clean_name) desc
     limit 1;

    if v_id is not null then
      return query select v_id, 'similar_name'::text, round(v_score, 3);
      return;
    end if;
  end if;

  return query select null::uuid, 'none'::text, 0::numeric;
end;
$$;

-- ---------------------------------------------------------------------
-- Nominal coding from history
--
-- If the last several bills from this supplier all went to 7501, that is
-- almost certainly where this one goes. This is the function that turns
-- capture from data entry into time actually saved.
-- ---------------------------------------------------------------------

create or replace function suggest_account_for_contact(
  p_organisation_id uuid,
  p_contact_id      uuid
) returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select dl.account_id
    from document_line dl
    join document d on d.id = dl.document_id
   where d.organisation_id = p_organisation_id
     and d.contact_id = p_contact_id
     and d.status = 'posted'
   group by dl.account_id
   order by count(*) desc, max(d.date) desc
   limit 1;
$$;

create or replace function suggest_vat_code_for_rate(
  p_organisation_id uuid,
  p_rate            numeric
) returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id
    from vat_code
   where organisation_id = p_organisation_id
     and active
     and rate = coalesce(p_rate, 0)
     and not is_reverse_charge
   order by is_default_purchase desc, sort_order
   limit 1;
$$;

-- ---------------------------------------------------------------------
-- Duplicate detection
--
-- Duplicate purchase invoices are one of the most common real errors in
-- a purchase ledger, and capture makes them easier to create. Two
-- tests: the same supplier and invoice number, or the same supplier,
-- total and a date within a week.
-- ---------------------------------------------------------------------

create or replace function find_duplicate_document(
  p_organisation_id uuid,
  p_contact_id      uuid,
  p_number          text,
  p_gross_total     numeric default null,
  p_date            date default null
) returns table (
  document_id uuid,
  number      text,
  date        date,
  gross_total numeric,
  reason      text
)
language sql
stable
security definer
set search_path = public
as $$
  select d.id, d.number, d.date, d.gross_total,
         case
           when lower(regexp_replace(coalesce(d.number, ''), '[^a-zA-Z0-9]', '', 'g'))
                = lower(regexp_replace(coalesce(p_number, ''), '[^a-zA-Z0-9]', '', 'g'))
             then 'same invoice number'
           else 'same amount within a week'
         end
    from document d
   where d.organisation_id = p_organisation_id
     and d.contact_id = p_contact_id
     and d.status = 'posted'
     and d.doc_type in ('PI', 'SI')
     and (
       (p_number is not null and p_number <> '' and
        lower(regexp_replace(coalesce(d.number, ''), '[^a-zA-Z0-9]', '', 'g'))
          = lower(regexp_replace(p_number, '[^a-zA-Z0-9]', '', 'g')))
       or
       (p_gross_total is not null and p_date is not null
        and d.gross_total = p_gross_total
        and abs(d.date - p_date) <= 7)
     )
   order by d.date desc
   limit 3;
$$;

-- ---------------------------------------------------------------------
-- Arithmetic checks
--
-- Extraction errors cluster where the numbers do not add up, so this is
-- the cheapest accuracy win available. It reports rather than corrects:
-- a silent fix would hide the very thing worth looking at.
-- ---------------------------------------------------------------------

create or replace function validate_extraction(p_extraction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_e      capture_extraction;
  v_notes  jsonb := '[]'::jsonb;
  v_lines_net numeric(14,2);
  v_lines_vat numeric(14,2);
  v_line_count int;
begin
  select * into v_e from capture_extraction where id = p_extraction_id;
  if not found then return v_notes; end if;

  select coalesce(sum(net_amount), 0), coalesce(sum(vat_amount), 0), count(*)
    into v_lines_net, v_lines_vat, v_line_count
    from capture_extraction_line where capture_extraction_id = p_extraction_id;

  if v_e.net_total is null or v_e.gross_total is null then
    v_notes := v_notes || jsonb_build_object(
      'field', 'totals', 'severity', 'error',
      'message', 'The totals could not be read from this document. Enter them by hand.');
  else
    if abs(coalesce(v_e.net_total, 0) + coalesce(v_e.vat_total, 0) - v_e.gross_total) > 0.02 then
      v_notes := v_notes || jsonb_build_object(
        'field', 'gross_total', 'severity', 'error',
        'message', format('Net %s plus VAT %s does not equal the total of %s.',
          to_char(v_e.net_total, 'FM999999990.00'),
          to_char(coalesce(v_e.vat_total, 0), 'FM999999990.00'),
          to_char(v_e.gross_total, 'FM999999990.00')));
    end if;

    if v_line_count > 0 and abs(v_lines_net - v_e.net_total) > 0.02 then
      v_notes := v_notes || jsonb_build_object(
        'field', 'lines', 'severity', 'error',
        'message', format('The lines add up to %s but the invoice total is %s. Check for a line that was missed.',
          to_char(v_lines_net, 'FM999999990.00'),
          to_char(v_e.net_total, 'FM999999990.00')));
    end if;

    if v_line_count > 0 and v_e.vat_total is not null
       and abs(v_lines_vat - v_e.vat_total) > 0.02 then
      v_notes := v_notes || jsonb_build_object(
        'field', 'vat', 'severity', 'warning',
        'message', format('VAT on the lines comes to %s but the invoice shows %s. Mixed rates are worth checking by eye.',
          to_char(v_lines_vat, 'FM999999990.00'),
          to_char(v_e.vat_total, 'FM999999990.00')));
    end if;
  end if;

  if v_line_count = 0 then
    v_notes := v_notes || jsonb_build_object(
      'field', 'lines', 'severity', 'warning',
      'message', 'No line detail was read. One line for the total will be created unless you add more.');
  end if;

  if v_e.invoice_number is null or btrim(v_e.invoice_number) = '' then
    v_notes := v_notes || jsonb_build_object(
      'field', 'invoice_number', 'severity', 'error',
      'message', 'No invoice number was found. One is needed to match the bill later.');
  end if;

  if v_e.invoice_date is null then
    v_notes := v_notes || jsonb_build_object(
      'field', 'invoice_date', 'severity', 'error',
      'message', 'No invoice date was found.');
  end if;

  if v_e.matched_contact_id is null then
    v_notes := v_notes || jsonb_build_object(
      'field', 'supplier', 'severity', 'error',
      'message', format('No supplier on file matches %s. Choose one or add a new supplier.',
        coalesce(v_e.supplier_name, 'this document')));
  elsif v_e.match_method = 'similar_name' then
    v_notes := v_notes || jsonb_build_object(
      'field', 'supplier', 'severity', 'warning',
      'message', 'The supplier was matched on a similar name rather than exactly. Worth confirming.');
  end if;

  return v_notes;
end;
$$;

-- Runs matching, suggestion and validation in one call after extraction.
create or replace function finalise_extraction(p_extraction_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_e        capture_extraction;
  v_capture  capture_document;
  v_match    record;
  v_dup      record;
  v_account  uuid;
  v_line     record;
begin
  select * into v_e from capture_extraction where id = p_extraction_id;
  if not found then
    raise exception 'That extraction does not exist' using errcode = 'no_data_found';
  end if;

  select * into v_capture from capture_document where id = v_e.capture_document_id;

  select * into v_match
    from match_contact(
      v_e.organisation_id, v_e.supplier_name, v_e.supplier_vat_number,
      v_capture.ledger = 'purchase');

  update capture_extraction
     set matched_contact_id = v_match.contact_id,
         match_method = v_match.method,
         match_score = v_match.score
   where id = p_extraction_id;

  if v_match.contact_id is not null then
    select * into v_dup
      from find_duplicate_document(
        v_e.organisation_id, v_match.contact_id, v_e.invoice_number,
        v_e.gross_total, v_e.invoice_date);

    if v_dup.document_id is not null then
      update capture_extraction
         set duplicate_of_document_id = v_dup.document_id
       where id = p_extraction_id;
    end if;

    v_account := suggest_account_for_contact(v_e.organisation_id, v_match.contact_id);
  end if;

  -- Suggest a nominal and a VAT code per line.
  for v_line in
    select id, vat_rate from capture_extraction_line
     where capture_extraction_id = p_extraction_id
  loop
    update capture_extraction_line
       set suggested_account_id = coalesce(suggested_account_id, v_account),
           suggested_vat_code_id = coalesce(
             suggested_vat_code_id,
             suggest_vat_code_for_rate(v_e.organisation_id, v_line.vat_rate))
     where id = v_line.id;
  end loop;

  -- Refresh and validate.
  select * into v_e from capture_extraction where id = p_extraction_id;

  update capture_extraction
     set validation_notes = validate_extraction(p_extraction_id),
         arithmetic_ok = (
           v_e.net_total is not null and v_e.gross_total is not null
           and abs(coalesce(v_e.net_total, 0) + coalesce(v_e.vat_total, 0)
                   - v_e.gross_total) <= 0.02
         )
   where id = p_extraction_id;

  update capture_document
     set status = 'extracted', extracted_at = now()
   where id = v_e.capture_document_id;
end;
$$;

-- ---------------------------------------------------------------------
-- approve_capture
--
-- The only route from a captured file into the ledger, and it takes what
-- the human confirmed rather than what the model read. p_config has the
-- same shape post_document() expects.
-- ---------------------------------------------------------------------

create or replace function approve_capture(
  p_capture_id uuid,
  p_config     jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_capture capture_document;
  v_doc_id  uuid;
begin
  select * into v_capture from capture_document where id = p_capture_id;

  if not found then
    raise exception 'That captured document does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_capture.organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if v_capture.status = 'approved' then
    raise exception 'That document has already been posted'
      using errcode = 'check_violation';
  end if;

  v_doc_id := post_document(
    p_config
      || jsonb_build_object('organisation_id', v_capture.organisation_id)
  );

  update capture_document
     set status = 'approved',
         document_id = v_doc_id,
         resolved_at = now(),
         resolved_by = auth.uid()
   where id = p_capture_id;

  -- Link the file to the posted document so the paperwork behind the
  -- entry can always be produced.
  insert into attachment (organisation_id, entity_type, entity_id, storage_path, filename)
  values (v_capture.organisation_id, 'document', v_doc_id,
          v_capture.storage_path, v_capture.file_name)
  on conflict do nothing;

  return v_doc_id;
end;
$$;

create or replace function reject_capture(
  p_capture_id uuid,
  p_reason     text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
begin
  select organisation_id into v_org from capture_document where id = p_capture_id;

  if v_org is null then
    raise exception 'That captured document does not exist' using errcode = 'no_data_found';
  end if;

  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  update capture_document
     set status = 'rejected',
         status_detail = p_reason,
         resolved_at = now(),
         resolved_by = auth.uid()
   where id = p_capture_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Attachments
--
-- Any stored file linked to any record. Created here because capture is
-- the first thing that needs it: HMRC expects the paperwork behind an
-- entry to be producible, so the original invoice stays attached to the
-- bill it became.
-- ---------------------------------------------------------------------

create table if not exists attachment (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  entity_type     text not null check (entity_type in
                    ('document', 'journal', 'contact', 'capture', 'organisation')),
  entity_id       uuid not null,
  storage_path    text not null,
  filename        text not null,
  mime_type       text,
  file_size       bigint,
  uploaded_by     uuid references auth.users(id),
  created_at      timestamptz not null default now()
);

create index if not exists attachment_entity_idx
  on attachment (organisation_id, entity_type, entity_id);

create unique index if not exists attachment_unique_idx
  on attachment (organisation_id, entity_type, entity_id, storage_path);

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------

-- Safe to re-run.
do $$
declare r record;
begin
  for r in
    select tablename, policyname from pg_policies
     where schemaname = 'public'
       and tablename in ('capture_document', 'capture_extraction',
                         'capture_extraction_line', 'attachment')
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end;
$$;

alter table capture_document        enable row level security;
alter table capture_extraction      enable row level security;
alter table capture_extraction_line enable row level security;
alter table attachment              enable row level security;

create policy "members read captures" on capture_document
  for select to authenticated using (is_org_member(organisation_id));

create policy "staff upload captures" on capture_document
  for insert to authenticated
  with check (has_org_role(organisation_id, array['owner','admin','bookkeeper']));

create policy "staff update captures" on capture_document
  for update to authenticated
  using (has_org_role(organisation_id, array['owner','admin','bookkeeper']))
  with check (has_org_role(organisation_id, array['owner','admin','bookkeeper']));

create policy "staff delete unposted captures" on capture_document
  for delete to authenticated
  using (
    has_org_role(organisation_id, array['owner','admin','bookkeeper'])
    and status <> 'approved'
  );

-- Extractions are written by the server route, which uses the user's
-- session, so inserts are permitted. Nothing here touches the ledger.
do $$
declare t text;
begin
  foreach t in array array['capture_extraction', 'capture_extraction_line']
  loop
    execute format($f$
      create policy "members read %1$s" on %1$I
        for select to authenticated using (is_org_member(organisation_id));

      create policy "staff write %1$s" on %1$I
        for insert to authenticated
        with check (has_org_role(organisation_id, array['owner','admin','bookkeeper']));

      create policy "staff update %1$s" on %1$I
        for update to authenticated
        using (has_org_role(organisation_id, array['owner','admin','bookkeeper']))
        with check (has_org_role(organisation_id, array['owner','admin','bookkeeper']));
    $f$, t);
  end loop;
end;
$$;

create policy "members read attachments" on attachment
  for select to authenticated using (is_org_member(organisation_id));

create policy "staff write attachments" on attachment
  for insert to authenticated
  with check (has_org_role(organisation_id, array['owner','admin','bookkeeper']));

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

grant execute on function match_contact(uuid, text, text, boolean) to authenticated;
grant execute on function suggest_account_for_contact(uuid, uuid) to authenticated;
grant execute on function suggest_vat_code_for_rate(uuid, numeric) to authenticated;
grant execute on function find_duplicate_document(uuid, uuid, text, numeric, date) to authenticated;
grant execute on function validate_extraction(uuid) to authenticated;
grant execute on function finalise_extraction(uuid) to authenticated;
grant execute on function approve_capture(uuid, jsonb) to authenticated;
grant execute on function reject_capture(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Storage
--
-- Creates a private bucket for the original files. Wrapped in a guard so
-- this migration still runs against a plain Postgres for testing, where
-- the storage schema does not exist.
-- ---------------------------------------------------------------------

do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then

    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('captures', 'captures', false, 20971520,
            array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'])
    on conflict (id) do nothing;

    -- Files live under {organisation_id}/{uuid}.{ext}, so the first path
    -- segment is the tenant key.
    execute $p$
      drop policy if exists "members read capture files" on storage.objects;
      create policy "members read capture files" on storage.objects
        for select to authenticated
        using (
          bucket_id = 'captures'
          and is_org_member(((storage.foldername(name))[1])::uuid)
        );

      drop policy if exists "staff upload capture files" on storage.objects;
      create policy "staff upload capture files" on storage.objects
        for insert to authenticated
        with check (
          bucket_id = 'captures'
          and has_org_role(((storage.foldername(name))[1])::uuid,
                           array['owner','admin','bookkeeper'])
        );

      drop policy if exists "staff delete capture files" on storage.objects;
      create policy "staff delete capture files" on storage.objects
        for delete to authenticated
        using (
          bucket_id = 'captures'
          and has_org_role(((storage.foldername(name))[1])::uuid,
                           array['owner','admin','bookkeeper'])
        );
    $p$;

  end if;
end;
$$;

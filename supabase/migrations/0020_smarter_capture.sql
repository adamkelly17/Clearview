-- =====================================================================
-- 0020_smarter_capture.sql
--
-- Four fixes from a real Amazon invoice.
--
-- 1. "Amazon EU S.à r.l., UK Branch" did not match "Amazon" on file.
--    Trigram similarity between those two is 0.25, well under the
--    threshold, because most of the long name is not in the short one.
--    That is the wrong measure. word_similarity() asks whether the short
--    string appears *within* the long one, and scores it 1.0.
--
-- 2. VAT was being suggested on a business that is not VAT registered.
--    Harmless at the point of posting, because post_document() strips it
--    — but the review screen showed a total of £8.24 against a document
--    saying £8.25, which is exactly the sort of thing that stops anyone
--    trusting the figures.
--
-- 3. No category was suggested for a supplier with no history. The model
--    can see what was bought; it just was not being asked.
--
-- 4. A confirmed supplier's VAT number is now remembered, so the second
--    invoice from them matches on VAT number rather than on a fuzzy name.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Normalising a company name
--
-- Strips punctuation, legal forms and territory qualifiers so that
-- "Amazon EU S.à r.l., UK Branch" and "Amazon" can be compared as the
-- same thing. Deliberately conservative: it removes the noise around a
-- name rather than trying to shorten the name itself.
-- ---------------------------------------------------------------------

create or replace function normalise_contact_name(p_name text)
returns text
language plpgsql
immutable
as $$
declare
  v_words text[];
  v_out   text[] := '{}';
  v_word  text;
  v_noise text[] := array[
    'ltd', 'limited', 'plc', 'llp', 'llc', 'inc', 'incorporated', 'corp',
    'corporation', 'gmbh', 'bv', 'nv', 'ag', 'sarl', 'sa', 'spa', 'srl',
    'pty', 'oy', 'ab', 'as', 'aps', 'kg', 'ug',
    'uk', 'gb', 'eu', 'branch', 'the', 'and', 'co', 'company'
  ];
begin
  v_words := string_to_array(
    btrim(regexp_replace(
      regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', ' ', 'g'),
      '\s+', ' ', 'g')),
    ' ');

  foreach v_word in array coalesce(v_words, '{}')
  loop
    -- Single characters are what is left of "S.à r.l." after the
    -- punctuation goes.
    continue when length(v_word) <= 1 or v_word = any(v_noise);
    v_out := v_out || v_word;
  end loop;

  -- If stripping left nothing, the name was entirely qualifiers. Fall
  -- back to the plain cleaned string rather than matching everything.
  if array_length(v_out, 1) is null then
    return btrim(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', ' ', 'g'));
  end if;

  return array_to_string(v_out, ' ');
end;
$$;

grant execute on function normalise_contact_name(text) to authenticated;

-- ---------------------------------------------------------------------
-- Supplier matching, in order of how much it can be trusted
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
  v_raw_name   text;
  v_norm       text;
  v_id         uuid;
  v_score      numeric;
begin
  v_clean_vat := nullif(regexp_replace(upper(coalesce(p_vat_number, '')), '[^0-9]', '', 'g'), '');
  v_raw_name  := lower(btrim(coalesce(p_name, '')));
  v_norm      := normalise_contact_name(p_name);

  -- 1. VAT number. Names are inconsistent; VAT numbers are not.
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

  if v_raw_name = '' then
    return query select null::uuid, 'none'::text, 0::numeric;
    return;
  end if;

  -- 2. The name exactly as written.
  select c.id into v_id
    from contact c
   where c.organisation_id = p_organisation_id
     and c.active
     and (p_is_supplier and c.is_supplier or not p_is_supplier and c.is_customer)
     and lower(btrim(c.name)) = v_raw_name
   limit 1;

  if v_id is not null then
    return query select v_id, 'exact_name'::text, 1.0::numeric;
    return;
  end if;

  -- 3. The same name once the legal form and territory are stripped.
  --    "Amazon EU S.à r.l., UK Branch" and "Amazon" both reduce to
  --    "amazon".
  if v_norm <> '' then
    select c.id into v_id
      from contact c
     where c.organisation_id = p_organisation_id
       and c.active
       and (p_is_supplier and c.is_supplier or not p_is_supplier and c.is_customer)
       and normalise_contact_name(c.name) = v_norm
     limit 1;

    if v_id is not null then
      return query select v_id, 'exact_name'::text, 0.95::numeric;
      return;
    end if;

    -- 4. One name contained in the other. Four characters minimum, so
    --    "BT" cannot claim every supplier with those letters in it.
    select c.id into v_id
      from contact c
     where c.organisation_id = p_organisation_id
       and c.active
       and (p_is_supplier and c.is_supplier or not p_is_supplier and c.is_customer)
       and length(normalise_contact_name(c.name)) >= 4
       and (
         v_norm ~ ('\y' || regexp_replace(normalise_contact_name(c.name), '([\\^$.|?*+()\[\]{}])', '\\\1', 'g') || '\y')
         or normalise_contact_name(c.name) ~ ('\y' || regexp_replace(v_norm, '([\\^$.|?*+()\[\]{}])', '\\\1', 'g') || '\y')
       )
     order by length(normalise_contact_name(c.name)) desc
     limit 1;

    if v_id is not null then
      return query select v_id, 'similar_name'::text, 0.88::numeric;
      return;
    end if;

    -- 5. word_similarity asks how well the shorter name sits inside the
    --    longer one, which is the right question for a trading name
    --    buried in a legal one.
    select c.id, word_similarity(normalise_contact_name(c.name), v_norm)
      into v_id, v_score
      from contact c
     where c.organisation_id = p_organisation_id
       and c.active
       and (p_is_supplier and c.is_supplier or not p_is_supplier and c.is_customer)
       and word_similarity(normalise_contact_name(c.name), v_norm) > 0.6
     order by word_similarity(normalise_contact_name(c.name), v_norm) desc
     limit 1;

    if v_id is not null then
      return query select v_id, 'similar_name'::text, round(v_score * 0.9, 3);
      return;
    end if;

    -- 6. Plain trigram similarity, for typos and truncations.
    select c.id, similarity(normalise_contact_name(c.name), v_norm)
      into v_id, v_score
      from contact c
     where c.organisation_id = p_organisation_id
       and c.active
       and (p_is_supplier and c.is_supplier or not p_is_supplier and c.is_customer)
       and similarity(normalise_contact_name(c.name), v_norm) > 0.45
     order by similarity(normalise_contact_name(c.name), v_norm) desc
     limit 1;

    if v_id is not null then
      return query select v_id, 'similar_name'::text, round(v_score, 3);
      return;
    end if;
  end if;

  return query select null::uuid, 'none'::text, 0::numeric;
end;
$$;

grant execute on function match_contact(uuid, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- No VAT code for a business that is not VAT registered
-- ---------------------------------------------------------------------

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
     -- Suggesting a rate to someone who cannot charge VAT made the
     -- review screen show a total that disagreed with the document.
     and coalesce((select vat_enabled from organisation_feature
                    where organisation_id = p_organisation_id), false)
   order by is_default_purchase desc, sort_order
   limit 1;
$$;

-- ---------------------------------------------------------------------
-- finalise_extraction
--
-- Two changes: history now beats the model's guess at a category, and
-- the model's guess is used when there is no history to go on.
-- ---------------------------------------------------------------------

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

  for v_line in
    select id, vat_rate, suggested_account_id from capture_extraction_line
     where capture_extraction_id = p_extraction_id
  loop
    update capture_extraction_line
       set -- What this supplier's bills have gone to before beats what
           -- the model inferred from the description. The model only
           -- gets a say where there is no history.
           suggested_account_id = coalesce(v_account, v_line.suggested_account_id),
           suggested_vat_code_id = coalesce(
             suggested_vat_code_id,
             suggest_vat_code_for_rate(v_e.organisation_id, v_line.vat_rate))
     where id = v_line.id;
  end loop;

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
-- Remember the supplier's VAT number when a match is confirmed
--
-- The first invoice from a supplier matches on a fuzzy name and the user
-- confirms it. Recording the VAT number at that moment means every
-- invoice after it matches exactly, with no guessing at all.
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
  v_ext     capture_extraction;
  v_doc_id  uuid;
  v_contact uuid;
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
    p_config || jsonb_build_object('organisation_id', v_capture.organisation_id)
  );

  update capture_document
     set status = 'approved',
         document_id = v_doc_id,
         resolved_at = now(),
         resolved_by = auth.uid()
   where id = p_capture_id;

  insert into attachment (organisation_id, entity_type, entity_id, storage_path, filename)
  values (v_capture.organisation_id, 'document', v_doc_id,
          v_capture.storage_path, v_capture.file_name)
  on conflict do nothing;

  -- Learn the VAT number from the confirmed match.
  select * into v_ext
    from capture_extraction
   where capture_document_id = p_capture_id and is_current
   limit 1;

  v_contact := nullif(p_config ->> 'contact_id', '')::uuid;

  if v_ext.supplier_vat_number is not null and v_contact is not null then
    update contact
       set vat_number = v_ext.supplier_vat_number
     where id = v_contact
       and organisation_id = v_capture.organisation_id
       and coalesce(btrim(vat_number), '') = '';
  end if;

  return v_doc_id;
end;
$$;

grant execute on function approve_capture(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- The chart of accounts, for the extraction prompt
--
-- The model can see what was bought but has no idea what the categories
-- are called. Handing it the list is the difference between no
-- suggestion and a sensible one.
-- ---------------------------------------------------------------------

create or replace function coding_options(
  p_organisation_id uuid,
  p_ledger          text default 'purchase'
) returns table (code text, name text, report_group text)
language sql
stable
security definer
set search_path = public
as $$
  select a.code, a.name, t.report_group
    from account a
    join account_type t on t.code = a.account_type_code
   where a.organisation_id = p_organisation_id
     and a.active
     and not a.is_control
     and not a.is_bank
     and t.class = (case when p_ledger = 'sales' then 'income' else 'expense' end)::account_class
   order by a.code;
$$;

grant execute on function coding_options(uuid, text) to authenticated;

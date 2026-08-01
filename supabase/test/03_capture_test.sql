-- =====================================================================
-- Capture tests: matching, suggestion, duplicate detection, validation
-- and the approval path into the ledger.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

do $$
declare
  v_user   uuid := gen_random_uuid();
  v_org    uuid;
  v_timber uuid;
  v_wells  uuid;
  v_bank   uuid;
  v_subcon uuid;
  v_post   uuid;
  v_credit uuid;
  v_t1     uuid;
  v_t21    uuid;
  v_cap    uuid;
  v_ext    uuid;
  v_doc    uuid;
  v_bill   uuid;
  v_match  record;
  v_dup    record;
  v_notes  jsonb;
  v_n      numeric;
  v_count  int;
  v_text   text;
  v_uuid   uuid;
  v_flag   boolean;
  v_ledger_total numeric;
begin
  insert into auth.users (id, email) values (v_user, 'capture@example.com');
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  v_org := create_organisation(jsonb_build_object(
    'name', 'Brookfield Joinery Ltd',
    'entity_type_code', 'limited_company',
    'year_end_day', 31, 'year_end_month', 3,
    'books_start_date', '2026-04-01',
    'vat_enabled', true));

  select id into v_bank   from account where organisation_id = v_org and code = '1200';
  select id into v_subcon from account where organisation_id = v_org and code = '5002';
  select id into v_post   from account where organisation_id = v_org and code = '7501';
  select id into v_t1     from vat_code where organisation_id = v_org and code = 'T1';
  select id into v_t21    from vat_code where organisation_id = v_org and code = 'T21';

  v_timber := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Timber Supplies Ltd',
    'is_supplier', true, 'vat_number', 'GB412556721'));

  v_wells := create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'K Wells Carpentry',
    'is_supplier', true, 'cis_registered', true));

  -- ---------------------------------------------------------------
  raise notice '--- Supplier matching';
  -- ---------------------------------------------------------------

  select * into v_match from match_contact(v_org, 'Totally Different Name', 'GB 412 5567 21', true);
  if v_match.contact_id <> v_timber or v_match.method <> 'vat_number' then
    raise exception 'FAIL: VAT number should win over the name, got % via %',
      v_match.contact_id, v_match.method;
  end if;
  raise notice 'PASS  VAT number matches even when the name is wrong, and spacing is ignored';

  select * into v_match from match_contact(v_org, 'timber supplies ltd', null, true);
  if v_match.contact_id <> v_timber or v_match.method <> 'exact_name' then
    raise exception 'FAIL: case-insensitive exact name match failed';
  end if;
  raise notice 'PASS  exact name match ignores case';

  select * into v_match from match_contact(v_org, 'Timber Supplies Limited', null, true);
  if v_match.contact_id <> v_timber or v_match.method <> 'similar_name' then
    raise exception 'FAIL: expected a fuzzy match on "Limited" vs "Ltd", got %', v_match.method;
  end if;
  raise notice 'PASS  "Limited" matched to "Ltd" as a similar name, score %', v_match.score;

  select * into v_match from match_contact(v_org, 'Pennington Scaffolding', null, true);
  if v_match.contact_id is not null then
    raise exception 'FAIL: an unrelated name should not match anything';
  end if;
  raise notice 'PASS  an unknown supplier returns no match rather than a bad one';

  -- A customer must not be matched when looking for a supplier.
  perform create_contact(jsonb_build_object(
    'organisation_id', v_org, 'name', 'Hartley Developments', 'is_customer', true));
  select * into v_match from match_contact(v_org, 'Hartley Developments', null, true);
  if v_match.contact_id is not null then
    raise exception 'FAIL: a customer was returned when matching a supplier';
  end if;
  raise notice 'PASS  customers are not offered as suppliers';

  -- ---------------------------------------------------------------
  raise notice '--- Nominal coding from history';
  -- ---------------------------------------------------------------

  if suggest_account_for_contact(v_org, v_timber) is not null then
    raise exception 'FAIL: should be no suggestion before any history exists';
  end if;
  raise notice 'PASS  no suggestion offered with no history';

  -- Three bills to postage, one to subcontractors.
  for v_count in 1..3 loop
    perform post_document(jsonb_build_object(
      'organisation_id', v_org, 'doc_type', 'PI', 'contact_id', v_timber,
      'date', '2026-05-0' || v_count, 'number', 'HIST-' || v_count,
      'lines', jsonb_build_array(jsonb_build_object(
        'description', 'Postage', 'quantity', 1, 'unit_price', 50,
        'account_id', v_post, 'vat_code_id', v_t1))));
  end loop;

  perform post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'PI', 'contact_id', v_timber,
    'date', '2026-05-04', 'number', 'HIST-4',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Labour', 'quantity', 1, 'unit_price', 50,
      'account_id', v_subcon, 'vat_code_id', v_t1))));

  if suggest_account_for_contact(v_org, v_timber) <> v_post then
    raise exception 'FAIL: should suggest the most used account';
  end if;
  raise notice 'PASS  suggests the account used most often for that supplier';

  -- ---------------------------------------------------------------
  raise notice '--- VAT code suggestion by rate';
  -- ---------------------------------------------------------------

  if (select code from vat_code where id = suggest_vat_code_for_rate(v_org, 20)) <> 'T1' then
    raise exception 'FAIL: 20%% should suggest T1';
  end if;
  if (select code from vat_code where id = suggest_vat_code_for_rate(v_org, 5)) <> 'T5' then
    raise exception 'FAIL: 5%% should suggest T5';
  end if;
  if suggest_vat_code_for_rate(v_org, 20) = v_t21 then
    raise exception 'FAIL: must not suggest a reverse charge code from a rate alone';
  end if;
  raise notice 'PASS  20%% suggests T1, 5%% suggests T5, reverse charge never auto-suggested';

  -- ---------------------------------------------------------------
  raise notice '--- Duplicate detection';
  -- ---------------------------------------------------------------

  v_bill := post_document(jsonb_build_object(
    'organisation_id', v_org, 'doc_type', 'PI', 'contact_id', v_timber,
    'date', '2026-05-12', 'number', 'TS-24188',
    'lines', jsonb_build_array(jsonb_build_object(
      'description', 'Oak', 'quantity', 1, 'unit_price', 1284.50,
      'account_id', v_post, 'vat_code_id', v_t1))));

  select * into v_dup from find_duplicate_document(v_org, v_timber, 'TS-24188', null, null);
  if v_dup.document_id is null then
    raise exception 'FAIL: an identical invoice number was not flagged';
  end if;
  raise notice 'PASS  the same invoice number is flagged as a duplicate';

  select * into v_dup from find_duplicate_document(v_org, v_timber, 'ts 24188', null, null);
  if v_dup.document_id is null then
    raise exception 'FAIL: punctuation and case should not defeat duplicate detection';
  end if;
  raise notice 'PASS  "ts 24188" still matches "TS-24188"';

  select * into v_dup from find_duplicate_document(v_org, v_timber, 'DIFFERENT-1', 1541.40, '2026-05-14');
  if v_dup.document_id is null then
    raise exception 'FAIL: same amount within a week should be flagged';
  end if;
  raise notice 'PASS  same total within a week flagged even with a different number';

  select * into v_dup from find_duplicate_document(v_org, v_timber, 'DIFFERENT-2', 1541.40, '2026-07-01');
  if v_dup.document_id is not null then
    raise exception 'FAIL: the same amount months later should not be a duplicate';
  end if;
  raise notice 'PASS  the same amount two months later is not treated as a duplicate';

  select * into v_dup from find_duplicate_document(v_org, v_wells, 'TS-24188', null, null);
  if v_dup.document_id is not null then
    raise exception 'FAIL: duplicate check must be scoped to the supplier';
  end if;
  raise notice 'PASS  duplicate detection is scoped to one supplier';

  -- ---------------------------------------------------------------
  raise notice '--- Validation catches a broken extraction';
  -- ---------------------------------------------------------------

  insert into capture_document (
    organisation_id, storage_path, file_name, mime_type, status, uploaded_by
  ) values (
    v_org, v_org || '/broken.pdf', 'broken.pdf', 'application/pdf', 'uploaded', v_user
  ) returning id into v_cap;

  -- Header says 1240 net but the lines come to 1180. The fixture case.
  insert into capture_extraction (
    organisation_id, capture_document_id, provider, model,
    supplier_name, supplier_vat_number, invoice_number, invoice_date,
    net_total, vat_total, gross_total, currency_code
  ) values (
    v_org, v_cap, 'stub', 'fixtures-v1/broken',
    'Timber Supplies Ltd', 'GB412556721', 'APH-31007', '2026-05-15',
    1240.00, 248.00, 1488.00, 'GBP'
  ) returning id into v_ext;

  insert into capture_extraction_line (
    organisation_id, capture_extraction_id, line_no, description,
    quantity, unit_price, net_amount, vat_rate, vat_amount
  ) values
    (v_org, v_ext, 1, 'Excavator hire', 3, 340, 1020, 20, 204),
    (v_org, v_ext, 2, 'Breaker', 1, 160, 160, 20, 32);

  perform finalise_extraction(v_ext);

  select validation_notes, arithmetic_ok into v_notes, v_flag
    from capture_extraction where id = v_ext;

  if not exists (
    select 1 from jsonb_array_elements(v_notes) n
     where n ->> 'field' = 'lines' and n ->> 'severity' = 'error'
  ) then
    raise exception 'FAIL: lines not summing to the header was not flagged. Notes: %', v_notes;
  end if;
  raise notice 'PASS  lines totalling 1180 against a header of 1240 flagged as an error';

  -- Net + VAT does equal gross here, so that particular check passes.
  if (select arithmetic_ok from capture_extraction where id = v_ext) is not true then
    raise exception 'FAIL: net plus VAT does equal gross on this one';
  end if;
  raise notice 'PASS  net plus VAT equalling gross is reported separately from the line mismatch';

  -- Matching and suggestions ran as part of finalise.
  if (select matched_contact_id from capture_extraction where id = v_ext) <> v_timber then
    raise exception 'FAIL: finalise_extraction did not match the supplier';
  end if;
  if (select count(*) from capture_extraction_line
       where capture_extraction_id = v_ext and suggested_account_id = v_post) <> 2 then
    raise exception 'FAIL: nominal suggestion was not applied to the lines';
  end if;
  if (select count(*) from capture_extraction_line
       where capture_extraction_id = v_ext and suggested_vat_code_id = v_t1) <> 2 then
    raise exception 'FAIL: VAT code suggestion was not applied to the lines';
  end if;
  raise notice 'PASS  finalise matched the supplier and suggested nominal and VAT on both lines';

  if (select status from capture_document where id = v_cap) <> 'extracted' then
    raise exception 'FAIL: the capture should be marked as extracted';
  end if;
  raise notice 'PASS  capture status moved to extracted';

  -- ---------------------------------------------------------------
  raise notice '--- Validation catches missing fields';
  -- ---------------------------------------------------------------

  insert into capture_document (organisation_id, storage_path, file_name, mime_type, status)
  values (v_org, v_org || '/vague.jpg', 'vague.jpg', 'image/jpeg', 'uploaded')
  returning id into v_cap;

  insert into capture_extraction (
    organisation_id, capture_document_id, provider, model, supplier_name
  ) values (v_org, v_cap, 'stub', 'fixtures-v1/sparse', 'Nobody We Know Ltd')
  returning id into v_ext;

  perform finalise_extraction(v_ext);
  select validation_notes into v_notes from capture_extraction where id = v_ext;

  if not exists (select 1 from jsonb_array_elements(v_notes) n where n ->> 'field' = 'invoice_number') then
    raise exception 'FAIL: a missing invoice number was not flagged';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_notes) n where n ->> 'field' = 'supplier') then
    raise exception 'FAIL: an unmatched supplier was not flagged';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_notes) n where n ->> 'field' = 'totals') then
    raise exception 'FAIL: missing totals were not flagged';
  end if;
  raise notice 'PASS  missing number, missing totals and unknown supplier all flagged (% notes)',
    jsonb_array_length(v_notes);

  -- ---------------------------------------------------------------
  raise notice '--- Approval posts to the ledger';
  -- ---------------------------------------------------------------

  insert into capture_document (organisation_id, storage_path, file_name, mime_type, status)
  values (v_org, v_org || '/clean.pdf', 'clean.pdf', 'application/pdf', 'extracted')
  returning id into v_cap;

  select coalesce(sum(jl.credit - jl.debit), 0) into v_n
    from journal_line jl
    join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'creditors';

  v_doc := approve_capture(v_cap, jsonb_build_object(
    'doc_type', 'PI',
    'contact_id', v_timber,
    'date', '2026-05-20',
    'number', 'TS-24999',
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Oak board', 'quantity', 14,
        'unit_price', 62.50, 'account_id', v_post, 'vat_code_id', v_t1))));

  if (select status from capture_document where id = v_cap) <> 'approved' then
    raise exception 'FAIL: capture not marked approved';
  end if;
  if (select document_id from capture_document where id = v_cap) <> v_doc then
    raise exception 'FAIL: capture not linked to the posted document';
  end if;
  raise notice 'PASS  approval posted a bill and linked it back to the file';

  select coalesce(sum(jl.credit - jl.debit), 0) - v_n into v_n
    from journal_line jl
    join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'creditors';

  if v_n <> 1050.00 then
    raise exception 'FAIL: creditors should have moved by 1050.00 (875 + 175 VAT), moved by %', v_n;
  end if;
  raise notice 'PASS  trade creditors moved by exactly 1050.00';

  -- The original file must remain attached to the posted document.
  if (select count(*) from attachment
       where entity_type = 'document' and entity_id = v_doc) <> 1 then
    raise exception 'FAIL: the original file was not attached to the posted document';
  end if;
  raise notice 'PASS  the original file stays attached to the posted bill';

  begin
    perform approve_capture(v_cap, jsonb_build_object(
      'doc_type', 'PI', 'contact_id', v_timber, 'date', '2026-05-20',
      'number', 'TS-25000',
      'lines', jsonb_build_array(jsonb_build_object(
        'description', 'x', 'quantity', 1, 'unit_price', 10,
        'account_id', v_post, 'vat_code_id', v_t1))));
    raise exception 'FAIL: the same capture was approved twice';
  exception when check_violation then
    raise notice 'PASS  approving the same capture twice refused';
  end;

  -- ---------------------------------------------------------------
  raise notice '--- Rejection';
  -- ---------------------------------------------------------------

  insert into capture_document (organisation_id, storage_path, file_name, mime_type, status)
  values (v_org, v_org || '/junk.pdf', 'junk.pdf', 'application/pdf', 'extracted')
  returning id into v_cap;

  perform reject_capture(v_cap, 'Statement, not an invoice');

  if (select status from capture_document where id = v_cap) <> 'rejected' then
    raise exception 'FAIL: rejection did not take';
  end if;
  raise notice 'PASS  a discarded document is marked rejected with a reason';

  -- ---------------------------------------------------------------
  raise notice '--- The ledger is still sound';
  -- ---------------------------------------------------------------

  select sum(debit) into v_n from trial_balance(v_org, '2027-03-31');

  if v_n <> (select sum(credit) from trial_balance(v_org, '2027-03-31')) then
    raise exception 'FAIL: trial balance out of balance after capture activity';
  end if;
  raise notice 'PASS  trial balance still agrees at %', to_char(v_n, 'FM999999990.00');

  select coalesce(sum(jl.credit - jl.debit), 0) into v_n
    from journal_line jl join account a on a.id = jl.account_id
   where jl.organisation_id = v_org and a.control_type = 'creditors';
  select coalesce(sum(case when direction = 'credit' then outstanding_amount
                           else -outstanding_amount end), 0) into v_ledger_total
    from ledger_item_outstanding
   where organisation_id = v_org and ledger = 'purchase';

  if v_n <> v_ledger_total then
    raise exception 'FAIL: creditors % does not agree with the purchase ledger %', v_n, v_ledger_total;
  end if;
  raise notice 'PASS  trade creditors and the purchase ledger still agree at %',
    to_char(v_n, 'FM999999990.00');

  raise notice '';
  raise notice 'All capture tests passed.';
end;
$$;

-- =====================================================================
-- 0023_capture_queue.sql
--
-- Uploading twenty invoices and clicking away lost most of them. Two
-- separate faults, and the second is worse than the first.
--
-- 1. Upload and extraction were welded together in one client-side loop.
--    Navigating away stopped the loop, so files it had not reached yet
--    were never uploaded at all.
--
-- 2. Anything the loop had *started* was set to 'extracting' and left
--    there. The inbox offered no action for that status, so those
--    documents sat reading "Reading" for ever with no way to retry.
--
-- The fix is to treat extraction as a queue rather than a loop. Upload is
-- quick and happens first; extraction is slow and is picked up
-- afterwards, resumably. Nothing is ever in a state it cannot get out
-- of.
-- =====================================================================

alter table capture_document
  add column if not exists extraction_started_at timestamptz,
  add column if not exists extraction_attempts int not null default 0;

create index if not exists capture_document_pending_idx
  on capture_document (organisation_id, status, created_at)
  where status in ('uploaded', 'extracting');

-- ---------------------------------------------------------------------
-- Reclaim anything abandoned mid-extraction
--
-- A document is only 'extracting' while a request is actually running. If
-- it has been that way for several minutes the request is gone — the
-- browser was closed, the function timed out, the network dropped — and
-- the document must become retryable again.
--
-- Called whenever the inbox loads, so a stuck document heals itself
-- rather than waiting for someone to notice.
-- ---------------------------------------------------------------------

create or replace function reclaim_stuck_captures(
  p_organisation_id uuid,
  p_older_than      interval default '5 minutes'
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  if not is_org_member(p_organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  with reclaimed as (
    update capture_document
       set status = case
             -- Three failed attempts is not bad luck. Stop retrying and
             -- say so, rather than looping for ever.
             when extraction_attempts >= 3 then 'failed'
             else 'uploaded'
           end,
           status_detail = case
             when extraction_attempts >= 3
               then 'Reading failed three times. Try again by hand, or enter it manually.'
             else 'Reading was interrupted. Ready to try again.'
           end,
           extraction_started_at = null
     where organisation_id = p_organisation_id
       and status = 'extracting'
       and extraction_started_at < now() - p_older_than
    returning 1
  )
  select count(*) into v_count from reclaimed;

  return v_count;
end;
$$;

grant execute on function reclaim_stuck_captures(uuid, interval) to authenticated;

-- ---------------------------------------------------------------------
-- Claim the next document to read
--
-- Takes one document and marks it as being worked on, atomically, so two
-- browser tabs or two workers cannot pick up the same one. The row lock
-- with SKIP LOCKED is what makes this a queue rather than a race.
-- ---------------------------------------------------------------------

create or replace function claim_next_capture(p_organisation_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not has_org_role(p_organisation_id, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to do this'
      using errcode = 'insufficient_privilege';
  end if;

  select id into v_id
    from capture_document
   where organisation_id = p_organisation_id
     and status = 'uploaded'
   order by created_at
   for update skip locked
   limit 1;

  if v_id is null then
    return null;
  end if;

  update capture_document
     set status = 'extracting',
         extraction_started_at = now(),
         extraction_attempts = extraction_attempts + 1,
         status_detail = null
   where id = v_id;

  return v_id;
end;
$$;

grant execute on function claim_next_capture(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What is left to do
-- ---------------------------------------------------------------------

create or replace function capture_queue_status(p_organisation_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'waiting',     count(*) filter (where status = 'uploaded'),
    'reading',     count(*) filter (where status = 'extracting'),
    'to_check',    count(*) filter (where status = 'extracted'),
    'failed',      count(*) filter (where status = 'failed'),
    'oldest_waiting', min(created_at) filter (where status = 'uploaded')
  )
    from capture_document
   where organisation_id = p_organisation_id
     and status in ('uploaded', 'extracting', 'extracted', 'failed');
$$;

grant execute on function capture_queue_status(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Retrying by hand
-- ---------------------------------------------------------------------

create or replace function retry_capture(p_capture_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
begin
  select organisation_id into v_org from capture_document where id = p_capture_id;

  if v_org is null then
    raise exception 'That document does not exist' using errcode = 'no_data_found';
  end if;

  if not has_org_role(v_org, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to do this'
      using errcode = 'insufficient_privilege';
  end if;

  update capture_document
     set status = 'uploaded',
         status_detail = null,
         extraction_started_at = null,
         -- A deliberate retry resets the counter. Someone who has just
         -- fixed the API key should not be told they are out of attempts.
         extraction_attempts = 0
   where id = p_capture_id
     and status in ('extracting', 'failed', 'uploaded');
end;
$$;

grant execute on function retry_capture(uuid) to authenticated;

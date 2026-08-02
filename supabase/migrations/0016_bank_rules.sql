-- =====================================================================
-- 0016_bank_rules.sql
--
-- Three things the split-screen reconciliation needs.
--
-- 1. Suggestions for every line at once. The old screen fetched them one
--    row at a time when a row was expanded, which is fine when you click
--    into each line and useless when you want to see all the treatments
--    down the page.
--
-- 2. A live count of how many other lines a proposed rule would catch,
--    so someone writing a rule can see its reach before saving it.
--
-- 3. Applying a rule to the lines it already matches. Writing "anything
--    from EDF goes to electricity" and then having to code the other
--    eleven EDF lines by hand would rather miss the point.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Suggestions for a set of lines
--
-- Takes explicit ids rather than a whole account, so the cost is bounded
-- by what is actually on screen.
-- ---------------------------------------------------------------------

create or replace function suggest_matches_bulk(p_line_ids uuid[])
returns table (
  statement_line_id uuid,
  kind       text,
  ref_id     uuid,
  label      text,
  detail     text,
  amount     numeric,
  ref_date   date,
  score      numeric,
  contact_id uuid,
  payload    jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  select sl.id, s.kind, s.ref_id, s.label, s.detail, s.amount,
         s.ref_date, s.score, s.contact_id, s.payload
    from statement_line sl
    cross join lateral suggest_matches_for_line(sl.id) s
   where sl.id = any(p_line_ids)
     and sl.status = 'unmatched'
   order by sl.date, sl.id, s.score desc;
$$;

grant execute on function suggest_matches_bulk(uuid[]) to authenticated;

-- ---------------------------------------------------------------------
-- How far would this rule reach?
--
-- Counts unmatched lines the pattern would catch, excluding the one
-- being worked on. Shown live as the pattern is typed, because a rule
-- that turns out to match forty things is worth knowing about before
-- it is saved rather than after.
-- ---------------------------------------------------------------------

create or replace function preview_rule_matches(
  p_organisation_id uuid,
  p_bank_account_id uuid,
  p_pattern         text,
  p_match_type      text default 'contains',
  p_direction       text default 'any',
  p_exclude_line_id uuid default null
) returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
    from statement_line sl
   where sl.organisation_id = p_organisation_id
     and sl.status = 'unmatched'
     and (p_bank_account_id is null or sl.bank_account_id = p_bank_account_id)
     and (p_exclude_line_id is null or sl.id <> p_exclude_line_id)
     and coalesce(nullif(btrim(p_pattern), ''), '\x00') <> '\x00'
     and (
       p_direction = 'any'
       or (p_direction = 'in'  and sl.amount > 0)
       or (p_direction = 'out' and sl.amount < 0)
     )
     and (
       (p_match_type = 'contains'    and sl.description ilike '%' || p_pattern || '%')
       or (p_match_type = 'starts_with' and sl.description ilike p_pattern || '%')
       or (p_match_type = 'exact'       and lower(btrim(sl.description)) = lower(btrim(p_pattern)))
       or (p_match_type = 'regex'       and sl.description ~* p_pattern)
     );
$$;

grant execute on function preview_rule_matches(uuid, uuid, text, text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Save a rule from a coding decision
--
-- Kept separate from create_from_statement_line() so the interface can
-- offer "save this as a rule" as its own explicit act rather than a
-- side effect of coding one line.
-- ---------------------------------------------------------------------

create or replace function create_match_rule(p_config jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org  uuid := (p_config ->> 'organisation_id')::uuid;
  v_id   uuid;
begin
  if not is_org_member(v_org) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(nullif(btrim(p_config ->> 'pattern'), ''), '') = '' then
    raise exception 'A rule needs something to match on' using errcode = 'check_violation';
  end if;

  if nullif(p_config ->> 'account_id', '') is null then
    raise exception 'A rule needs a category to code to' using errcode = 'check_violation';
  end if;

  insert into match_rule (
    organisation_id, bank_account_id, name, priority,
    match_type, pattern, direction,
    account_id, contact_id, vat_code_id, description_template, auto_apply
  ) values (
    v_org,
    nullif(p_config ->> 'bank_account_id', '')::uuid,
    nullif(p_config ->> 'name', ''),
    coalesce((p_config ->> 'priority')::int, 100),
    coalesce(nullif(p_config ->> 'match_type', ''), 'contains'),
    btrim(p_config ->> 'pattern'),
    coalesce(nullif(p_config ->> 'direction', ''), 'any'),
    (p_config ->> 'account_id')::uuid,
    nullif(p_config ->> 'contact_id', '')::uuid,
    nullif(p_config ->> 'vat_code_id', '')::uuid,
    nullif(p_config ->> 'description_template', ''),
    coalesce((p_config ->> 'auto_apply')::boolean, false)
  )
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function create_match_rule(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- Apply a rule to everything it already matches
--
-- Codes each unmatched line the rule catches, using the rule's own
-- category and VAT treatment. Returns how many were dealt with.
--
-- Deliberately skips anything that fails rather than aborting the lot:
-- one line falling in a closed period should not undo the other eleven.
-- ---------------------------------------------------------------------

create or replace function apply_rule_to_unmatched(
  p_rule_id         uuid,
  p_bank_account_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule    match_rule;
  v_line    record;
  v_done    int := 0;
  v_failed  int := 0;
  v_first   text;
begin
  select * into v_rule from match_rule where id = p_rule_id;

  if not found or not is_org_member(v_rule.organisation_id) then
    raise exception 'That rule does not exist' using errcode = 'no_data_found';
  end if;

  for v_line in
    select sl.id
      from statement_line sl
     where sl.organisation_id = v_rule.organisation_id
       and sl.status = 'unmatched'
       and (coalesce(p_bank_account_id, v_rule.bank_account_id) is null
            or sl.bank_account_id = coalesce(p_bank_account_id, v_rule.bank_account_id))
       and (v_rule.direction = 'any'
            or (v_rule.direction = 'in'  and sl.amount > 0)
            or (v_rule.direction = 'out' and sl.amount < 0))
       and (
         (v_rule.match_type = 'contains'    and sl.description ilike '%' || v_rule.pattern || '%')
         or (v_rule.match_type = 'starts_with' and sl.description ilike v_rule.pattern || '%')
         or (v_rule.match_type = 'exact'       and lower(btrim(sl.description)) = lower(btrim(v_rule.pattern)))
         or (v_rule.match_type = 'regex'       and sl.description ~* v_rule.pattern)
       )
     order by sl.date
  loop
    begin
      perform create_from_statement_line(v_line.id, jsonb_build_object(
        'kind', 'nominal',
        'account_id', v_rule.account_id,
        'vat_code_id', v_rule.vat_code_id,
        'contact_id', v_rule.contact_id,
        'rule_id', v_rule.id
      ));
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed + 1;
      if v_first is null then
        v_first := sqlerrm;
      end if;
    end;
  end loop;

  -- create_from_statement_line() already counts a hit for each line it
  -- codes with a rule_id, so only the timestamp is touched here. Adding
  -- v_done as well would double count and push a rule up the ordering
  -- for work it did once.
  if v_done > 0 then
    update match_rule set last_used_at = now() where id = p_rule_id;
  end if;

  return jsonb_build_object('applied', v_done, 'failed', v_failed, 'first_error', v_first);
end;
$$;

grant execute on function apply_rule_to_unmatched(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- A sensible default pattern from a bank description
--
-- Bank descriptions carry a stable prefix and a volatile tail: card
-- numbers, dates, payment references. "EDF ENERGY DD 4471" should
-- suggest "EDF ENERGY", not the whole string, or the rule will never
-- fire again.
-- ---------------------------------------------------------------------

create or replace function suggest_rule_pattern(p_description text)
returns text
language plpgsql
immutable
as $$
declare
  v_clean text;
  v_words text[];
  v_out   text[] := '{}';
  v_word  text;
  -- Transaction-type markers banks bolt on. They carry no digits so a
  -- digit test alone leaves them in, and "EDF ENERGY DD" as a pattern is
  -- brittle in a way "EDF ENERGY" is not.
  v_noise text[] := array[
    'DD','SO','BP','BAC','BACS','CHQ','CHEQUE','TFR','TRF','FP','FPI','FPO',
    'CRD','CARD','POS','ATM','DEB','CR','DR','PMT','PAYMENT','REF','TX','TXN',
    'VIS','MC','DIRECT','DEBIT','STANDING','ORDER','FASTER','ONLINE',
    'PMTS','TO','FROM','AT','VIA','THE','PURCHASE','TRANSFER'
  ];
  v_token text;
begin
  v_clean := btrim(regexp_replace(coalesce(p_description, ''), '\s+', ' ', 'g'));

  if v_clean = '' then
    return '';
  end if;

  v_words := string_to_array(v_clean, ' ');

  foreach v_word in array v_words
  loop
    -- A digit or a lone character means the reference has started, and
    -- everything after it is volatile.
    exit when v_word ~ '[0-9]' or length(v_word) <= 1;

    v_token := upper(regexp_replace(v_word, '[^A-Za-z]', '', 'g'));

    if v_token = any(v_noise) then
      -- Leading markers like "DD" or "CARD PAYMENT TO" are skipped so the
      -- real name is still found. Once the name has started, a marker
      -- means the name has finished.
      if array_length(v_out, 1) is null then
        continue;
      else
        exit;
      end if;
    end if;

    v_out := v_out || v_word;
    exit when array_length(v_out, 1) >= 4;
  end loop;

  if array_length(v_out, 1) is null then
    -- Everything looked like a reference. Fall back to the first chunk.
    return left(v_clean, 18);
  end if;

  return array_to_string(v_out, ' ');
end;
$$;

grant execute on function suggest_rule_pattern(text) to authenticated;

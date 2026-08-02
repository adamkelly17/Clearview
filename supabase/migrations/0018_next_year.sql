-- =====================================================================
-- 0018_next_year.sql
--
-- Rolling on to the next financial year.
--
-- Worth being clear about two things that get conflated:
--
--   Adding the next year   creates the periods so you can carry on
--                          posting. Nothing else changes.
--
--   Closing a year         rolls the profit into reserves, locks the
--                          periods and produces the final accounts.
--                          That is the year-end routine, still to come.
--
-- You do the first the moment the calendar rolls over. You do the second
-- months later, once the accounts are agreed. Businesses trade through
-- the gap, so two open years side by side is normal and not a mistake.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What would the next year look like?
-- ---------------------------------------------------------------------

create or replace function next_fiscal_year_preview(p_organisation_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org    organisation;
  v_last   fiscal_year;
  v_start  date;
  v_end    date;
  v_periods int := 0;
  v_cursor date;
begin
  if not is_org_member(p_organisation_id) then
    raise exception 'You do not have access to this organisation'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_org from organisation where id = p_organisation_id;

  select * into v_last
    from fiscal_year
   where organisation_id = p_organisation_id
   order by end_date desc
   limit 1;

  if not found then
    return jsonb_build_object('available', false,
      'message', 'No financial year exists yet. Finish setting the business up first.');
  end if;

  v_start := v_last.end_date + 1;

  -- Subsequent years are unambiguous: the next time the year end date
  -- comes round after the year starts.
  v_end := year_end_on(extract(year from v_start)::int, v_org.year_end_day, v_org.year_end_month);
  if v_end < v_start then
    v_end := year_end_on(extract(year from v_start)::int + 1, v_org.year_end_day, v_org.year_end_month);
  end if;

  v_cursor := v_start;
  while v_cursor <= v_end and v_periods < 24 loop
    v_periods := v_periods + 1;
    v_cursor := least(
      (date_trunc('month', v_cursor) + interval '1 month' - interval '1 day')::date,
      v_end) + 1;
  end loop;

  return jsonb_build_object(
    'available', true,
    'start_date', v_start,
    'end_date', v_end,
    'periods', v_periods,
    'months', round((v_end - v_start) / 30.44, 1),
    'previous_end', v_last.end_date,
    'previous_status', v_last.status,
    -- True once the current year is over, which is when this stops being
    -- optional and starts being urgent.
    'overdue', current_date > v_last.end_date,
    'days_remaining', v_last.end_date - current_date
  );
end;
$$;

grant execute on function next_fiscal_year_preview(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Create it
--
-- Always runs on from the day after the last year ends. A gap between
-- financial years would mean transactions on the days in between could
-- never be posted, and nothing would warn you until someone tried.
-- ---------------------------------------------------------------------

create or replace function create_next_fiscal_year(
  p_organisation_id uuid,
  p_end_date        date default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_preview jsonb;
  v_start   date;
  v_end     date;
  v_id      uuid;
begin
  if not has_org_role(p_organisation_id, array['owner', 'admin', 'bookkeeper']) then
    raise exception 'You do not have permission to add a financial year'
      using errcode = 'insufficient_privilege';
  end if;

  v_preview := next_fiscal_year_preview(p_organisation_id);

  if not (v_preview ->> 'available')::boolean then
    raise exception '%', v_preview ->> 'message' using errcode = 'no_data_found';
  end if;

  v_start := (v_preview ->> 'start_date')::date;
  v_end := coalesce(p_end_date, (v_preview ->> 'end_date')::date);

  -- create_fiscal_year() handles the overlap check, the eighteen month
  -- limit and the monthly periods.
  v_id := create_fiscal_year(p_organisation_id, v_start, v_end);

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (p_organisation_id, auth.uid(), 'fiscal_year', v_id::text, 'created',
          jsonb_build_object('start_date', v_start, 'end_date', v_end));

  return jsonb_build_object(
    'fiscal_year_id', v_id,
    'start_date', v_start,
    'end_date', v_end,
    'periods', (select count(*) from period where fiscal_year_id = v_id)
  );
end;
$$;

grant execute on function create_next_fiscal_year(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- A more useful error when there is nowhere to post
--
-- The old message said "Add the financial year first", which is correct
-- but does not say where. Someone hitting this in April, having been
-- posting happily all year, needs to be told exactly what to do.
-- ---------------------------------------------------------------------

create or replace function resolve_period(
  p_organisation_id uuid,
  p_date            date
) returns period
language plpgsql
stable
as $$
declare
  v_period period;
  v_last   date;
begin
  select * into v_period
    from period
   where organisation_id = p_organisation_id
     and p_date between start_date and end_date;

  if not found then
    select max(end_date) into v_last
      from fiscal_year where organisation_id = p_organisation_id;

    if v_last is not null and p_date > v_last then
      raise exception
        'Your financial years run up to %. Add the next one under Settings before posting into %.',
        to_char(v_last, 'DD/MM/YYYY'), to_char(p_date, 'DD/MM/YYYY')
        using errcode = 'no_data_found';
    end if;

    raise exception
      'There is no accounting period covering %. Your books start later than that.',
      to_char(p_date, 'DD/MM/YYYY')
      using errcode = 'no_data_found';
  end if;

  if v_period.status <> 'open' then
    raise exception
      'The period % is %. Reopen it under Settings, or use a different date.',
      v_period.name, v_period.status
      using errcode = 'insufficient_privilege';
  end if;

  return v_period;
end;
$$;

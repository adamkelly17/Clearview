-- =====================================================================
-- 0017_change_year_end.sql
--
-- Changing a financial year end after the books have been started.
--
-- Needed immediately because organisations set up before 0011 got the
-- wrong first year end. Worth building properly rather than patching by
-- hand, because it is a real thing businesses do: Companies House lets a
-- company shorten its year as often as it likes and extend it once every
-- five years, and an accountant will want to follow suit here.
--
-- Extending adds the missing periods. Shortening removes them, but only
-- if nothing has been posted into them — a period with transactions in
-- it cannot simply disappear.
-- =====================================================================

create or replace function change_fiscal_year_end(
  p_fiscal_year_id uuid,
  p_new_end_date   date,
  p_update_pattern boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year     fiscal_year;
  v_org      organisation;
  v_old_end  date;
  v_months   numeric;
  v_blocked  int;
  v_removed  int := 0;
  v_added    int := 0;
  v_next_no  int;
  v_p_start  date;
  v_p_end    date;
  v_last_end date;
begin
  select * into v_year from fiscal_year where id = p_fiscal_year_id;

  if not found then
    raise exception 'That financial year does not exist' using errcode = 'no_data_found';
  end if;

  if not has_org_role(v_year.organisation_id, array['owner', 'admin']) then
    raise exception 'Only an owner or admin can change the financial year end'
      using errcode = 'insufficient_privilege';
  end if;

  if v_year.status <> 'open' then
    raise exception 'That year has been closed and cannot be changed'
      using errcode = 'check_violation';
  end if;

  select * into v_org from organisation where id = v_year.organisation_id;

  v_old_end := v_year.end_date;

  if p_new_end_date = v_old_end then
    return jsonb_build_object('changed', false, 'message', 'That is already the year end.');
  end if;

  if p_new_end_date <= v_year.start_date then
    raise exception 'The year end must be after % , the day the year starts',
      to_char(v_year.start_date, 'DD/MM/YYYY')
      using errcode = 'check_violation';
  end if;

  v_months := (p_new_end_date - v_year.start_date) / 30.44;

  if v_months > 18.5 then
    raise exception
      'That would make the year about % months long. Eighteen is the limit.',
      round(v_months)
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1 from fiscal_year
     where organisation_id = v_year.organisation_id
       and id <> p_fiscal_year_id
       and v_year.start_date <= end_date
       and p_new_end_date >= start_date
  ) then
    raise exception 'That would overlap another financial year'
      using errcode = 'unique_violation';
  end if;

  -- ---------------- Shortening -------------------------------------
  if p_new_end_date < v_old_end then

    select count(*) into v_blocked
      from journal j
      join period p on p.id = j.period_id
     where p.fiscal_year_id = p_fiscal_year_id
       and j.date > p_new_end_date;

    if v_blocked > 0 then
      raise exception
        'There % already posted after %. Reverse or re-date % before shortening the year.',
        case when v_blocked = 1 then 'is 1 transaction' else 'are ' || v_blocked || ' transactions' end,
        to_char(p_new_end_date, 'DD/MM/YYYY'),
        case when v_blocked = 1 then 'it' else 'them' end
        using errcode = 'check_violation';
    end if;

    delete from period
     where fiscal_year_id = p_fiscal_year_id
       and start_date > p_new_end_date;

    get diagnostics v_removed = row_count;

    -- Trim the period that straddles the new year end.
    update period
       set end_date = p_new_end_date
     where fiscal_year_id = p_fiscal_year_id
       and start_date <= p_new_end_date
       and end_date > p_new_end_date;

  -- ---------------- Extending --------------------------------------
  else
    select max(end_date), coalesce(max(period_no), 0)
      into v_last_end, v_next_no
      from period where fiscal_year_id = p_fiscal_year_id;

    -- If the final period ends mid-month, run it to the end of its month
    -- first so the added periods tile cleanly from there.
    if v_last_end is null then
      v_p_start := v_year.start_date;
    else
      v_p_end := least(
        (date_trunc('month', v_last_end) + interval '1 month' - interval '1 day')::date,
        p_new_end_date);

      if v_p_end > v_last_end then
        update period set end_date = v_p_end
         where fiscal_year_id = p_fiscal_year_id and end_date = v_last_end;
        v_last_end := v_p_end;
      end if;

      v_p_start := v_last_end + 1;
    end if;

    v_next_no := v_next_no + 1;

    while v_p_start <= p_new_end_date loop
      v_p_end := least(
        (date_trunc('month', v_p_start) + interval '1 month' - interval '1 day')::date,
        p_new_end_date);

      insert into period (
        organisation_id, fiscal_year_id, period_no, name, start_date, end_date
      ) values (
        v_year.organisation_id, p_fiscal_year_id, v_next_no,
        to_char(v_p_start, 'Mon YYYY'), v_p_start, v_p_end
      );

      v_added := v_added + 1;
      v_next_no := v_next_no + 1;
      v_p_start := v_p_end + 1;
    end loop;
  end if;

  update fiscal_year
     set end_date = p_new_end_date,
         name = case
           when extract(year from p_new_end_date) <> extract(year from v_year.start_date)
             then to_char(v_year.start_date, 'YYYY') || '/' || to_char(p_new_end_date, 'YY')
           else to_char(p_new_end_date, 'YYYY')
         end
   where id = p_fiscal_year_id;

  -- Future years follow the new pattern unless told otherwise.
  if p_update_pattern then
    update organisation
       set year_end_day = extract(day from p_new_end_date)::int,
           year_end_month = extract(month from p_new_end_date)::int
     where id = v_year.organisation_id;
  end if;

  insert into audit_log (organisation_id, user_id, table_name, record_id, action, detail)
  values (v_year.organisation_id, auth.uid(), 'fiscal_year', p_fiscal_year_id::text,
          'year_end_changed',
          jsonb_build_object('from', v_old_end, 'to', p_new_end_date,
                             'periods_added', v_added, 'periods_removed', v_removed));

  return jsonb_build_object(
    'changed', true,
    'from', v_old_end,
    'to', p_new_end_date,
    'periods_added', v_added,
    'periods_removed', v_removed,
    'months', round(v_months, 1)
  );
end;
$$;

grant execute on function change_fiscal_year_end(uuid, date, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- What would happen if I changed it to this?
--
-- Lets the interface warn about transactions in the way before anything
-- is altered, rather than surfacing it as an error afterwards.
-- ---------------------------------------------------------------------

create or replace function preview_year_end_change(
  p_fiscal_year_id uuid,
  p_new_end_date   date
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_year    fiscal_year;
  v_blocked int := 0;
  v_periods int := 0;
  v_months  numeric;
  v_cursor  date;
begin
  select * into v_year from fiscal_year where id = p_fiscal_year_id;

  if not found or not is_org_member(v_year.organisation_id) then
    raise exception 'That financial year does not exist' using errcode = 'no_data_found';
  end if;

  if p_new_end_date <= v_year.start_date then
    return jsonb_build_object('valid', false,
      'message', 'The year end has to be after the day the year starts.');
  end if;

  v_months := (p_new_end_date - v_year.start_date) / 30.44;

  if v_months > 18.5 then
    return jsonb_build_object('valid', false,
      'message', format('That would be about %s months. Eighteen is the limit.', round(v_months)));
  end if;

  if p_new_end_date < v_year.end_date then
    select count(*) into v_blocked
      from journal j
      join period p on p.id = j.period_id
     where p.fiscal_year_id = p_fiscal_year_id
       and j.date > p_new_end_date;
  end if;

  -- Count the months the year would span.
  v_cursor := v_year.start_date;
  while v_cursor <= p_new_end_date and v_periods < 24 loop
    v_periods := v_periods + 1;
    v_cursor := least(
      (date_trunc('month', v_cursor) + interval '1 month' - interval '1 day')::date,
      p_new_end_date) + 1;
  end loop;

  return jsonb_build_object(
    'valid', v_blocked = 0,
    'blocking_transactions', v_blocked,
    'periods', v_periods,
    'months', round(v_months, 1),
    'direction', case when p_new_end_date > v_year.end_date then 'extend' else 'shorten' end,
    'message', case
      when v_blocked > 0 then
        format('%s already posted after that date. Reverse or re-date %s first.',
          case when v_blocked = 1 then '1 transaction is' else v_blocked || ' transactions are' end,
          case when v_blocked = 1 then 'it' else 'them' end)
      else null
    end
  );
end;
$$;

grant execute on function preview_year_end_change(uuid, date) to authenticated;

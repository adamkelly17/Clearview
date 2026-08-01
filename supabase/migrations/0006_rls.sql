-- =====================================================================
-- 0006_rls.sql
-- Row level security.
--
-- Two principles:
--   1. Reference data (entity types, account types, currencies) is
--      readable by anyone signed in and writable by no one.
--   2. Everything else is visible only to members of the owning
--      organisation. Ledger tables are read-only through the API —
--      the ONLY way to write to them is post_journal(), which runs
--      security definer.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------

alter table entity_type  enable row level security;
alter table currency     enable row level security;
alter table account_type enable row level security;

create policy "reference data is readable" on entity_type
  for select to authenticated using (true);
create policy "reference data is readable" on currency
  for select to authenticated using (true);
create policy "reference data is readable" on account_type
  for select to authenticated using (true);

-- ---------------------------------------------------------------------
-- Organisation
-- ---------------------------------------------------------------------

alter table organisation         enable row level security;
alter table organisation_user    enable row level security;
alter table organisation_feature enable row level security;

create policy "members can see their organisation" on organisation
  for select to authenticated
  using (is_org_member(id));

create policy "owners and admins can update" on organisation
  for update to authenticated
  using (has_org_role(id, array['owner', 'admin']))
  with check (has_org_role(id, array['owner', 'admin']));

-- Insert goes through create_organisation(), which is security
-- definer. Nothing inserts here directly.

create policy "members can see the member list" on organisation_user
  for select to authenticated
  using (is_org_member(organisation_id));

create policy "owners manage members" on organisation_user
  for all to authenticated
  using (has_org_role(organisation_id, array['owner', 'admin']))
  with check (has_org_role(organisation_id, array['owner', 'admin']));

create policy "members read features" on organisation_feature
  for select to authenticated
  using (is_org_member(organisation_id));

create policy "owners change features" on organisation_feature
  for update to authenticated
  using (has_org_role(organisation_id, array['owner', 'admin']))
  with check (has_org_role(organisation_id, array['owner', 'admin']));

-- ---------------------------------------------------------------------
-- Chart of accounts, periods, VAT codes: members read, non-viewers write
-- ---------------------------------------------------------------------

alter table account     enable row level security;
alter table fiscal_year enable row level security;
alter table period      enable row level security;
alter table vat_code    enable row level security;
alter table number_sequence enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['account', 'fiscal_year', 'period', 'vat_code', 'number_sequence']
  loop
    execute format($f$
      create policy "members read %1$s" on %1$I
        for select to authenticated
        using (is_org_member(organisation_id));

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

-- System accounts cannot be renamed away or deactivated.
create or replace function protect_system_accounts()
returns trigger
language plpgsql
as $$
begin
  if old.is_system and (new.is_system = false or new.control_type is distinct from old.control_type) then
    raise exception 'This account is part of the system and cannot be changed'
      using errcode = 'insufficient_privilege';
  end if;
  if old.is_system and new.active = false then
    raise exception 'This account is part of the system and cannot be deactivated'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger account_protect_system
  before update on account
  for each row execute function protect_system_accounts();

-- ---------------------------------------------------------------------
-- The ledger: read only through the API
-- ---------------------------------------------------------------------

alter table journal      enable row level security;
alter table journal_line enable row level security;
alter table audit_log    enable row level security;

create policy "members read journals" on journal
  for select to authenticated
  using (is_org_member(organisation_id));

create policy "members read journal lines" on journal_line
  for select to authenticated
  using (is_org_member(organisation_id));

create policy "members read the audit log" on audit_log
  for select to authenticated
  using (is_org_member(organisation_id));

-- Deliberately NO insert, update or delete policy on journal or
-- journal_line. Even a compromised client key cannot write to the
-- ledger. post_journal() is the only door.

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

revoke all on function post_journal(uuid, date, text, jsonb, text, text, uuid, text, numeric) from public;
grant execute on function post_journal(uuid, date, text, jsonb, text, text, uuid, text, numeric) to authenticated;

revoke all on function reverse_journal(uuid, date, text) from public;
grant execute on function reverse_journal(uuid, date, text) to authenticated;

revoke all on function create_organisation(jsonb) from public;
grant execute on function create_organisation(jsonb) to authenticated;

grant execute on function trial_balance(uuid, date, date) to authenticated;
grant execute on function account_activity(uuid, uuid, date, date) to authenticated;
grant execute on function create_fiscal_year(uuid, date) to authenticated;
grant execute on function next_document_number(uuid, text) to authenticated;
grant execute on function is_org_member(uuid) to authenticated;
grant execute on function has_org_role(uuid, text[]) to authenticated;

-- These two are called by modules, not by the browser.
revoke all on function set_line_reconciled(uuid, uuid, boolean) from public;
revoke all on function set_lines_vat_return(uuid[], uuid) from public;
revoke all on function seed_chart_of_accounts(uuid, text) from public;
revoke all on function seed_vat_codes(uuid) from public;

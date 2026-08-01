-- =====================================================================
-- 0010_trading_rls.sql
--
-- Contacts are ordinary data: members read, staff write.
--
-- Documents, ledger items and allocations are ledger data. They are
-- read-only through the API for the same reason journal lines are:
-- the only way to create one is through post_document(),
-- post_payment() or allocate_items(), each of which posts to the
-- nominal ledger in the same transaction. Letting the browser insert a
-- ledger_item directly would let it create a debtor balance with no
-- matching journal, and the control account would stop agreeing.
--
-- Draft documents are the one exception: they post nothing, so they
-- can be edited and deleted freely.
-- =====================================================================

alter table contact         enable row level security;
alter table contact_address enable row level security;
alter table document        enable row level security;
alter table document_line   enable row level security;
alter table ledger_item     enable row level security;
alter table allocation      enable row level security;

-- ---------------------------------------------------------------------
-- Contacts
-- ---------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['contact', 'contact_address']
  loop
    execute format($f$
      create policy "members read %1$s" on %1$I
        for select to authenticated
        using (is_org_member(organisation_id));

      create policy "staff insert %1$s" on %1$I
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

-- ---------------------------------------------------------------------
-- Documents: read always, write only while draft
-- ---------------------------------------------------------------------

create policy "members read documents" on document
  for select to authenticated
  using (is_org_member(organisation_id));

create policy "staff create drafts" on document
  for insert to authenticated
  with check (
    has_org_role(organisation_id, array['owner','admin','bookkeeper'])
    and status = 'draft'
  );

create policy "staff edit drafts" on document
  for update to authenticated
  using (
    has_org_role(organisation_id, array['owner','admin','bookkeeper'])
    and status = 'draft'
  )
  with check (
    has_org_role(organisation_id, array['owner','admin','bookkeeper'])
    and status = 'draft'
  );

create policy "staff delete drafts" on document
  for delete to authenticated
  using (
    has_org_role(organisation_id, array['owner','admin','bookkeeper'])
    and status = 'draft'
  );

create policy "members read document lines" on document_line
  for select to authenticated
  using (is_org_member(organisation_id));

create policy "staff write draft lines" on document_line
  for all to authenticated
  using (
    has_org_role(organisation_id, array['owner','admin','bookkeeper'])
    and exists (
      select 1 from document d
       where d.id = document_line.document_id and d.status = 'draft'
    )
  )
  with check (
    has_org_role(organisation_id, array['owner','admin','bookkeeper'])
    and exists (
      select 1 from document d
       where d.id = document_line.document_id and d.status = 'draft'
    )
  );

-- ---------------------------------------------------------------------
-- Settlement layer: read only
-- ---------------------------------------------------------------------

create policy "members read ledger items" on ledger_item
  for select to authenticated
  using (is_org_member(organisation_id));

create policy "members read allocations" on allocation
  for select to authenticated
  using (is_org_member(organisation_id));

-- Deliberately no insert, update or delete. post_payment(),
-- post_document() and allocate_items() are the only routes in.

-- ---------------------------------------------------------------------
-- A posted document cannot be altered
-- ---------------------------------------------------------------------

create or replace function forbid_posted_document_change()
returns trigger
language plpgsql
as $$
begin
  if current_setting('app.ledger_unlocked', true) = 'on' then
    return coalesce(new, old);
  end if;

  if old.status = 'posted' then
    if tg_op = 'DELETE' then
      raise exception
        'A posted document cannot be deleted. Raise a credit note instead.'
        using errcode = 'insufficient_privilege';
    end if;

    -- Only the PDF path and the void flag may change afterwards.
    if new.doc_type    is distinct from old.doc_type
       or new.contact_id  is distinct from old.contact_id
       or new.number      is distinct from old.number
       or new.date        is distinct from old.date
       or new.net_total   is distinct from old.net_total
       or new.vat_total   is distinct from old.vat_total
       or new.gross_total is distinct from old.gross_total
       or new.journal_id  is distinct from old.journal_id then
      raise exception
        'A posted document cannot be changed. Raise a credit note instead.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

create trigger document_posted_immutable
  before update or delete on document
  for each row execute function forbid_posted_document_change();

-- Note: the guard only bites once a document is posted. post_document()
-- inserts the document as a draft and flips it to posted in the same
-- transaction, so that step passes through untouched.

grant select on ledger_item_outstanding to authenticated;

# Ledger — Phases 1 and 2

A double-entry accounting system on Next.js 14, Supabase and Vercel.

Phase 1 is the foundation: nominal ledger, posting engine, setup wizard,
manual transactions, trial balance.

Phase 2 is the trading layer: customers, suppliers, invoices, bills, credit
notes, receipts, payments, allocation, statements and aged analysis.

Banking, VAT returns and the year-end close are phase 3.

**The checkpoint:** raise an invoice, record a part payment against it, then
open aged debtors and the trial balance side by side. The aged debtors total
and trade debtors must be the same number. If they are, the settlement layer
is sound and the rest is screens.

---

## Getting it running

### 1. Supabase

Create a project, then open the **SQL Editor** and run each migration in
order, one at a time, checking each succeeds before the next:

```
supabase/migrations/0001_core.sql
supabase/migrations/0002_ledger.sql
supabase/migrations/0003_posting.sql
supabase/migrations/0004_setup.sql
supabase/migrations/0005_vat.sql
supabase/migrations/0006_rls.sql
supabase/migrations/0007_contacts.sql
supabase/migrations/0008_trading.sql
supabase/migrations/0009_trading_posting.sql
supabase/migrations/0010_trading_rls.sql
```

Order matters. `0003` depends on the helper functions in `0001`, `0006`
grants execute on functions defined in `0003`, and `0009` calls
`post_journal()` from `0003`.

If you have already run `0001` to `0006` on a live project, `0007` to `0010`
apply on top without touching existing data.

Then under **Authentication → Providers**, make sure Email is enabled. The
app signs people in with a magic link, so no password configuration is
needed.

Under **Authentication → URL Configuration**, add your Vercel URL and
`http://localhost:3000` to the redirect allow list, both with `/auth/callback`
on the end.

### 2. Environment

Copy `.env.example` to `.env.local` and fill in the two values from
**Project Settings → API**:

```
NEXT_PUBLIC_SUPABASE_URL=https://yourproject.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
```

### 3. Local

```bash
npm install
npm run dev
```

### 4. Vercel

Push to GitHub, import the repo, add the same two environment variables.
Nothing else to configure.

---

## Testing the ledger

The database rules are covered by a test suite that runs against any
Postgres 16. It stubs the parts of Supabase it needs:

```bash
createdb ledgertest
psql -d ledgertest -f supabase/test/00_stub_supabase.sql
for f in supabase/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -d ledgertest -f "$f"; done
psql -d ledgertest -f supabase/test/01_ledger_test.sql
psql -d ledgertest -f supabase/test/02_trading_test.sql
```

Forty-five assertions across the two files.

`01_ledger_test.sql` covers chart of accounts seeding, period generation,
balance enforcement, control account protection, period locking,
immutability of posted entries, reversal, double-reversal rejection, trial
balance agreement, currency rounding and journal numbering.

`02_trading_test.sql` covers invoice and bill posting, VAT at standard and
zero rate, quantity and discount arithmetic, the CIS domestic reverse
charge, credit notes, automatic allocation oldest-first, part payment,
over-allocation refusal, cross-contact allocation refusal, statements, aged
analysis, and — the important one — that the trade debtors and trade
creditors control accounts agree exactly with their sub-ledgers.

Do not run `00_stub_supabase.sql` against a real Supabase project.

---

## The rules this is built on

These four are enforced in the database, not in application code, which
means they hold even if the front end has a bug or someone hits the API
directly with a stolen key.

**1. Every journal balances.** A deferred constraint trigger checks that
debits equal credits at commit. There is no way to store a journal that
does not.

**2. Posted entries are immutable.** `UPDATE` and `DELETE` on `journal` and
`journal_line` raise an exception. A mistake is corrected by
`reverse_journal()`, which posts the mirror image and links the two
together. Both stay on the record for ever.

**3. There is exactly one door into the ledger.** `post_journal()`. There
is deliberately no insert policy on `journal` or `journal_line`, so the
browser cannot write to them at all. When you build the sales module, it
calls `post_journal()`. When you build banking, it calls `post_journal()`.
No exceptions — this is the rule that keeps the audit trail honest, and
it is the one that is painful to reinstate once broken.

**4. Nothing posts into a closed period.** Resolved and checked inside
`post_journal()`.

Two further guards worth knowing about: control accounts (debtors,
creditors, VAT, retained earnings) reject manual postings and can only be
written to by a module, and system accounts cannot be renamed or
deactivated.

---

## Configuration model

Nothing about VAT, stock, multi-currency or departments changes the shape
of the database. Every column exists from day one; the flags in
`organisation_feature` only change what the interface offers.

This is deliberate. A business that registers for VAT in year three, or
starts holding stock, or wins its first export customer, switches a toggle.
There is no data migration and nothing already recorded changes.

The same applies to `accountant_mode`. With it off, the interface hides
nominal codes and says "where the money came from" instead of "credit".
With it on, it looks like a ledger. Same data, same tables.

---

## What is here

| Area | Status |
|------|--------|
| Multi-tenant schema with RLS | Built |
| Setup wizard (5 business types, VAT, stock, currency) | Built |
| UK chart of accounts, seeded per business type | Built |
| Financial years and monthly periods | Built |
| Posting engine, reversal, immutability | Built |
| Manual transactions with the balance beam | Built |
| Trial balance | Built |
| Chart of accounts viewer | Built |
| Settings with live feature toggles | Built |
| Customers and suppliers (one record can be both) | Built |
| Sales invoices and credit notes | Built |
| Purchase bills and credit notes | Built |
| Receipts, payments and allocation | Built |
| Customer statements | Built |
| Aged debtors and aged creditors | Built |
| CIS domestic reverse charge | Built |
| Invoice PDFs | Phase 2b |
| Quotes and purchase orders | Phase 2b |
| Banking, import, reconciliation | Phase 3 |
| VAT return calculation | Phase 3 |
| P&L, balance sheet, year-end close | Phase 3 |
| Stock, fixed assets, recurring, departments | Phase 4 |
| MTD submission, live bank feeds | Later |

## The settlement layer

This is the part of the specification worth re-reading, because it is where
home-grown accounting systems usually go wrong.

`ledger_item` holds one row for every single thing that can be settled: an
invoice, a credit note, a receipt, a payment on account. `allocation` links
a debit item to a credit item for an amount. Outstanding balance is
`gross_amount` less what has been allocated, exposed through the
`ledger_item_outstanding` view.

Aged debtors, aged creditors, statements, remittances and credit control all
read that one view. The consequence is that "how much does this customer
owe" is written once and only once.

`allocate_items()` refuses to over-allocate either side and refuses to match
items belonging to different contacts. Those two guards are what keep the
control account agreeing with the sub-ledger, which is the property the test
suite checks explicitly.

## VAT treatment

Line amounts are recalculated in the database from quantity, price, discount
and VAT code every time a document is posted. The browser's arithmetic is
never what ends up in the ledger.

The domestic reverse charge is worth knowing about since it is the one most
often got wrong. On a **sale** under the reverse charge, no VAT is charged at
all — the customer accounts for it, and only the net goes to box 6. On a
**purchase**, you account for it yourself, so notional VAT is posted to both
the input and the output account: boxes 1 and 4 both move and the effect on
the liability is nil. The bill total stays at the net figure either way.

Cash accounting and flat rate post identically to standard for now. Both
schemes change *when* and *how much* VAT is declared rather than how the
invoice is recorded, so they belong with the VAT return in phase 3.

---

## A note on selling this

Two things change the moment there is a second organisation on the
instance that is not yours:

**Data protection.** You become a data processor for your customers'
financial records. That means a processor agreement, a retention policy, a
breach procedure, and a documented answer to where the data lives. Worth
getting advice before the first paying customer rather than after.

**Backups.** Supabase's point-in-time recovery is not on the free tier.
For accounting records it is not optional, and neither is testing that a
restore actually works.

Neither is a reason not to build it. Both are cheaper to sort out now than
at the point someone asks.

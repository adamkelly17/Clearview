# Clearview

Accounting that shows its working.

A double-entry accounting system on Next.js 14, Supabase and Vercel.

Phase 1 is the foundation: nominal ledger, posting engine, setup wizard,
manual transactions, trial balance.

Phase 2 is the trading layer: customers, suppliers, invoices, bills, credit
notes, receipts, payments, allocation, statements and aged analysis.

Invoice capture sits on top of phase 2: upload a PDF or a photo, it gets
read, you check it, and it posts as a bill with the original attached.

Banking is built: bank accounts, statement import from CSV or Excel,
matching rules and reconciliation. Bank feeds are not — but a feed will
write to the same table the import does, so nothing else changes when
they arrive.

VAT returns and the year-end close are what remain.

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
supabase/migrations/0011_fiscal_year.sql
supabase/migrations/0012_capture.sql
supabase/migrations/0013_banking.sql
supabase/migrations/0014_void_and_vat.sql
supabase/migrations/0015_edit_documents.sql
supabase/migrations/0016_bank_rules.sql
supabase/migrations/0017_change_year_end.sql
supabase/migrations/0018_next_year.sql
supabase/migrations/0019_undo_and_reallocate.sql
supabase/migrations/0020_smarter_capture.sql
supabase/migrations/0021_overview.sql
supabase/migrations/0022_contact_reports.sql
supabase/migrations/0023_capture_queue.sql
supabase/migrations/0024_negative_lines.sql
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

## Linting

```bash
npm run lint
```

Worth running before every deploy, and not optional. An undefined variable
inside JSX is a **runtime** error, not a compile one — `next build` reports
success and the page then dies with "a client-side exception has occurred".
That is exactly how a missing `useState` reached production once. The
config turns `no-undef` into an error for that reason.

## Testing the ledger

The database rules are covered by a test suite that runs against any
Postgres 16. It stubs the parts of Supabase it needs:

```bash
createdb ledgertest
psql -d ledgertest -f supabase/test/00_stub_supabase.sql
for f in supabase/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -d ledgertest -f "$f"; done
psql -d ledgertest -f supabase/test/01_ledger_test.sql
psql -d ledgertest -f supabase/test/02_trading_test.sql
psql -d ledgertest -f supabase/test/03_capture_test.sql
psql -d ledgertest -f supabase/test/04_banking_test.sql
psql -d ledgertest -f supabase/test/05_void_vat_test.sql
psql -d ledgertest -f supabase/test/06_edit_test.sql
psql -d ledgertest -f supabase/test/07_year_end_test.sql
psql -d ledgertest -f supabase/test/08_undo_reallocate_test.sql
psql -d ledgertest -f supabase/test/09_overview_test.sql
```

A hundred and forty-one assertions across the six files. Each is independent — they can
be run in any order, repeatedly, against the same database.

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

`03_capture_test.sql` covers supplier matching by VAT number, exact name
and fuzzy name, nominal coding from history, duplicate detection on both
invoice number and amount-within-a-week, the arithmetic validation
catching a header that disagrees with its lines, and the approval path
posting to the ledger with the original file attached.

`04_banking_test.sql` covers statement import, duplicate detection on
overlapping re-imports, matching against transactions already in the
ledger, VAT being taken out of a gross bank figure rather than added to
it, rules being remembered and reused, transfers, settling a bill from
the bank, unmatching, and the reconciliation figures agreeing with the
nominal.

`05_void_vat_test.sql` covers voiding — that the document survives, the
journal reverses, the audit trail records who and why, aged debtors
clears with no orphan balance, and a part-paid invoice refuses to be
voided — plus the VAT registration guard in both directions.

The RLS migrations (`0006`, `0010`, `0012`, `0013`) are safe to re-run: they clear
their own policies first, because `CREATE POLICY` has no `IF NOT EXISTS`
and a migration that fails partway otherwise cannot be retried. The
table-creation migrations are run-once.

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
| Invoice capture — upload, read, review, post | Built |
| Supplier matching, duplicate detection, nominal suggestion | Built |
| Invoice PDFs (outbound) | Phase 2b |
| Email-in for capture | Phase 2b |
| Quotes and purchase orders | Phase 2b |
| Bank accounts, opening balances | Built |
| Statement import from CSV and Excel, with column mapping | Built |
| Matching, rules, transfers, reconciliation | Built |
| Bank feeds (Open Banking) | Later |
| VAT return calculation | Phase 3 |
| P&L, balance sheet, year-end close | Phase 3 |
| Stock, fixed assets, recurring, departments | Phase 4 |
| MTD submission, live bank feeds | Later |


## Invoice capture

Upload a PDF or a photo of a supplier invoice. It goes to Supabase Storage,
a server route reads it, and you get a review screen with the original on
one side and editable fields on the other. Approving calls
`post_document()` with what you confirmed.

### The rule that shapes everything else

**Extraction produces a draft, never a posting.** A model that misreads a
VAT figure and posts straight to the ledger produces a wrong VAT return,
and afterwards there is no way to tell whether a figure was read or
checked. So nothing in the capture tables touches the ledger.
`approve_capture()` is the only route through, and it posts what a human
confirmed on screen.

The original file stays attached to the posted bill, because HMRC expects
the paperwork behind any entry to be producible.

### Supplier matching, and why trigrams were the wrong tool

A real Amazon invoice reads as "Amazon EU S.à r.l., UK Branch". Against
"Amazon" on file, trigram similarity scores 0.25 — most of the long name
is not in the short one — so it fell under the threshold and matched
nothing.

Matching now goes: VAT number, exact name, **normalised** name, one name
contained in the other, `word_similarity`, then trigram. Normalisation
strips punctuation, legal forms and territory qualifiers, so both reduce
to "amazon". As a side effect "Timber Supplies Limited" and "Timber
Supplies Ltd" are now an exact match rather than a fuzzy one.

Confirming a match **records the supplier's VAT number**. The first
invoice from a supplier is matched on a name and confirmed by a human;
every one after it matches on the VAT number, exactly, with no guessing.

### Coding a supplier with no history

`suggest_account_for_contact()` works from what a supplier's bills have
gone to before, which is nothing on the first invoice. So the extraction
prompt is now handed the organisation's chart of accounts and asked to
pick a code per line.

History still wins where it exists — what this supplier's bills have
always gone to beats what a model inferred from a description.

### Not VAT registered means the gross is the cost

A business that is not VAT registered cannot reclaim VAT, so an £8.25
invoice is an £8.25 cost — not £6.87 with £1.38 stranded. The review
screen now fills the line at the gross figure, suggests no VAT code, and
compares its total against the document's total rather than against a net
figure that was never relevant.

That last part was a real bug: the screen showed £8.24 against a document
saying £8.25, purely from applying a VAT rate that should never have been
suggested. Posting was correct, but a screen that disagrees with the
paperwork in front of you is worse than useless.

### What makes it worth using rather than just OCR

- **Supplier matching** on VAT number first, then exact name, then fuzzy
  name via `pg_trgm`. Names are inconsistent; VAT numbers are not. A fuzzy
  match is shown as a suggestion to confirm, never applied silently.
- **Duplicate detection** on the same supplier plus invoice number, or the
  same supplier, total and a date within a week. Duplicate purchase
  invoices are among the most common real errors in a purchase ledger, and
  capture makes them easier to create.
- **Nominal coding from history.** If this supplier's last several bills
  went to 7501, that is suggested. This is the part that turns capture
  from data entry into time actually saved.
- **Arithmetic validation.** Net plus VAT against the stated total, and the
  lines against the header. It reports rather than corrects — a silent fix
  would hide the very thing worth looking at.
- **Confidence shown only where it is low.** A row of green ticks trains
  people to stop looking. A marker on the two shaky fields sends the eye
  where it should go.

### Reading is a queue, not a loop

Uploading and reading used to happen in one client-side loop: upload a
file, read it, upload the next. Clicking away part way through stopped the
loop, so files it had not reached yet were never uploaded at all — and
anything it had started sat on "Reading" for ever, because the inbox
offered no action for that status.

Now the two are separate. **Uploading** happens first, four at a time, and
is quick. Once a file is in the inbox it is safe. **Reading** is a queue:
`claim_next_capture()` takes one document at a time using `FOR UPDATE SKIP
LOCKED`, so two tabs cannot read the same one, and each document's status
records exactly where to carry on.

`reclaim_stuck_captures()` runs whenever the inbox loads. Anything left
mid-read for more than five minutes goes back in the queue with a note
saying it was interrupted — a closed tab heals itself instead of leaving a
document stranded. After three failed attempts it stops retrying and says
so, rather than looping.

Leaving the page still stops the reading, but nothing is lost and the
button picks up where it left off. Genuinely unattended processing needs a
scheduled trigger: `app/api/capture/process/route.js` is written and ready
for one, but frequent cron jobs need a Vercel plan above the free tier, so
it stays switched off until then.

### The stub provider

`EXTRACTION_PROVIDER=stub` is the default and reads nothing. It returns one
of six hand-written fixtures so the whole flow can be exercised before any
API account exists and before any document leaves your infrastructure.

Name a file to pick a case: `clean`, `mixed` (two VAT rates), `reverse`
(CIS domestic reverse charge), `broken` (lines that do not sum to the
header), `sparse` (a photographed receipt with no line detail) or
`unknown` (a supplier not on file). Otherwise the fixture is chosen from a
hash of the filename, so the same file always gives the same result.

`broken` is the one that matters most. You cannot make a real model
misread something on demand, but you need to know what the review screen
does when extraction is wrong — that is the case the whole design exists
to catch.

### Switching to a real model

Set `EXTRACTION_PROVIDER=claude` and `ANTHROPIC_API_KEY`. The interface in
`lib/extraction/` is one function with one return shape, so moving to
Textract, Document AI or Mindee means writing one file and changing one
variable. Nothing downstream knows which one read the document.

**Before you do**, and this is the real consideration rather than a
technical one: client financial documents will leave your infrastructure
and go to a third party. For a practice that needs a data processing
agreement in place first, and confirmation in writing of the provider's
retention terms — zero retention is generally available on request but
should not be assumed. If you sell this, the provider becomes a named
sub-processor you have to disclose to your own customers. Worth reading
your existing engagement letters before the first client document goes
through it.

### Accuracy, honestly

Header fields — supplier, number, date, totals — are reliable with current
vision models. Line-item detail on multi-page or unusual layouts is less
so, and the VAT breakdown on mixed-rate invoices is the weakest point. CIS
reverse-charge invoices need watching because the notice wording varies by
contractor and the VAT box is often blank by design.

A stub tells you nothing about any of that. It is worth running fifty real
invoices through a real model and counting the corrections before deciding
this saves time on your particular post.



## The customer and supplier lists

Both screens read `contact_summary()`, which returns amounts **and counts**
per contact: total due, how many invoices that is, how much is overdue, how
many invoices that is, the ageing buckets, and the age of the oldest item.
"£4,200 overdue" and "£4,200 overdue across eleven invoices" call for quite
different phone calls.

Contacts with nothing outstanding still appear, at nil, rather than
vanishing from a list of customers.

Every column sorts, and the sort lives in the URL — so a sorted view can be
bookmarked, shared, and survives a refresh after recording something.

### Reports

Three Excel downloads, built in the browser with SheetJS:

- **Summary with ageing** — one row per contact, balance in each period,
  with a totals row because the first thing anyone does is check it against
  the control account.
- **All outstanding** — one row per invoice, with the ageing bucket as a
  label as well as a day count, so it can be pivoted without anyone
  rebuilding the bucket logic in Excel and getting it subtly different.
- **Overdue only** — the same, filtered.

All three read the same functions the screen reads. A report that disagrees
with the screen it came from is worse than no report, and the test asserts
that the summary, the detail and trade debtors all reach the same figure.

## The overview

Three panels, each answering something an owner actually asks.

**How the business is doing** is a chain, not four separate cards: sales,
less cost of sales, gross profit with its margin, less overheads, profit.
Laid out downward because these figures are not independent facts — the
point of each is what it leaves behind. Percentages of sales sit alongside,
which is how you spot a problem long before the absolute numbers look
wrong.

Other income sits *below* gross profit deliberately. Bank interest is
income but it is not sales, and letting it flatter the gross margin would
defeat the object — the margin is about the work.

**The bank** shows the balance, how many entries are unreconciled, and how
old the oldest of those is. The count alone says little; the date says a
great deal. Something sitting there since April means the bank has not
been looked at since April, and the balance on screen should not be
trusted. Past thirty days it says so plainly.

**Where you stand** is bank, plus what is owed to you, less what you owe,
and where that leaves you if everything settled. For a small business that
last figure is more use than either ledger total on its own — it is the
answer to "can I afford this". It also names who to chase first, chosen by
age rather than size, because age is what turns a debt into a bad one.

## Financial years

Two things that get conflated, kept apart here:

**Adding the next year** creates the periods so posting can continue.
Nothing else changes. Settings offers it, and the dashboard prompts when
the current year is within thirty days of ending or has already ended.
Years always run back to back — a gap would mean transactions on the days
between could never be posted, with nothing to say why.

**Closing a year** rolls the profit into reserves, locks the periods and
produces the final accounts. Still to build.

You do the first the day the calendar rolls over and the second months
later, once the accounts are agreed, so two open years side by side is
normal rather than a mistake.

**Changing a year end** after the fact is supported, because businesses do
it — Companies House allows shortening freely and extending once every
five years. Extending adds the missing months; shortening removes them,
but only if nothing has been posted into them, and the preview says how
many transactions are in the way before anything is altered.

## Editing is void and replace

A posted document still cannot be altered. Editing one voids the original,
reverses its journal, and posts a replacement — carrying the **same
document number**, because the customer already has a piece of paper with
that number on it and the numbering should not develop gaps. The
uniqueness rule on document numbers therefore ignores voided documents.

The two are linked in both directions and the original records "Replaced
by INV0006 — wrong price agreed" against it. From the user's side it
behaves like an edit; from an auditor's side it reads like a correction,
which is what it is.

Everything can change: contact, date, number, lines, categories, VAT
treatment. The replacement is posted from scratch rather than patched, so
there is no field quietly carried over and no partial update to get wrong.
The original's lines survive too, so the superseded version can still be
read.

### An invoice with a payment against it can still be edited

This is safe for one reason worth stating plainly: **an allocation never
touches the nominal ledger**. `allocation` records which payment answers
to which invoice and nothing else — the money moved when the payment was
posted. So allocations can be taken apart and put back without the
control account ever being wrong at any point in between.

The order is: unallocate, void, post the replacement, re-apply what fits.

The case that needs care is a replacement smaller than what was paid.
Editing a paid £600 invoice down to £400 leaves £200 the customer has
overpaid. That is a real credit: £400 goes back onto the new invoice, the
£200 sits on account, and the screen says so rather than letting it
disappear quietly. Trade debtors reads −£200 and the sales ledger agrees.

Voiding keeps the old restriction, because unlike an edit there is no
replacement for the payment to move to. Unallocate it first — there is now
a button for that on the contact screen.

A document already reported on a filed VAT return cannot be edited at all.
No return can be filed yet, but the guard is in place for when they can
be.

## Negative lines

Discounts, promotions, rebates and carriage refunds all print as negatives
on perfectly ordinary invoices. What is not ordinary is a negative debit —
double entry has no use for negative numbers, because a negative amount on
one side is simply a positive amount on the other.

`posting_sides()` works the side out from the sign. A −£2.92 promotion on a
purchase invoice becomes a credit of £2.92 to that account; the same
discount on a sales invoice becomes a debit. The document line keeps the
figure as printed, so the paperwork still matches, while the ledger only
ever holds positives.

`post_journal()` normalises signs too, so a module written later cannot
reach the constraint by making the same mistake. A negative debit handed in
is understood as a credit — not a guess, just the same entry written the
other way round.

## Nothing is ever deleted

A posted invoice or bill cannot be deleted, only **voided**. Voiding
reverses the journal, marks the document void, and records who did it,
when, and why. Both the original and the reversal stay in the transaction
list for ever, so anyone auditing the books can see that something was
entered and then taken back out.

`void_document()` refuses if anything has been settled against the
document. A payment is real; voiding around it would leave the control
account disagreeing with the sub-ledger. Unallocate the payment first, or
raise a credit note instead.

The offsetting entry is a `contra` ledger item allocated against the
original, so the document drops off aged debtors without leaving an
orphan balance behind.

## VAT is guarded in the database

If an organisation is not VAT registered, `post_document()` strips every
VAT code it is given. The same guard applies to the bank coding path
through `apply_vat_guard()`.

This is deliberately not only an interface concern. An earlier version
hid the VAT column when VAT was switched off but still passed the default
code, so a £20 bill posted as £20 net plus £4 VAT. Enforcing it in one
place in the database means the invoice screen, the capture screen, the
bank screen and anything built later all get it right without having to
remember.

## Banking

### A statement line is not a transaction

It is *evidence* that a transaction happened. Those are different things,
and conflating them is how bank imports corrupt a ledger.

So `statement_line` is imported data sitting outside the ledger. Each line
ends in one of three states: matched to a journal line, excluded with a
reason, or still waiting for a decision. Reconciling stamps
`reconciled_at` on the journal line through `set_line_reconciled()`; the
transaction itself stays immutable, exactly as in phase 1.

This is also why bank feeds will be a small piece of work rather than a
rewrite. A feed writes to `statement_line` and everything downstream is
already built.

### The screen is split

The bank's version of the transaction on the left, what Clearview will do
with it on the right. Suggestions for every line are fetched in one call
and shown immediately — nothing has to be opened to find out whether a
match is waiting.

The right-hand side is pre-filled from the best suggestion, so the common
case is reading one line and pressing one button. Alternatives sit behind
a single click and everything stays editable.

Suggestions are labelled by what accepting them will *do* — "Suggested:
pay off supplier invoice" rather than "Unpaid invoice". The reader is
deciding about an action, not identifying an object.

### Payments go against the invoice you choose

Picking a contact lists their outstanding items with an amount box
against each. Nothing is swept oldest-first: when you are looking at one
payment on a bank statement you usually know exactly which invoice it
settles, and guessing wrong quietly mis-states two accounts rather than
one.

If the payment exactly matches a single outstanding item, that one is
filled in automatically — the common case still takes one click. Anything
left unallocated sits on account rather than being forced somewhere it
does not belong.

### Rules are made from decisions

Coding a line offers "do this automatically next time", with a pattern
already suggested from the description. `suggest_rule_pattern()` strips
the volatile tail — "EDF ENERGY DD 4471" becomes "EDF ENERGY", because a
rule containing the direct debit number will never fire again. Leading
markers like `DD`, `CARD PAYMENT TO` and `TFR TO` are skipped so the real
name is found.

The same function exists in SQL and in `lib/statement.js`, and the two are
tested against the same cases. The interface needs one per row, and a
round trip to compute a string would be absurd.

As the pattern is edited, `preview_rule_matches()` reports how many other
waiting lines it would catch — so the reach of a rule is visible before it
is saved rather than discovered afterwards. Saving offers to apply it to
those lines immediately, which is the difference between a rule saving
time this month and next month.

### Undo

Matched and ignored lines both have an undo that puts them back in the
list. What it does depends on what the line did:

- **Created a transaction** — that transaction is reversed, and both
  entries stay in the audit trail. Any sales or purchase ledger entry it
  created goes with it, or the control account and the sub-ledger would
  stop agreeing.
- **Matched to something already there** — only the link is broken. The
  transaction is left alone.

The confirmation says which of the two is about to happen, because they
are quite different.

### Rules suggest, they never act

A saved rule is offered as a suggestion on every line it matches, and each
one is still accepted individually. There is deliberately no "apply this
to the other eleven" — every transaction gets looked at before it reaches
the ledger, which is the whole point of a reconciliation screen.

Saving a rule does say how many other waiting lines it will be suggested
on, because that is how you judge whether a pattern is too broad or too
narrow. It is information, not an offer.

### Matching, in order of trustworthiness

1. **Something already in the ledger** — same amount, same bank account,
   within a fortnight, not yet reconciled. Confidence tails off with date
   distance because bank dates and posting dates drift. This is the
   suggestion that stops a bank import duplicating what the sales and
   purchase ledgers already recorded, which is the single most common way
   bank imports go wrong.
2. **An unpaid invoice or bill** for exactly this amount. Settles and
   allocates in one action. The score is raised when the contact's name
   appears in the bank description.
3. **A saved rule** matching the description.

Rules stay suggestions unless someone explicitly sets `auto_apply`. Each
use increments a hit count so the useful ones sort to the top.

### VAT comes out of the gross

A bank figure is gross. Coding £1,200 to rent at 20% gives £1,000 net and
£200 VAT — not £1,200 plus £240. Getting this the wrong way round is the
classic bank-coding error and the test asserts it explicitly.

### Reading statement files

There is no standard for UK bank statement CSVs. Barclays, HSBC, Lloyds,
NatWest, Monzo, Starling and Tide differ on column names, on column order,
on whether amounts are one signed column or two, on date format, and on
whether there is a preamble above the header row.

So `lib/statement.js` guesses the layout, and the interface shows the
guess for confirmation. It never applies it silently, because being wrong
about which column is the amount — or reading 04/03 as 3 April — is not
recoverable once posted. The preview shows real parsed dates and signed
amounts before anything is written, and the mapping is remembered per
account for next time.

Handled: single signed amount columns, separate money-in/money-out
columns, bracketed negatives, currency symbols and thousands separators,
Excel serial dates, two-digit years, and a header row that is not the
first row. Rows that cannot be read are reported rather than dropped.

### Re-importing is safe

Every line carries a fingerprint of account, date, amount and normalised
description. Overlapping date ranges are recognised and skipped, and an
import consisting entirely of duplicates does not leave an empty statement
behind. Two genuinely identical direct debits on different dates are
correctly kept as two lines.

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

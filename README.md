<div align="center">

# Peony

**Booking pages for solo beauty professionals.**
Her clients book themselves. She just shows up.

<img src="docs/hero.png" alt="The Peony marketing site: a laptop showing a studio's diary beside a phone showing a client booking an appointment" width="100%">

</div>

---

## What this is

A booking platform for lash, brow, nail and hair technicians working for
themselves — the ones currently running their diary out of Instagram DMs at
eleven at night.

It is priced to be sold cheaply to many rather than expensively to a few, and
that single decision drives most of the design. At £10 a month the only thing
that matters is that setting up a new studio costs **zero minutes**: she signs
up herself, claims her own link, and corrects treatments we guessed rather than
filling a form from nothing.

## The whole loop

**She** signs in by emailed link, picks her trade, names her studio and claims
a link. Her page is live in about ten minutes, with her usual treatments and
prices already in it.

**Her client** opens that link, sees her treatments with her photographs, picks
a time she is genuinely free, and books. Both of them are emailed.

**Afterwards** she can cancel or block out a holiday; the client can cancel
themselves and the time goes straight back on sale. On Pro, a reminder goes out
before every appointment.

## What is in here

| Path | |
|---|---|
| `peony/` | the marketing site, and the brand it is built from |
| `app/` | sign in, the three-step wizard, her dashboard |
| `book/` | her clients' booking page and their manage page |
| `platform/` | nine migrations, three edge functions, nine test suites |
| `index.html`, `demo/` | the original èllash client page this grew out of — still live, see below |

No build step and no framework anywhere. Every page is a file you can open.

## The part worth reading the code for

The page this grew out of could not lock a slot. Two people on two devices
could both take 09:00 and both get a confirmation — proven with a two-browser
test, not assumed.

Checking "is it free?" in application code does not fix that. It only narrows
the window between the check and the insert. So the refusal lives in the
database:

```sql
alter table booking add constraint booking_no_overlap
  exclude using gist (
    tenant_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status = 'confirmed');
```

A range overlap rather than an equality test, because a 90-minute full set
booked at 09:00 has to block 10:00 as well. Two concurrent transactions cannot
both satisfy it: the second to commit raises `23P01` and rolls back.

**Fifty simultaneous attempts on one slot produce exactly one booking** and
forty-nine refusals. `platform/test_booking.sh` runs that against a real
Postgres on demand.

## Running the tests

```bash
cd platform
./test_booking.sh      # the overlap constraint, under real concurrency
./test_signup.sh       # signup, availability, row level security
./test_cancel.sh       # cancelling from both sides, closures
./test_email.sh        # what is queued, and what is not
./test_reminders.sh    # the Pro reminder
./test_billing.sh      # plan state, and that she cannot grant herself Pro
./test_function.sh     # the three edge functions type-check
node test_app.js       # her dashboard, end to end
node test_book.js      # her clients' pages, end to end
```

The SQL suites build a throwaway Postgres cluster each time. They need
`postgresql-16` and a non-root user, because Postgres refuses to run as root.

The two front-end suites drive a stubbed Supabase client: they test this code's
own logic and make no claim about supabase-js itself.

## Setting it up

`platform/README.md` has the eight steps, and explains what each migration is
for. The short version: create a Supabase project, apply `001` to `009`, fill in
`platform/config.js`, deploy the three functions with their keys.

> **This repository is public.** The service-role key bypasses every row-level
> security policy in the database. It belongs in a gitignored `*.local.sql`
> copy or pasted straight into the Supabase SQL editor — never in a tracked
> file. `006_cron.sql` says so where you would be tempted.

## What is not built

Being plain about this, because the marketing copy was once not:

- **Deposits.** They need Stripe Connect so the money goes to her, not to us.
  A larger job than subscriptions were.
- **Her own domain name**, for Pro.
- **Rescheduling** is cancel-then-rebook. Honest, but clumsy.
- **No email has ever actually been sent, and no payment ever actually taken.**
  Everything that composes them is tested and the senders type-check, but
  neither has run against a live provider. That needs keys.
- **Real Safari is untested.** Only Chromium is installed in the environment
  this was built in.

## The èllash page

`index.html` and `demo/` are the original one-page booking flow built for
**èllash**, a mobile lash technician covering Birmingham, Nuneaton and
Coventry. It is still live and still works, and Peony grew out of it.

It carries her real prices, photographs and aftercare, and it cannot be reused
as a sales sample for anyone else — the photographs are her clients' faces.
`peony/` exists because of that.

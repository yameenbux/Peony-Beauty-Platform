<div align="center">

<img src="site/monogram.svg" alt="Booked In" width="88">

# Booked In

**A booking page for solo beauty professionals.**

Her clients book themselves, from a link in her Instagram bio.
No commission, no marketplace, and nobody else advertised on her page.

Made by YSB Designs.

![Postgres](https://img.shields.io/badge/Postgres-16-43192A?style=flat-square&labelColor=43192A&color=8E2F43)
![Supabase](https://img.shields.io/badge/Supabase-RLS%20%2B%20edge%20functions-43192A?style=flat-square&labelColor=43192A&color=8E2F43)
![Render](https://img.shields.io/badge/Render-static%20site-43192A?style=flat-square&labelColor=43192A&color=8E2F43)
![Build](https://img.shields.io/badge/build%20step-none-43192A?style=flat-square&labelColor=43192A&color=B8465C)
![Tests](https://img.shields.io/badge/suites-38%20passing-43192A?style=flat-square&labelColor=43192A&color=2E7D5B)
![Double booking](https://img.shields.io/badge/double%20booking-impossible-43192A?style=flat-square&labelColor=43192A&color=2E7D5B)
![Licence](https://img.shields.io/badge/licence-all%20rights%20reserved-43192A?style=flat-square&labelColor=43192A&color=C08A4E)

</div>

<br/>

> [!NOTE]
> **Reading this without a technical background?** Start at *The problem*, *Two
> screens, one diary* and *Free, Pro and Pro+*. Those three explain what Booked
> In is and what it does for someone running a beauty business on her own.
> Everything from *How the pieces fit* onwards is for whoever maintains the
> code.

### How to read the diagrams

Every picture in this file uses the same four colours, and they always mean the
same thing. The connectors animate, so you can see which way the information
actually travels.

| | Means |
| :--- | :--- |
| 🟪 **Plum, carmine border** | Booked In itself: our code |
| 🟩 **Pale mint** | Built, tested and working today |
| 🟨 **Sand, dashed border** | Written down, not built, not sold as built |
| ⬜ **Blush** | A person, or something outside the product |

---

## The problem, in one picture

A lash technician's diary lives in her Instagram DMs. A client asks at eleven at
night whether Saturday is free; she has to open her calendar, count back the
three weeks since the last infill, and remember she is in Coventry that day. By
the time she answers, the client has gone quiet and the slot is still empty.

<img src="assets/diagrams/01-the-problem.svg" alt="The same week two ways: a DM thread that goes nowhere, against a booking page that offers only her free times and locks the slot" width="100%">

Plenty of products book appointments. What Booked In does differently is that
**the page is hers**: her photographs, her prices, her link, and no marketplace
showing her client three other technicians nearby.

> [!TIP]
> **The booking page is the acquisition channel.** Every client page carries
> "Powered by Booked In" in its footer, on every plan, and every page is seen by
> fifty to two hundred women, some of whom are beauty technicians themselves.
> That line used to come off at Pro, which meant the studios with the most
> clients were the ones nobody could trace back here. It stays now.
>
> It is also the *only* place our name appears. The mark used to come off her
> **story cards** at Pro; `028` took it off every card, on every plan. A page we
> host for her is ours to sign. A post she makes under her own name, to her own
> followers, is not — and a card that looks like us rather than like her is a
> card she does not post, which costs us the reach the footer is there to buy.

---

## Two screens, one diary

<img src="assets/diagrams/02-two-sides.svg" alt="What her client sees against what she sees, and the booking passing between them" width="100%">

She never has to be the bottleneck. Bookings arrive while she is working on
somebody else, and anything she changes — a price, an hour, a photograph, a day
off — is live on her page the moment she saves it.

---

## Nothing can double-book

This is the part worth reading the code for.

The page this grew out of could not lock a slot. Two people on two devices could
both take 09:00 and both get a confirmation — proven with a two-browser test,
not assumed.

<img src="assets/diagrams/03-the-lock.svg" alt="Two clients tapping the same time in the same second, and the exclusion constraint refusing the second one" width="100%">

Checking "is it free?" in application code does not fix that. It only narrows
the window between the check and the insert. So the refusal lives in the
database (`platform/001_schema.sql`):

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

> [!IMPORTANT]
> **Fifty simultaneous attempts on one slot produce exactly one booking** and
> forty-nine refusals. `platform/test_booking.sh` runs that against a real
> Postgres on demand, so it is a claim you can check rather than one you have to
> take on trust.

The same transaction boundary is why a losing booking never emails anybody: the
mail trigger fires `AFTER INSERT`, so a row the constraint rolls back takes its
queued confirmation with it. Thirty racing bookings produce one booking and
exactly two emails.

---

## How the pieces fit

<img src="assets/diagrams/04-how-it-fits.svg" alt="Three static pages talking to Postgres through security-definer functions, with edge functions for mail and Stripe" width="100%">

Three static pages, no framework and no build step — every page is a file you
can open. All the logic that matters is in the database, where it can be tested
and where row level security can keep one studio's client list away from every
other studio.

> [!CAUTION]
> **Postgres grants `EXECUTE` on a new function to `PUBLIC` by default.** Three
> `SECURITY DEFINER` functions were therefore callable by anonymous visitors
> until `009_lockdown.sql`: `next_mail()` hands back the outbox, which holds
> client names and email addresses; `setting()` returned any row of
> `platform_setting`, where `006` was storing a service-role key; and
> `set_plan()` would have let anybody put any studio on Pro.
>
> `lockdown()` is a standing audit now rather than a one-off. It holds the
> allowed list, revokes everything else, and **raises** rather than repairs on
> the three things no later migration should reintroduce: a policy handing a
> whole table to `anon`, `anon` holding `SELECT` on `tenant`, and a trigger
> function left `SECURITY INVOKER`. Every migration that creates a function
> must end with `select lockdown();` — `platform/README.md` says why.

---

## Free, Pro and Pro+

<img src="assets/diagrams/05-built-and-not.svg" alt="Three tiers side by side: what Free gives her, what Pro adds at ten pounds a month, what Pro+ adds at twenty-four, and the five things written down but not built" width="100%">

Pro now carries the thing that pays for it. **Rebooking** watches how long it
has been since each client's last appointment, against an interval set per
treatment, and sends one email when she is about due with a link straight to a
free time. Nothing about it is clever; it is simply the message a studio means
to send and never does. A single client coming back one extra time in a year
covers the subscription several times over.

It is deliberately hard to misuse. It is off until she turns it on, even though
the intervals arrive filled in. It sends once per visit, enforced by a primary
key rather than by being careful. It skips anyone with an appointment already
booked, anyone whose last visit was over three months ago, and anyone who has
opted out — and every message carries the link that opts her out, for good, in
one tap. That is the soft opt-in the law describes; miss any part of it and this
would be marketing, which it is not.

Pro also carries **deposits** — paid straight to her, never through us — which
is the feature that moved out of the not-built column when `017` threw out
Stripe Connect in favour of her own payment link.

**Pro+ is built entirely out of the one thing a generic scheduler cannot do**,
which is know what a patch test is. At £24 it adds the waiting list that fills
a cancellation within the minute, standing appointments so a regular's next six
visits go in at once, chasing for the client whose test is about to lapse, and
**the insurance pack**: every dated patch test and every appointment for one
client, in one call, as the record an insurer asks for after a reaction. That
data had been sitting in the schema since `014` and nobody could get it out.

None of that is a limit lifted off the free tier. **The patch-test rule itself
is free and always will be** — a safety rule behind a paywall is not a safety
rule — so what Pro+ sells is the chasing and the paperwork, never the
enforcement. `test_proplus.sh` holds the other half of that promise, which is
that paying more must never take anything away: adding a third tier put every
gate comparing `plan` to `'pro'` one word away from silently cancelling a
paying studio's reminders, so nothing compares it to a literal any more.

## The one thing that is not a convenience

Tinting and lash extensions need a patch test 24 to 48 hours beforehand. The
exact window is the insurer's and they differ; a signed disclaimer does not
replace it, and a test done at another salon does not count. If a client reacts
and the studio cannot produce a dated record, the insurance that was supposed to
cover it may not — and a reaction claim is the kind that ends a one-person
business.

**Every booking platform treats this as her problem.** They sell appointments,
and the compliance that has to sit around the appointment is left in a notebook,
or in her head, or nowhere. Which means the one thing a stranger can do on her
page — book herself in — is also the thing that can quietly void her cover, and
she finds out afterwards.

Here the database refuses. A treatment that needs a test cannot be booked by
somebody who has not had one in time; the refusal says what to do instead; the
booking page says so on the tile before anybody picks a time; and booking the
patch test appointment *is* the record, so nobody has to remember to write
anything down. The window, the lifetime and which treatments need one are all
hers — we are not going to guess her policy's wording for her.

It is turned on from the trade at signup, because a setting that arrives switched
off is a setting nobody finds.

---

## Two trades, one platform

This started as software for the ones who travel, and it showed: openings
carried an *area*, the copy talked about turning up, and nowhere in the database
held an address. That is half the trade. The other half works from a room at
home, a chair rented in a salon, or a shop — and for her clients the first
question is not when she is free, it is **where she is and where to park**.

So where the appointment happens is now something she says, once, and three
answers are allowed:

| | Her page | Her diary |
|---|---|---|
| **Clients come to me** | Shows the address, a maps link, and the line no address field holds — the buzzer, which door, the parking | — |
| **I travel to them** | Asks each client for her own address, and will not accept a town without a number or a postcode | Every appointment carries it, as a link straight to maps |
| **Both** | Her client chooses, in one tap, before the calendar | Only the ones she is travelling to |

The asymmetry is the point. A technician working from a room at home must
**never** be asked to publish that address "for her page", and a client driving
to a treatment must never be left guessing. Getting the two the wrong way round
is the kind of mistake that is only ever found by a client standing in the wrong
street, so the pages, the confirmation emails, the night-before reminder and the
calendar file all take their answer from the same setting — and the booking is
refused outright if an address is needed and missing.

An address a client gives once is remembered against her record, so a regular
never types it twice, and a move updates her without rewriting where last
month's appointment actually was.

---

## A barber's page is not blush

Booked In's own colours are carmine and blush, which is right for the lash and
brow studios it was built for and faintly ridiculous on a barber. A man booking
a skin fade does not want a pink page; nor does a sports-therapy clinic. So the
palette comes from her trade now, set at signup, with no decision for her to
make.

Twelve of them, each with its own accent, grounds and type colour. A barber gets
oxblood `#7E3038`, skin and aesthetics a sage `#3C7868`, tanning an amber
`#986425`; lashes keeps the carmine it always had, so nothing changed under the
studios already on it. An unrecognised trade falls back to that carmine rather
than to nothing. Her own colour, if she gives one, overrides the **accent** and
nothing else — which is what stops one hex value picked on her phone from
quietly making her own prices unreadable.

Because that is the real risk, the contrast rule lives in the database rather
than in anybody's judgement:

```sql
create or replace trigger trade_palette_readable
  before insert or update on trade_palette
  for each row execute function check_palette_readable();
```

Six pairs, checked on every insert and update — body type on ink at 7:1, the
accent on both grounds at 4.5:1, and so on — and a palette that fails any of
them is **rejected rather than shipped**. So the thirteenth trade cannot be
added in a colour nobody can read on, which is the mistake this would otherwise
make eventually and discover from a client squinting at a price list.
`test_palette.sh` checks the ratios against hand-worked figures, including the
4.59 that `013` recorded in a comment long before anything enforced it.

---

## The card she posts

<img src="assets/card-example.png" alt="A Stories card reading &quot;Spaces this week&quot; over three free times and a booking link" width="260" align="right">

A link in a bio is passive: it works for somebody who has already decided to go
looking. What fills a quiet Thursday is a picture in a Story saying Thursday is
quiet. The **Share** tab draws one from her real diary in a tap — the times on
it are the ones actually long enough for the treatment she picked, so the card
can never advertise an appointment she cannot take.

Three of them: the spaces left this week, a gap that has just opened in the
next two days, and an evergreen card with her treatments and prices. Drawn on a
canvas in her own browser, which is partly because there is no server to draw
them on and partly because it means her diary never has to be sent anywhere to
become a picture of itself.

**It is her brand, not ours.** The palette starts from her trade rather than
from us — see *A barber's page is not blush* below — and she can give one colour
on top of that, from which the rest is derived in HSL: the same hue taken pale
for the fills and dark for the type. Asking a lash technician for five hex
values is asking her to do a job she did not sign up for, and the result would
clash anyway. That holds for the black-and-gold and the sage-green that half
this trade uses. She can add a logo, which replaces her name at the top —
uploaded when she first types her business name, because a logo asked for after
signup is a logo nobody adds — and switch the card between light and dark and
between left and centred.

The preview sits inside Instagram's own frame — the progress bar, her handle,
the "Send message" strip — so the two bands that cover a Story are visible while
she is making the card rather than discovered after she has posted it.

**No card carries our mark any more**, on any plan. It used to come off at Pro;
`028` removed it altogether. The booking page still carries "Powered by Booked
In" on every plan, and that is the only place our name appears — a page we host
for her is ours to sign, a post she makes under her own name is not.

`test_story.js` checks by counting ink, because a canvas has no DOM to assert
against. It covers the things that are invisible until the card has been posted
and it is too late: nothing readable in the covered strips, a long studio name
shrinking rather than running off the edge, and a near-black brand colour still
producing a link pill you can read. It also asserts that a free card and a Pro
card are now pixel-for-pixel identical, which is how the removed mark stays
removed.

<br clear="right">

> [!WARNING]
> **Email is live. Subscription billing is not — but it has now been proved.** `booked-in.co.uk` is verified
> with Resend and real confirmations have been delivered to real inboxes — a
> client's "Booking confirmed" and the studio's "New booking", both on 21
> October 2026. The Stripe path has still never run against a live provider:
> every function that composes it is covered by tests and all three edge
> functions type-check under `--strict`, but that is not the same as having
> taken a payment against a real account, and it should not be described as
> though it had.
>
> It has, however, been run end to end against a **Stripe sandbox**: a real
> hosted checkout page, a real card, a real signed webhook. Both tiers map to
> the right plan. That run found two bugs, both now fixed and covered by
> `test_webhook.sh` — see *What the sandbox run found*.
>
> **Deposits are built, and deliberately never touch the money.** She puts in
> her own payment link, PayPal or bank details and the client pays *her*
> directly — we never see it, hold it, or take a cut. The honest limit of that
> design, which the pages carry rather than hide: nothing here can verify a
> deposit arrived, so she marks it received and her client is told "she will
> confirm once it arrives". `017_deposits.sql` sets out why this replaced
> Stripe Connect, and what it removed from the signup by doing so.
>
> **A custom domain per studio, rescheduling and publishing straight to
> Instagram are not built.** Do not describe them anywhere — including the
> marketing page — as features. The pricing card once did, and that is the sort
> of copy that gets a first customer refunded.
>
> `platform/INTEGRATIONS.md` sets out what Instagram publishing needs. It is
> gated on somebody else's approval queue rather than on code, which is worth
> knowing before it is promised to anyone.

---

## What the audit found

A read-only audit against a 198-control checklist, October 2026. Two findings
were live holes rather than missing paperwork, and both had the same root cause:
**Supabase grants new tables to `anon` directly, so row level security is the
only gate — and a policy written `using (true)` opens every column of the table,
including the ones added to it a year later.**

| | |
| :--- | :--- |
| **Her bank details were readable by anybody** | `001` gave `tenant` a `for select using (true)` policy so a booking page could read a studio's name and hours. `017` then added `deposit_bank`, `deposit_sort` and `deposit_paypal` to that same row. The policy did not have to change to start leaking them. `023` revokes the grant outright — column-level `REVOKE` would not have done it, because a table-level `SELECT` grant overrides one, which is worth knowing before reaching for it. |
| **Anybody could destroy the mail queue** | `mail_outbox` had the same arrangement. `024` revokes it and puts the outbox behind a lease: `next_mail()` claims a batch `for update skip locked`, so two senders cannot take the same work, a crashed sender's rows come back after five minutes, and a pick-up no longer costs a delivery attempt — which is what used to burn a confirmation's five tries without ever sending it. |
| **A payment link could be a `javascript:` URI** | `esc()` escapes five characters, none of which appear in `javascript:alert(1)`, and the value reached an `href` on a page already talking about money. The only check was in her own browser, and settings are written straight to PostgREST. `025` settles the scheme in the database, where PostgREST cannot go round it, and both client pages get a `safeUrl()` as well. |
| **Two triggers ran as the wrong role** | `suggest_patch_hours()` and `suggest_rebook_weeks()` were `SECURITY INVOKER`, so they ran as whoever fired them — and a real studio editing her own treatments got `permission denied for function guess_patch_hours`. Seeding never hit it because `create_studio()` is `SECURITY DEFINER`, and no test hit it because every test seeds. `026` fixes both and teaches `lockdown()` to refuse a third. |

And a fifth, found afterwards by Supabase's own linter rather than by the
audit — the worst of the five:

> [!CAUTION]
> **Anyone holding the key that ships in the browser could delete every booking
> on the platform.** `slot_taken` is a view giving the booking page the three
> columns it needs — `tenant_id`, `starts_at`, `ends_at`, and nothing that says
> who. It is `security_invoker = false` on purpose, because `anon` cannot read
> `booking` at all, so the view must run as its owner for that read to work.
>
> Three things had to line up and `001` chose only the first. The view runs as
> its owner. A plain select of three columns from one table is **auto-updatable**,
> so Postgres rewrites a `DELETE` on the view into a `DELETE` on `booking`. And
> Supabase's default ACL had already granted `anon` everything on it — `001`'s
> `grant select on slot_taken to anon` reads like the whole story and is a no-op
> on top of a grant that was there first. Running as the owner is what made the
> third fatal rather than untidy: the write bypassed the RLS on `booking`, which
> was the only thing protecting it.
>
> Confirmed against production with a `DELETE` filtered to a `tenant_id` that
> cannot exist, so nothing was touched: PostgREST answered **204, not 403**.
> Unfiltered, one request empties every studio's diary at once. `029` revokes
> the writes and keeps the read. `security_invoker = true` would have closed the
> write and broken the read the view exists for.

The lesson is not the view. `023` and `024` swept **tables and functions** and
it never occurred to either to look at a **view** — so `lockdown()` now revokes
writes on every view in `public` and refuses while one it does not know about
is writable.

And then it happened a fourth time, which is the point at which a pattern stops
being bad luck. `032` found **seven tables** carrying RLS with no policy and the
default ACL's grants still on them. The rows were unreachable, which is why
three previous sweeps walked past — but **RLS does not gate `TRUNCATE`**, so
every one of them was emptiable by a role that could not read a single row in
it. Nothing in a browser has ever reached those tables and PostgREST exposes no
`TRUNCATE`, so it was not reachable in practice; it should still never have been
true. `lockdown()` now treats a table with RLS and no policy as what it says it
is — nobody's but a definer function's — and writing a policy takes a table out
of that sweep by itself. `test_slot_taken.sh` proves the hole open on an unpatched schema by
emptying both studios' diaries with one statement, then proves `029` refuses it.

Each fix ships with a test that asserts the hole is **open** before the migration
is applied. A test that only checks the fix cannot tell you the fix was ever
needed, and cannot tell you when somebody reopens it.

> [!IMPORTANT]
> What the audit did not find is the one that mattered most on the day: **three
> of eleven trades could not take a booking at all.** Every lash treatment needs
> a patch test 48 hours ahead, `trade_seed` held no patch-test service, so the
> page correctly told a first-time client to book one and then offered her none.
> Every security control passed on a page nobody could book on.
>
> A 198-control register has no row for *does the thing work*, and the audit was
> never going to grow one. `027` seeds the service for all five trades that need
> it and backfills the studios already created; `test_bookable.sh` now asks the
> question nobody had asked.

---

## What the sandbox run found

The Stripe path was the last thing in here that had never run. It type-checked,
it was covered by tests, and it had never once spoken to Stripe — which is not
the same thing, and the difference is where money is.

So it was run: a real Stripe sandbox, a real hosted checkout page, a real card,
a real signed webhook. Both functions ran **unmodified**; only Supabase's two
RPC endpoints were stubbed, so the code under test was the code that deploys.

It worked. A Pro+ checkout built a £24 session carrying the right tenant, the
card went through, the webhook verified its signature, and the subscription
came back as `pro_plus` rather than `pro` — which is the one `016` warned about,
because getting it backwards takes £24 and hands over the £10 plan.

It also found two bugs, both in the same assumption.

> [!CAUTION]
> **A webhook payload is not shaped the way you pinned it.** The function pins
> `apiVersion: 2024-06-20`, so everything it *retrieves* has the shape it was
> written against. An event payload is serialised at the **account's** API
> version instead, which Stripe moves on its own schedule — and on
> `2026-09-30` they moved `current_period_end` off the subscription and onto
> its items.
>
> `periodEnd()` read only `sub.current_period_end`, so it returned `null`.
> That is not a cosmetic loss: `expire_plans()` only touches a row
> `where plan_until is not null`, so the null quietly switches off the thing
> that downgrades a studio whose subscription has lapsed. She keeps Pro+ for
> ever, free. In the run, `checkout.session.completed` wrote the right date and
> the `customer.subscription.updated` behind it overwrote it with `null`.

The second is that `customer.subscription.created` arrives with status
`incomplete`, which `tierOf()` correctly reads as free — and **Stripe promises
no ordering**. A `created` delivered after the `updated` that activated her
would put a paying studio back on free. The run showed exactly that sequence
arriving in the lucky order.

Both are fixed by the same move: `periodEnd()` now reads either shape and takes
the latest item, and the subscription handlers **re-read the subscription from
the API** rather than trusting the copy frozen into the event. That returns the
pinned shape and the current status in one call, so neither a moved field nor a
late delivery can decide what she pays. `test_webhook.sh` covers both — its
second assertion is the one the old code fails.

> [!NOTE]
> **What the run does not prove.** `stripe-webhook` authenticates to Supabase
> with `SUPABASE_SERVICE_ROLE_KEY`, and the value Supabase injects under that
> name is **not** the service-role JWT from the dashboard — the bug that broke
> `send-mail` and took a redesign to fix. The stub here accepts any key, so
> this run says the Stripe half is right and says nothing about that half. It
> is the first thing to check when the functions are deployed for real.

---

## This repository

| Path | |
| :--- | :--- |
| `site/` | the marketing page, the marks, the type, the legal pages, `brand.md` |
| `app/` | sign in, the three-step wizard, her dashboard |
| `book/` | her clients' booking page and their manage page |
| `platform/` | thirty-three migrations, three edge functions, thirty-eight test suites |
| `vendor/` | supabase-js, served from here rather than a CDN |
| `scripts/` | the generators: diagrams, icons, share cards, type |
| `assets/diagrams/` | the pictures in this file, as source and as SVG |
| `index.html`, `demo/` | the original èllash page this grew out of |

Nothing on any page is fetched from anybody else, with one named exception:
Cloudflare Web Analytics, which the privacy notice describes and which the
build adds only when `CF_ANALYTICS_TOKEN` is set. It sets no cookie and writes
nothing to the visitor's device, which is the only reason a third-party script
is tolerable on a client's booking page at all. The typefaces, the Supabase
client and every image are served from this origin, so opening a booking page
tells Google, jsDelivr and the rest precisely nothing. That is partly a privacy
promise the notice has to be able to keep, and partly speed: a first visit to
the marketing page is five requests and 3 KB of render-blocking CSS.

### Running the tests

```bash
./build.sh             # the browser suites all read dist/, so build it first
                       # WITHOUT CF_ANALYTICS_TOKEN: with it, the pages
                       # carry the analytics beacon, the sandbox cannot
                       # reach Cloudflare, and every "no console errors"
                       # assertion fails on a thing that works in production
cd platform
./test_booking.sh      # the overlap constraint, under real concurrency
./test_signup.sh       # signup, availability, row level security
./test_cancel.sh       # cancelling from both sides, closures
./test_email.sh        # what is queued, and what is not
./test_reminders.sh    # the Pro reminder
./test_billing.sh      # plan state, and that she cannot grant herself Pro
./test_abuse.sh        # the booking limits, the honeypot, the address hash
./test_clients.sh      # the client record, the backfill, one studio one list
./test_rebook.sh       # the nudge, and every rule that stops it being spam
./test_patch.sh        # the patch test, and that nobody can book around it
./test_venue.sh        # where she works: her address, or the client's
./test_proplus.sh      # three plans, and that paying more takes nothing away
./test_deposits.sh     # deposits we never touch, and details that must not leak
./test_sector.sh       # every trade, hair colour, and the hole in a colour appointment
./test_earn.sh         # the waiting list, the series, the nudge, her hourly rate
./test_pay.sh          # money up front, the window to cancel, fourteen days of Pro+
./test_lockdown.sh     # the hole 009 could not close, and the environment that hid it
./test_extpath.sh      # pgcrypto where Supabase actually keeps it, not where we assumed
./test_tenant_read.sh  # her bank details, and that anon cannot read the tenant row
./test_mail_lease.sh   # the outbox lease: a pick-up must not cost a delivery attempt
./test_paylink.sh      # a payment link cannot be a javascript: URI
./test_trigger_privilege.sh  # her own triggers fire as her, not as nobody
./test_bookable.sh     # can a brand new client book anything at all?
./test_palette.sh      # a palette per trade, and the contrast the database enforces
./test_slot_taken.sh   # anon could delete every booking; the view that let it
./test_launch.sh       # the paywall, the outbox's memory, and the IP keys
./test_trial.sh        # she hears before the trial ends, once, and only if true
./test_service_tables.sh # RLS does not gate TRUNCATE, and the default ACL knew it
./test_erasure.sh      # forgetting her, without destroying the insurance record
./test_function.sh     # the three edge functions type-check
./test_webhook.sh      # what Stripe's payload shape does to a lapsing plan
node test_app.js       # her dashboard, end to end
node test_book.js      # her clients' pages, end to end
node test_routing.js   # what each address serves, and where the slug comes from
node test_marketing.js # layout on eight screens, contrast on every text style
node test_story.js     # the Stories card, by counting ink on the canvas
node test_links.js     # every link, robots, the sitemap, what stays unindexed
node test_speed.js     # requests and bytes on a first visit, against a budget

node shots.js [dir]    # not a test: photographs every screen, for looking at
```

The SQL suites build a throwaway Postgres cluster each time. They need
`postgresql-16` and a non-root user, because Postgres refuses to run as root.

The browser suites serve `dist/` over HTTP through `platform/serve.js`, which
applies Render's own resolution order — a real file beats the catch-all
rewrite, exactly as in production. They used to open `file://` URLs, which
cannot see an absolute path or the rewrite at all: the bug that made
`/studio-mila` read its slug as `booked-in` was invisible to every one of them.

> [!NOTE]
> The front-end suites drive a **stubbed** Supabase client: they test this
> code's own logic and make no claim about supabase-js itself. Only Chromium is
> installed in the environment this was built in, so **real Safari has never
> been tested.**

### Turning it on

`platform/README.md` has the eight steps and explains what each migration is
for. The short version: create a Supabase project, apply `001` to `033`, set the
four environment variables on Render, deploy the three functions with their
keys.

`build.sh` refuses to produce a `dist/` that contains a service-role key. It
decodes every JWT it finds rather than grepping for the phrase, because the two
keys look alike and a comment that mentions one is not a leak.

> [!CAUTION]
> **This repository is public, and the service-role key bypasses every row level
> security policy in the database.** It belongs in a gitignored `*.local.sql`
> copy, or pasted straight into the Supabase SQL editor and never saved.
> `006_cron.sql` says so where you would be tempted to put it.

---

## The diagrams

Five SVGs, and the connectors animate. GitHub renders mermaid in a fenced block
but cannot animate it and cannot theme it, so these are built rather than
inlined. The sources stay in the repo as text, so a diagram is still something
you can edit and diff:

```bash
assets/diagrams/*.mmd             # the source, one file per diagram
node scripts/build-diagrams.mjs   # regenerates the SVGs
```

The build script holds the palette and the animation in one place. It declares
the colours light-first and redefines them under `prefers-color-scheme`, so the
diagrams follow GitHub's theme, and it keeps a `prefers-reduced-motion` guard so
anybody who has asked their machine for less movement gets a still picture.

> [!NOTE]
> **Do not add a `font-family` override to that stylesheet.** Mermaid sizes every
> box for the font it measured with *before* the stylesheet is added, so changing
> the face afterwards clips the last line of a label.

Rendering needs a Chromium and mermaid:

```bash
npm i -D playwright mermaid@11.4.1
node scripts/build-diagrams.mjs
```

---

## The èllash page

`index.html` and `demo/` are the original one-page booking flow built for
**èllash**, a mobile lash technician covering Birmingham, Nuneaton and Coventry.
It is still live, and Booked In grew out of it.

It carries her real prices, photographs and aftercare, and it cannot be reused
as a sales sample for anyone else — the photographs are her clients' faces.
`site/` exists because of that.

---

## Licence

All rights reserved, YSB Designs. Not open source.

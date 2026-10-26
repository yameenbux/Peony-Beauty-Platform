# Booked In — platform

A booking platform for solo beauty professionals, priced to be sold cheaply to
many rather than expensively to a few. At £10 a month the only thing that
matters is that setting up a new studio costs us **zero minutes**, and most of
the decisions here follow from that.

## What is here

| | |
|---|---|
| `001_schema.sql` | studios, treatments, travel days, bookings, and the overlap constraint |
| `002_signup.sql` | claiming a link, seeding a trade, working out free slots |
| `003_cancel.sql` | cancelling from both sides, and blocking out days |
| `004_photos.sql` | a photograph per treatment, and its storage policies |
| `005_email.sql` | the mail outbox and the triggers that fill it |
| `006_cron.sql` | the schedules |
| `007_reminders.sql` | the day-before reminder (Pro) |
| `008_billing.sql` | plan state |
| `009_lockdown.sql` | **closes three real holes — see below** |
| `010_abuse.sql` | the booking caps, the honeypot, the pseudonymised IP |
| `011_clients.sql` | the per-studio client record |
| `012_rebook.sql` | the rebooking nudge, and every rule that keeps it legal |
| `013_brand.sql` | her colour, her logo, her card layout |
| `014_patch.sql` | patch tests: the window, the lifetime, the refusal |
| `015_venue.sql` | where the appointment happens — her address, or the client's |
| `016_proplus.sql` | the third plan, and the insurance pack it is for |
| `017_deposits.sql` | deposits paid straight to her, which we never touch |
| `018_earn.sql` | the four things Pro+ does for her diary: the waiting list, standing appointments, the lapsed-test nudge, and what an hour earns |
| `019_sector.sql` | twelve trades instead of four; hair colour finally asks for a patch test; and a colour appointment becomes two spans with a bookable gap between them |
| `020_pay.sql` | the whole price up front as well as a deposit; a cancellation window seeded from the trade; three honest confirmation emails and the receipt that was missing; and fourteen days of Pro+ for every new studio |
| `021_lockdown.sql` | **the lockdown 009 could not do — see below.** Every migration that adds a function must end with `select lockdown();` |
| `022_pgcrypto_path.sql` | pgcrypto lives in `extensions` on Supabase, not `public` — without this, nobody can book |
| `023_tenant_read.sql` | **the bank details stop being a public read — see below.** `lockdown()` now polices policies and table grants too, not just functions |
| `024_mail_lease.sql` | a pick-up stops costing a delivery attempt: the outbox gets a lease instead of a counter that anybody could spend |
| `025_paylink.sql` | a payment link can no longer be a `javascript:` URI, and `patch_status()` comes off the public list |
| `026_trigger_privilege.sql` | two triggers ran as the caller and called helpers she may not; `lockdown()` now polices that too |
| `027_patch_test_seed.sql` | **a new client could not book anything** on three trades: the page demanded a patch test and offered none |
| `028_trade_palette.sql` | a palette per trade, so a barber's booking page is not blush — with the contrast rule enforced in the database |
| `029_slot_taken_readonly.sql` | **`anon` could delete every booking on the platform through a view — see below.** `lockdown()` now sweeps views as well as tables and functions |
| `030_launch_hardening.sql` | the Pro+ earnings panel was only Pro+ in the browser; the outbox kept every client's name and email for ever; `prune_ip_keys()` had never been scheduled |
| `031_trial_notice.sql` | three days' notice before a Pro+ trial ends — nothing used to happen between the trial starting and `expire_plans()` dropping her |
| `032_service_tables.sql` | **RLS does not gate `TRUNCATE`.** Seven policy-less tables still carried the default ACL's grants; `lockdown()` now sweeps them |
| `033_erasure.sql` | the right to erasure, keeping the smallest record that still defends an insurance claim — and a purge that ends the keeping |
| `functions/` | three edge functions: send-mail, checkout, stripe-webhook |
| `../app/` | sign in, the wizard, her dashboard |
| `../book/` | her clients' booking page, and their manage page |

Apply the SQL files in order.

### Why `021_lockdown.sql` exists, and the rule it imposes

`009` revokes `EXECUTE` on every function in `public` from `PUBLIC`. On a bare
Postgres that is the whole job. On Supabase it is not, and the gap is wide
enough to drive a lorry through:

* `anon` and `authenticated` never held `EXECUTE` *through* `PUBLIC`. Supabase
  installs a **default ACL** on the `public` schema granting it to them
  directly, so revoking from `PUBLIC` never touched either role.
* A default ACL applies at **CREATE time**, and `009` is the ninth migration of
  twenty-one. The sixty-three functions created by `010`–`020` were each handed
  straight back to `anon` as they were created.

Measured on a real project before the fix: `set_plan` (which hands out Pro+),
`deposit_lines` (her bank details), `client_record` (a client's patch-test
history) and `next_mail` were all callable by `anon` — and the anon key is
published in the browser.

`test_billing.sh` asserts she cannot grant herself Pro, and **passed the whole
time**, because a bare Postgres has no such default ACL. The test was right;
the environment it ran in was not. `test_lockdown.sh` now installs that default
ACL before applying anything, so the suite runs in the shape the real database
is in.

The obvious fix does not work, and it is worth knowing why before trying it
again:

```sql
alter default privileges in schema public
  revoke execute on functions from public, anon, authenticated;
```

This removes Supabase's grant, but a default ACL that ends up equal to
Postgres's own built-in default is deleted outright — and the built-in default
for a function is `EXECUTE` to `PUBLIC`, of which every role is a member.
Measured across four orderings, including `FOR ROLE` and keeping the row alive
with an unrelated grant: `anon` could still call it every time. An event
trigger would catch it, but creating one needs superuser, which Supabase's
`postgres` role is not.

So the sweep is a function, and:

> **Every migration that creates a function must end with `select lockdown();`**

`lockdown()` revokes from `public`, `anon` and `authenticated` across the
schema, re-grants exactly the 32 entry points the pages use, and then asserts
the result — raising if anything outside the public fourteen is still reachable
by `anon`. Extension-owned functions (`btree_gist` installs its own into
`public`) are left alone.

Since 023 it asserts two more things, for the reason in the next section:

* no permissive `SELECT`/`ALL` policy whose `USING` clause is exactly `true`
  exists on any table but `opening`, `closure` and `reserved_slug`. A fourth
  table joining that list is a decision somebody has to write into the array.
* `anon` holds no `SELECT` on `tenant` at all.

### Why `023_tenant_read.sql` exists

`001` gave `tenant` a `for select using (true)` policy, and at the time that
was right: the table held the shop front and nothing else. Then `008`, `013`,
`015`, `016`, `017` and `020` added her bank details and her Stripe ids to the
same table, and nobody went back to the policy. RLS cannot restrict columns —
`009` says so itself, which is why the billing guard had to be a trigger — so
one request with the published anon key returned a sort code, an account
number and an account holder for **every studio on the platform**:

```
GET /rest/v1/tenant?select=slug,deposit_name,deposit_sort,deposit_account
```

`017` states the intended rule in as many words: the amount is public, the
account is not, so `get_studio()` carries the amount and `get_booking()`
carries the account. Both functions implement that correctly. Both were
bypassed by reading the table instead of calling them.

`test_booking.sh` asserted that `get_studio()` does not return account
details, which is true. Nothing asserted that the table does not. It is the
same shape as the hole `021` documents: **the test was right about the thing it
tested.** `test_tenant_read.sh` now installs Supabase's default ACL for tables
as well as functions, asserts the hole is open before `023`, and asserts both
locks after it.

The two locks are the policy and the privilege, because either alone is one
mistake from being reopened. Column privileges are deliberately *not* used:
`revoke select (deposit_sort) on tenant from anon` reads like the obvious
answer and does nothing, since a table-level `SELECT` grant overrides any
column-level revoke beneath it.

### Why `025_paylink.sql` exists

Two bits of surface, both found by the same audit.

`esc()` on the client pages replaces `&` `<` `>` `"` and `'`, which is right
for text and does nothing to a scheme. `javascript:alert(1)` contains none of
those five characters, so it went through `esc()` unchanged into an `href` on
**both** `book/manage.html` and `book/index.html`, and ran when her client
tapped "Pay here" — on a page that is already talking about money. The only
guard was in the browser, and her settings are saved with
`sb.from("tenant").update(...)`, so a studio with her own token could PATCH
PostgREST directly and never meet it. Her clients are the victims, not her,
which is what makes it worth a constraint rather than a note.

Now a `check` constraint on `tenant.deposit_link`, where PostgREST cannot go
round it, plus a `safeUrl()` on both pages so a link that is not `https` is
rendered as plain text instead. `deposit_paypal` deliberately gets no
constraint: `paypal.me/hername` with no scheme is the documented format for
that field and both pages already prefix it.

`patch_status(slug, email)` answered "is this address a client of this studio,
and when was she last patch tested" to anybody holding the anon key, with no
rate limit — the caps in `010` are counted from the `booking` table, so they
only exist for `book()`. A patch test evidences allergy testing, and `011`
names allergies outright as an example of what goes in `client.notes`.

It is now off the public list, because **nothing ever called it**: the booking
page does patch tests through `get_studio()`'s `patch_test_hours` and
`records_patch_test`, and through `book()`'s `P0005` refusal. The function
stays in the schema; whoever writes the caller it was meant for puts it back
on the list, and has to answer the enumeration question then rather than
inheriting the answer by accident.

## The two things worth reading the code for

### Nothing can double-book

The old page could not lock a slot: two people on two devices could both take
09:00 and both get a confirmation. Checking "is it free?" in application code
does not fix that, it only narrows the window between the check and the insert.
So the refusal lives in the database:

```sql
exclude using gist (
  tenant_id with =,
  tstzrange(starts_at, ends_at, '[)') with &&
) where (status = 'confirmed')
```

A range overlap rather than an equality test, because a 90-minute full set
booked at 09:00 has to block 10:00 too. Fifty simultaneous attempts on one slot
produce exactly one booking and forty-nine refusals.

### What 009 fixed

The billing tests found three real problems, all of which would have shipped:

1. **Postgres grants `EXECUTE` on a new function to `PUBLIC` by default**, so
   every `SECURITY DEFINER` function was callable by an anonymous visitor. Most
   check `auth.uid()` and fail safely; three did not. `next_mail()` hands back
   the outbox, which holds client names and email addresses. `setting()`
   returned any row of `platform_setting`, where `006` was storing a
   service-role key. `set_plan()` would have let anybody put any studio on Pro.
   009 revokes from `PUBLIC` and grants back only what each caller needs.
2. **RLS cannot restrict columns**, and `tenant_own` is `FOR ALL` on the whole
   row, so a studio could set its own `plan` to `'pro'` with an ordinary
   update. A trigger now refuses writes to the billing columns unless a
   transaction-local flag is set, which only `set_plan` and `expire_plans` can
   raise.
3. **The service-role key is no longer stored in a table at all.** It goes
   inline in the cron schedule, which lives in `cron.job` and is readable only
   by `postgres`.

The tests now run as a role that is a *member of* `authenticated`, rather than
one granted everything directly — a blanket grant in the harness had been
quietly undoing the very lockdown it was meant to check.

## Testing

```
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
./test_pay.sh          # what is due up front, the three emails, and the trial
./test_lockdown.sh     # that anon cannot reach what it must not, under Supabase's own ACL
./test_tenant_read.sh  # that her bank details are not a public read, and the shop front still is
./test_mail_lease.sh   # that a pick-up cannot retire a message nobody tried to send
./test_paylink.sh      # that a payment link cannot be a javascript: URI, in either layer
./test_trigger_privilege.sh # that a trigger never needs a privilege she must not have
./test_bookable.sh     # that a brand new client can book SOMETHING, in every trade
./test_palette.sh      # a palette per trade, and that none of them is unreadable
./test_extpath.sh      # booking still works with pgcrypto outside public, as Supabase has it
./test_function.sh     # the three edge functions type-check
node test_app.js       # her dashboard, end to end
node test_book.js      # her clients' pages, end to end
node test_routing.js   # what each address serves, and where the slug comes from
node test_marketing.js # layout on eight screens, and contrast on every style
node test_story.js     # the Stories card and her palette, by counting ink
node test_links.js     # every link, robots, the sitemap, what stays unindexed
node test_speed.js     # requests and bytes on a first visit, against a budget

node shots.js [dir]    # not a test: photographs every screen, for looking at
```

The SQL suites need `postgresql-16` and a non-root user, because Postgres
refuses to run as root. They build a throwaway cluster each time.

**Run `../build.sh` first.** Every browser suite reads `dist/`, over HTTP, from
the little server in `serve.js` — which applies Render's own resolution order,
so a real file beats the catch-all rewrite exactly as it does in production.
They used to open `file://` URLs, which cannot see an absolute path or the
rewrite at all; the bug that made `/studio-mila` resolve its slug as
`booked-in` was invisible to every one of them.

The front-end suites drive a stubbed Supabase client: they test this code's own
logic and make no claim about supabase-js itself. Only Chromium is installed
here, so **real Safari has never been tested** — that remains a gap.

## Turning it on

1. Create a Supabase project.
2. Apply `001` to `033` in order in the SQL editor.
3. Put the project URL, anon key and functions URL into `platform/config.js`.
   The anon key belongs in a browser; the service-role key never does.
4. In Auth settings, add the URL `app/` is served from to the redirect allow
   list, or the emailed sign-in link will bounce.
   **Verify `booked-in.co.uk` with Resend, not `ysbdesigns.uk`.** Confirmations
   land in a lash client's inbox and she has never heard of YSB Designs, so a
   mail from that domain reads as spam. `hello@ysbdesigns.uk` is only where
   people write *to* us.
5. Deploy the functions and set their secrets:
   ```
   supabase functions deploy send-mail --no-verify-jwt
   supabase functions deploy checkout
   supabase functions deploy stripe-webhook --no-verify-jwt
   supabase secrets set RESEND_API_KEY=... MAIL_FROM="Booked In <book@booked-in.co.uk>"
   supabase secrets set STRIPE_SECRET_KEY=... STRIPE_WEBHOOK_SECRET=whsec_...
   supabase secrets set STRIPE_PRICE_MONTHLY=price_... STRIPE_PRICE_YEARLY=price_...
   supabase secrets set STRIPE_PRICE_PLUS_MONTHLY=price_... STRIPE_PRICE_PLUS_YEARLY=price_...
   supabase secrets set SITE_URL=https://yourdomain
   ```
   `stripe-webhook` uses `--no-verify-jwt` because Stripe sends no Supabase JWT;
   the signature check inside it is what authenticates the caller.

   `send-mail` uses it for the same kind of reason: since `024` it requires the
   service-role bearer that the cron job in step 7 has always sent, and
   compares it against its own `SUPABASE_SERVICE_ROLE_KEY`. Letting Supabase
   verify the JWT instead would not be enough — the gateway checks that a token
   is validly signed, not which role it carries, so it accepts the published
   anon key too. Before `024` the handler took no request argument at all, and
   anybody who knew the URL could drain the outbox.

   **A changed secret needs a redeploy.** `send-mail` is hit by cron every
   minute, so its worker never goes cold and keeps the environment it booted
   with. Setting `MAIL_FROM` and waiting does nothing; the function must be
   deployed again before it sees it. This cost twenty minutes once already:
   the outbox kept reporting Resend's *test sender* error long after the
   secret was saved, which reads exactly like the secret being wrong.

   `send-mail?whoami=1` answers with the sender the running worker actually
   has, so that question can be settled in one call instead of inferred from
   a bounce. It needs the same service-role bearer as a normal call, and the
   from-address is not a secret — it is on the front of every email sent.

   **Resend will not send from a `partially_verified` domain.** DKIM verifying
   first is normal and is not enough: the SPF pair at `send` has to go green
   too, and until it does every send is refused with "The <domain> domain is
   not verified". Do NOT press verify again to hurry it along — that restarts
   the whole check and knocks already-verified records back to pending.
6. Point a Stripe webhook at `stripe-webhook` for `checkout.session.completed`
   and the three `customer.subscription.*` events.

   Both Pro+ price ids must be set before anyone can buy Pro+. checkout
   refuses that tier outright rather than falling back to the Pro price,
   which is the right behaviour and looks exactly like a bug if you have
   forgotten them: "That plan is not on sale yet."

   The whole path — checkout session, hosted page, signed webhook, plan
   change — has been run end to end against a Stripe sandbox, and the two
   bugs that run found are fixed and covered by `test_webhook.sh`.

   **What it could not cover, and what to check first:**
   `stripe-webhook` authenticates to Supabase with
   `SUPABASE_SERVICE_ROLE_KEY`, and the value Supabase injects under that
   name is not the dashboard's service-role JWT. That difference is what
   broke `send-mail` and took a redesign. The sandbox run stubbed Supabase,
   so it proved the Stripe half and says nothing about this half.

   So put ONE real subscription through before telling anybody the plans
   are live, and watch `tenant.plan` actually change. If it does not, the
   function logs will say `set_plan: permission denied` and the fix is the
   one `send-mail` already uses: let the database decide, rather than
   trusting a key whose value is not what its name suggests.
7. **This repository is public.** Copy `006_cron.sql` to `006_cron.local.sql`
   (gitignored), put your functions URL and service-role key in the copy, and
   run that — or paste it into the Supabase SQL editor and never save it.
   Never fill in the committed template. The `Authorization` header in that
   job is load-bearing as of `024`: it is what `send-mail` checks. An existing
   schedule needs no change, because the header was always being sent — nothing
   was reading it.
8. Serve the repository. `app/` is hers; `book/?s=<link>` is her clients'.
   `book/` also reads the link from a subdomain, so `hername.booked-in.co.uk` works
   once there is wildcard DNS in front of it.

## Honest gaps

- **No email has ever actually been sent from here.** Everything that composes
  one is tested; the sender type-checks but needs a provider key to prove it.
- **No payment has ever actually been taken.** Same: the plan logic is tested,
  the Stripe functions type-check, nothing has run against live Stripe.
- **Deposits are not built.** They need Stripe Connect so the money goes to
  her, not to us — a different and larger piece of work than subscriptions.
  The marketing page lists deposits under Pro; either build them or cut that
  line before anyone pays.
- **"Your own domain" is also on the Pro list and is not built.**
- **Rescheduling** is cancel-then-rebook, which is honest but clumsy.
- **Real Safari is untested**, as above.

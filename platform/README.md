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
| `functions/` | three edge functions: send-mail, checkout, stripe-webhook |
| `../app/` | sign in, the wizard, her dashboard |
| `../book/` | her clients' booking page, and their manage page |

Apply the SQL files in order.

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
./test_function.sh     # the three edge functions type-check
node test_app.js       # her dashboard, end to end
node test_book.js      # her clients' pages, end to end
node test_routing.js   # what each address serves, and where the slug comes from
node test_marketing.js # layout on eight screens, and contrast on every style
node test_story.js     # the Stories card, by counting ink on the canvas
node test_links.js     # every link, robots, the sitemap, what stays unindexed
node test_speed.js     # requests and bytes on a first visit, against a budget
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
2. Apply `001` to `012` in order in the SQL editor.
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
   supabase secrets set SITE_URL=https://yourdomain
   ```
   `stripe-webhook` uses `--no-verify-jwt` because Stripe sends no Supabase JWT;
   the signature check inside it is what authenticates the caller.
6. Point a Stripe webhook at `stripe-webhook` for `checkout.session.completed`
   and the three `customer.subscription.*` events.
7. **This repository is public.** Copy `006_cron.sql` to `006_cron.local.sql`
   (gitignored), put your functions URL and service-role key in the copy, and
   run that — or paste it into the Supabase SQL editor and never save it.
   Never fill in the committed template.
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

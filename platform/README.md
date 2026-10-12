# Peony — platform

## Where this is up to

`001_schema.sql` is Phase 1's hard part: multi-tenancy, the travel-day
availability model, and a booking write that cannot double-book.

Nothing here is provisioned yet. Creating the Supabase project is an external
action, so it is yours to approve — the schema is written to be applied as-is.

## Why the slot locking looks the way it does

The booking page as it stands cannot lock a slot. Two people on two devices can
both take 09:00 and both get a confirmation. Checking "is this free?" in
application code does not fix it; it only narrows the window between the check
and the insert.

So the refusal lives in the database:

```sql
alter table booking add constraint booking_no_overlap
  exclude using gist (
    tenant_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status = 'confirmed');
```

It is a range overlap rather than an equality test because a 90-minute full set
booked at 09:00 has to block 10:00 too. Two concurrent transactions cannot both
satisfy it: the second to commit raises `23P01` and rolls back, and `book()`
turns that into "Someone just took that time."

Public booking goes through `book()` and nothing else. It is `security definer`,
so a signed-out visitor can create a booking without being able to read or write
the booking table — which is also what keeps one tenant's client list away from
every other tenant. The client side reads free/busy from the `slot_taken` view,
which exposes times only, never names or emails.

## Testing it

```
./test_booking.sh
```

Needs `postgresql-16` and a non-root user (Postgres refuses to run as root). It
builds a throwaway cluster, applies the migration unmodified, and fires real
concurrent `book()` calls at one slot.

Last run: 20 and 50 simultaneous attempts each produced exactly one booking and
N-1 refusals, with the overlap, opening-hours, closed-date and cancellation
cases all behaving.

## What exists now

| | |
|---|---|
| `001_schema.sql` | tenants, treatments, travel days, bookings, and the overlap constraint |
| `002_signup.sql` | claiming a link, seeding a trade, and working out free slots |
| `../app/` | sign in, the three-step wizard, and her dashboard |
| `../book/` | the page her clients book on |

Run it with `./test_booking.sh`, `./test_signup.sh`, `node test_app.js` and
`node test_book.js`. The two front-end suites drive a stubbed client, so they
test this code's own logic and make no claim about supabase-js itself.

## Turning it on

1. Create a Supabase project.
2. Apply `001_schema.sql` then `002_signup.sql` in the SQL editor.
3. Put the project URL and the anon key into `platform/config.js`. The anon key
   belongs in the browser; the service_role key never does.
4. In Auth settings, add the URL `app/` is served from to the redirect allow
   list, or the emailed sign-in link will bounce.
5. Serve the repository. `app/` is hers, `book/?s=<link>` is her clients'.
   `book/` also reads the link from a subdomain, so `hername.peony.uk` works
   once there is wildcard DNS in front of it.

## Still to build

- Email: nothing is sent yet. Her confirmation and the client's both need a
  trigger on `booking` calling an edge function. The copy on both pages
  currently promises an email, so this is the next thing or the copy is a lie.
- Stripe subscriptions, and enforcing the free/Pro split (today `plan` is a
  column nothing acts on beyond the footer credit)
- Deposits, which need Stripe Connect so the money goes to her, not to us
- Photographs against each treatment
- Cancelling and rescheduling from the client's side

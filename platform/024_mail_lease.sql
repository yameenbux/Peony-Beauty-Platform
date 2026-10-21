-- 024 — a pick-up stops costing a delivery attempt.
--
-- THE BUG. next_mail() counted the attempt at the moment it handed the batch
-- out, not at the moment a send was reported:
--
--     update mail_outbox m set attempts = m.attempts + 1
--      where m.id in (select id from mail_outbox
--                      where sent_at is null and attempts < 5 ...)
--
-- and `attempts < 5` is the only thing standing between a message and being
-- abandoned. So five pick-ups retire a message whether or not anybody ever
-- tried to send it. That was reachable from outside, because send-mail is
-- deployed --no-verify-jwt and its handler took no request argument at all:
--
--     Deno.serve(async () => { ... })        -- no JWT, no method, no secret
--
-- Anyone who knew the URL - it is in FUNCTIONS_URL in config.js, served to
-- every browser - could POST it six times and permanently delete every queued
-- confirmation, reminder, cancellation and deposit instruction. Nothing
-- retries them, nothing alerts, nothing shows it in the app. A studio finds
-- out when a client does not turn up.
--
-- The same thing happens with no attacker at all: Resend rate-limits a burst,
-- the minute-by-minute cron keeps picking the batch up, and five minutes later
-- the mail is gone.
--
-- send-mail now requires the service-role bearer the cron job already sends,
-- which closes the door. This file fixes the counter, because the door is not
-- the whole bug: a genuine provider outage walks through it legitimately.

-- ------------------------------------------------------------------ the fix
-- Two counters instead of one, because they answer two different questions.
--
--   attempts - how many times a send was actually tried and reported back.
--              This is the one that gives up at five, and now only moves when
--              mail_sent() says what happened.
--
--   claims   - how many times a batch has carried this row out of the door.
--              Not a reason to give up at five; a pick-up is free. It is here
--              so a drainer that dies before reporting cannot loop silently
--              forever, and so there is something to look at when one does.
-- `if not exists` where the rest of the schema does not bother, because this
-- one is likely to be run twice: it is applied by hand in a SQL editor, and
-- everything else in the file - create or replace, revoke, lockdown() - is
-- already idempotent, so these two lines were the only reason a second attempt
-- after a half-applied first one would fail.
alter table mail_outbox add column if not exists claimed_at timestamptz;
alter table mail_outbox add column if not exists claims     int not null default 0;

-- mail_pending_idx (created_at) where sent_at is null already serves the
-- claim query; the extra predicates are cheap over a queue this small.

-- A lease rather than a flag. A claimed row is off the queue for five minutes,
-- which does three jobs at once: two drainers never pick up the same message
-- (next_mail is also called concurrently by the one-a-minute schedule), a run
-- that dies before calling mail_sent() is retried instead of being lost, and a
-- failure that leaves claimed_at set gets five minutes of backoff before
-- anybody tries the provider again.
create or replace function next_mail(p_limit int default 20)
returns setof mail_outbox language sql volatile security definer set search_path = public as $$
  update mail_outbox m
     set claimed_at = now(),
         claims     = m.claims + 1
   where m.id in (
     select id from mail_outbox
      where sent_at is null
        and attempts < 5                 -- reported failures, not pick-ups
        and claims   < 50                -- a drainer that never reports back
        and (claimed_at is null or claimed_at < now() - interval '5 minutes')
      order by created_at
      limit p_limit
      for update skip locked          -- two drainers must not send the same mail twice
   )
  returning m.*;
$$;

-- The outcome, and the only thing that may retire a message. On success the
-- stamp goes on and the row is never picked again. On failure the stamp is
-- cleared so it is retried, the attempt is counted, and claimed_at is left
-- alone so the lease above delays that retry rather than hammering a provider
-- that has just said no.
create or replace function mail_sent(p_id uuid, p_error text default null)
returns void language sql volatile security definer set search_path = public as $$
  update mail_outbox
     set sent_at    = case when p_error is null then now() else null end,
         attempts   = case when p_error is null then attempts else attempts + 1 end,
         last_error = p_error
   where id = p_id;
$$;

-- ----------------------------------------------------------------- the view
-- Mail that has given up, which until now nothing could see. The counter bug
-- was invisible for the same reason it was dangerous: a message at attempts=5
-- simply stopped existing as far as the system was concerned.
--
-- service_role only, like everything else that touches the outbox. Call it
-- from the Supabase SQL editor, or wire it to whatever does the alerting:
--
--     select * from mail_stuck();
create or replace function mail_stuck()
returns table (id uuid, kind text, created_at timestamptz,
               attempts int, claims int, last_error text)
language sql stable security definer set search_path = public as $$
  select m.id, m.kind, m.created_at, m.attempts, m.claims, m.last_error
    from mail_outbox m
   where m.sent_at is null
     and (m.attempts >= 5 or m.claims >= 50)
   order by m.created_at;
$$;

-- ------------------------------------------------------------- the grants
-- The outbox holds the rendered body of every email ever queued: a client's
-- first name, her full name, her email, her phone number, and for a deposit
-- mail the studio's sort code and account number in the text. RLS with no
-- policy already default-denies it, which is a stronger position than `tenant`
-- was in - but Supabase's default ACL still handed anon and authenticated
-- SELECT, INSERT, UPDATE and DELETE on it, and "the dangerous grant plus a
-- policy that happens to be right" is exactly the arrangement that produced
-- the bank-detail leak 023 had to undo. Nothing outside service_role has ever
-- read this table: queue_mail_for, next_mail, mail_sent and mail_stuck are all
-- SECURITY DEFINER, so taking the privilege away costs nothing and removes the
-- half of that arrangement that was load-bearing by accident.
revoke select, insert, update, delete on mail_outbox from anon, authenticated;

select lockdown();

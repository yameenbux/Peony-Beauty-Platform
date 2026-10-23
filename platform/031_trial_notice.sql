-- 031 — tell her the trial is ending, before it does.
--
-- create_studio puts every new studio on pro_plus with a trial_until, and
-- expire_plans() drops her to free the moment plan_until passes. Nothing
-- between those two says a word to her.
--
-- So on day fifteen her deposits stop being asked for, her reminders stop
-- going out, and the waiting list stops filling her cancellations - and the
-- first she knows is a client turning up without having paid a deposit she
-- thought was still being collected. That is a bad morning caused by us.
--
-- It is also the worst possible moment to be silent commercially. The day she
-- is about to lose something is the day she is most likely to pay for it, and
-- we were letting it go by without a word.
--
-- Three days' notice, once per trial. Not on the day - she needs a working
-- day to decide - and not a fortnight out, when it is not real yet.
--
-- The tone is deliberately not a countdown. She keeps her page, her clients
-- and her patch-test records whatever she decides, and the mail says so
-- first: the point is that she is not about to be caught out, not that she
-- should be frightened into paying.

-- --------------------------------------------------------------- dedupe --
-- Keyed on the trial as well as the studio, so a studio given a second trial
-- later gets a second notice rather than being silently skipped. Service role
-- only, like rebook_nudge: RLS on, no policy.
create table if not exists trial_notice (
  tenant_id   uuid        not null references tenant(id) on delete cascade,
  trial_until timestamptz not null,
  sent_at     timestamptz not null default now(),
  primary key (tenant_id, trial_until)
);
alter table trial_notice enable row level security;

alter table mail_outbox drop constraint mail_outbox_kind_check;
alter table mail_outbox add constraint mail_outbox_kind_check check (kind in
  ('client_booked','studio_booked','client_cancelled','studio_cancelled',
   'client_reminder','client_rebook','client_patch','client_waitlist',
   'studio_trial_ending'));

-- ---------------------------------------------------------------- queue --
create or replace function queue_trial_notices(p_lead_days int default 3)
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_site text;
begin
  v_site := coalesce(setting('site_url'), 'https://booked-in.co.uk');
  for r in
    select t.id, t.slug, t.display_name, t.timezone, t.plan, t.plan_until,
           t.trial_until, u.email as owner_email
      from tenant t
      join auth.users u on u.id = t.owner
     -- plan_state() is the one place that decides what a plan IS, and it
     -- already knows that a subscription beats a trial. Asking it rather
     -- than re-deriving the rule here is what stops the two drifting.
     where plan_state(t.plan, t.plan_until, t.trial_until,
                      t.stripe_subscription_id) = 'trialing'
       and t.plan_until <= now() + make_interval(days => greatest(p_lead_days, 1))
       and u.email is not null
       and not exists (select 1 from trial_notice tn
                        where tn.tenant_id = t.id
                          and tn.trial_until = t.trial_until)
     for update of t skip locked
  loop
    insert into trial_notice (tenant_id, trial_until)
    values (r.id, r.trial_until)
    on conflict (tenant_id, trial_until) do nothing;
    if not found then continue; end if;    -- another worker got there first

    insert into mail_outbox (kind, to_email, to_name, subject, body)
    values (
      'studio_trial_ending', r.owner_email, r.display_name,
      'Your Pro+ trial ends on ' ||
        trim(to_char(r.plan_until at time zone r.timezone, 'FMDD FMMonth')),
      'Hi ' || r.display_name || E',\n\n' ||
      'Your fourteen days of Pro+ end on ' ||
        trim(to_char(r.plan_until at time zone r.timezone, 'FMDD FMMonth')) ||
        '.' || E'\n\n' ||
      'Nothing disappears from your page and nothing you have set up is lost. ' ||
      'Your booking link, your treatments and photographs, your client list ' ||
      'and your dated patch-test records all stay exactly as they are, on ' ||
      'Free, for as long as you want them. Patch tests stay enforced too - ' ||
      'that is a safety rule, not a feature.' || E'\n\n' ||
      'What stops on that day:' || E'\n' ||
      '  - Deposits paid straight to you' || E'\n' ||
      '  - Reminders before every appointment' || E'\n' ||
      '  - Rebooking, so clients hear from you when they are due' || E'\n' ||
      '  - The waiting list that fills a cancellation' || E'\n' ||
      '  - Standing appointments' || E'\n' ||
      '  - Lapsed patch tests chased for you' || E'\n' ||
      '  - The insurance pack' || E'\n\n' ||
      'If you would like to keep any of it, you can pick a plan here:' ||
        E'\n' || v_site || '/app/' || E'\n\n' ||
      'If Free suits you better, you do not need to do anything at all.' ||
      E'\n\n' || 'Your page: ' || v_site || '/' || r.slug || E'\n\n' ||
      '- Booked In'
    );
    n := n + 1;
  end loop;
  return n;
end $$;

-- ----------------------------------------------------------------- cron --
-- Once a day. The window is three days wide, so a day missed to a restart
-- still catches her on the next run rather than never.
do $c$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice '031: pg_cron is not installed here, so nothing was scheduled';
    return;
  end if;
  begin perform cron.unschedule('bookedin-trial-notice'); exception when others then null; end;
  perform cron.schedule('bookedin-trial-notice', '52 9 * * *',
                        'select queue_trial_notices()');
end $c$;

select lockdown();

-- 030 — three things that should be true before anyone is marketed to.
--
-- 1. my_earnings() WAS NOT ACTUALLY PRO+.
--
-- Every other Pro+ feature refuses in the database: join_waitlist, book_series,
-- client_record and queue_patch_nudges all check the plan and raise P0006. The
-- earnings panel checked it in the browser only - app/index.html hides the card
-- when isPro() is not plus - and the function itself asked nothing but
-- "is this her studio". A studio on Free could call /rest/v1/rpc/my_earnings
-- and read the thing the pricing page sells for GBP 14 a month.
--
-- It is her own data, so this is a paywall hole rather than a leak. It is still
-- the one place a plan is decided in a browser, which 016 went to some trouble
-- to make untrue everywhere else.
--
-- 2. THE OUTBOX KEPT EVERY CLIENT'S NAME AND EMAIL FOR EVER.
--
-- mail_outbox holds to_email, to_name and the rendered body - which for a
-- travelling studio contains the CLIENT'S HOME ADDRESS. A sent message has
-- done its job; what happened lives in booking and client, which are the
-- records with a reason to exist. Keeping the copy indefinitely is personal
-- data held for no purpose, and with real studios about to arrive that stops
-- being theoretical.
--
-- Sent mail older than thirty days goes. Unsent mail is never touched, so
-- nothing in flight can be lost by this.
--
-- 3. prune_ip_keys() HAS NEVER RUN.
--
-- 010 wrote it - it nulls the hashed IP on a booking after seven days, which
-- is the whole reason the hash is defensible - and nothing ever scheduled it.
-- Every IP key taken since launch is still sitting there.

-- -------------------------------------------------------------- 1. earnings
create or replace function my_earnings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_plan text; v_out jsonb;
begin
  select t.plan into v_plan from tenant t where t.owner = auth.uid();
  if v_plan is null then
    raise exception 'Make your page first.' using errcode = 'P0002';
  end if;
  if v_plan <> 'pro_plus' then
    raise exception 'What an hour of your time is worth is part of Pro+.'
      using errcode = 'P0006';
  end if;

  with done as (
    select s.id, s.name, s.price_pence, s.duration_min,
           count(b.id) as visits,
           coalesce(sum(s.price_pence), 0) as taken_pence,
           coalesce(sum(s.duration_min), 0) as minutes
      from service s
      join tenant t on t.id = s.tenant_id and t.owner = auth.uid()
      left join booking b on b.service_id = s.id
                         and b.status = 'confirmed'
                         and b.starts_at < now()
                         and b.starts_at > now() - interval '180 days'
     where s.active
     group by s.id, s.name, s.price_pence, s.duration_min
  )
  select jsonb_build_object(
    'since_days', 180,
    'treatments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', id, 'name', name, 'visits', visits,
               'price_pence', price_pence, 'duration_min', duration_min,
               'taken_pence', taken_pence,
               -- The rate the price list implies, which is the number she can
               -- act on: it exists even for a treatment nobody has booked yet.
               'per_hour_pence', case when duration_min > 0
                   then round(price_pence * 60.0 / duration_min)::int else null end)
             -- best-paying first: the list is an argument, not a catalogue
             order by case when duration_min > 0
                      then price_pence * 60.0 / duration_min else 0 end desc)
        from done), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $$;

-- ----------------------------------------------------------------- 2. outbox
-- Thirty days is long enough to answer "did that email go?" from the row
-- itself, and short enough that the copy is not a second client list.
create or replace function prune_mail(p_days int default 30)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with gone as (
    delete from mail_outbox
     where sent_at is not null
       and sent_at < now() - make_interval(days => greatest(p_days, 1))
    returning 1)
  select count(*) into n from gone;
  return n;
end $$;

-- ------------------------------------------------------------------- 3. cron
-- Guarded on the extension rather than on the error, so that a box without
-- pg_cron - every one of the SQL test suites builds exactly that - applies
-- this file cleanly and says so, while production really schedules the jobs.
-- Unscheduling a job that is not there raises, and this file must be safe to
-- apply twice, so those are caught individually.
do $c$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice '030: pg_cron is not installed here, so nothing was scheduled';
    return;
  end if;

  begin perform cron.unschedule('bookedin-prune-ip');   exception when others then null; end;
  begin perform cron.unschedule('bookedin-prune-mail'); exception when others then null; end;

  -- Quiet hours, on different minutes, so neither contends with the
  -- every-minute mail sender.
  perform cron.schedule('bookedin-prune-ip',   '24 3 * * *', 'select prune_ip_keys()');
  perform cron.schedule('bookedin-prune-mail', '41 3 * * *', 'select prune_mail()');
end $c$;

select lockdown();

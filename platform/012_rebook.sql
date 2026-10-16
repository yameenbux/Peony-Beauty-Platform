-- Booked In — the nudge that fills next month
--
-- Lash infills are every two or three weeks. Gel is every three or four. The
-- client knows this and still forgets, and the studio finds out when a gap
-- appears in a week she thought was full. The single highest-value thing this
-- software can do is notice that Ruby is due and say so, once, with a link
-- straight to a time that exists.
--
-- This is what Pro is for. Reminders stop no-shows; this makes money.
--
-- THREE RULES IT WILL NOT BREAK, because an automated email to somebody else's
-- client is the fastest way to lose a studio her clients' trust and ours:
--
--   1. Nothing sends until she turns it on. Every studio starts with it off,
--      even though the intervals below are filled in for her, because quietly
--      emailing a stranger's clients on her behalf is not a default anyone
--      should be opted into.
--   2. One message per visit, ever, enforced by a primary key rather than by
--      being careful.
--   3. Every message carries a one-tap off switch, and it is honoured for that
--      studio for good. Under PECR this is the soft opt-in: an existing client,
--      about a treatment she has already had, with a way out in every message.
--      Miss any of those three and it is marketing, which it is not.

-- --------------------------------------------------------------- how often
-- Null means "do not nudge for this treatment" - a bridal trial or a one-off
-- patch test has no next one.
alter table service add column rebook_weeks int
  check (rebook_weeks is null or rebook_weeks between 1 and 52);

-- A starting interval, guessed from the name. A setting nobody fills in is a
-- setting nobody uses, so the feature has to arrive already configured; the
-- master switch below is what stops that being presumptuous.
--
-- These are the ordinary intervals for the work. A removal or a trial gets
-- nothing, because there is no next one.
create or replace function guess_rebook_weeks(p_name text)
returns int language sql immutable set search_path = public as $$
  select case
    when p_name ilike '%removal%' or p_name ilike '%soak off%'
      or p_name ilike '%trial%'   or p_name ilike '%patch%'      then null
    when p_name ilike '%infill%'                                 then 3
    when p_name ilike '%lash%'  or p_name ilike '%extension%'    then 3
    when p_name ilike '%blow dry%'                               then 3
    when p_name ilike '%gel%'   or p_name ilike '%biab%'
      or p_name ilike '%nail%'  or p_name ilike '%manicure%'
      or p_name ilike '%pedicure%'                               then 4
    when p_name ilike '%brow%'  or p_name ilike '%wax%'
      or p_name ilike '%tint%'                                   then 4
    when p_name ilike '%cut%'                                    then 6
    when p_name ilike '%highlight%'                              then 10
    when p_name ilike '%facial%' or p_name ilike '%massage%'     then 6
    else 4
  end;
$$;

update service s set rebook_weeks = guess_rebook_weeks(s.name);

-- The same guess for every treatment made from now on. A trigger rather than a
-- line inside create_studio() because treatments are also added one at a time
-- from the dashboard, and a feature that only works for the five she was given
-- at signup is not much of a feature.
--
-- INSERT only, deliberately: this suggests an interval once and then never
-- argues with her. Setting it back to null to stop nudging for a treatment has
-- to stick, and it would not if the trigger also fired on update.
create or replace function suggest_rebook_weeks()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.rebook_weeks is null then
    new.rebook_weeks := guess_rebook_weeks(new.name);
  end if;
  return new;
end $$;

create trigger service_rebook_default
  before insert on service
  for each row execute function suggest_rebook_weeks();

alter table tenant add column rebook_on boolean not null default false;
-- How many days before she is due. Nudging on the day is too late to be any
-- use: the point is to be asked while next week still has room in it.
alter table tenant add column rebook_lead_days int not null default 3
  check (rebook_lead_days between 0 and 14);

-- ------------------------------------------------------------- the off switch
alter table client add column rebook_opt_out boolean not null default false;
-- Unguessable, and the only thing the unsubscribe link carries. It identifies
-- one client at one studio, so following it can reveal nothing about anyone
-- else and cannot be used to go fishing.
alter table client add column unsub_token uuid not null default gen_random_uuid();
create unique index client_unsub_idx on client (unsub_token);

-- ----------------------------------------------------------------- one each
-- The booking is the primary key, so a second nudge for the same visit cannot
-- be written even if two drainers run at once and both think they are first.
create table rebook_nudge (
  booking_id uuid primary key references booking(id) on delete cascade,
  tenant_id  uuid not null references tenant(id) on delete cascade,
  client_id  uuid not null references client(id)  on delete cascade,
  sent_at    timestamptz not null default now()
);
alter table rebook_nudge enable row level security;   -- service_role only

alter table mail_outbox drop constraint mail_outbox_kind_check;
alter table mail_outbox add constraint mail_outbox_kind_check check (kind in
  ('client_booked','studio_booked','client_cancelled','studio_cancelled',
   'client_reminder','client_rebook'));

-- ------------------------------------------------------------------ the run
create or replace function queue_rebook_nudges()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_site text;
begin
  v_site := coalesce(setting('site_url'), 'https://booked-in.co.uk');
  for r in
    select b.id as booking_id, b.tenant_id, b.client_id
      from booking b
      join tenant  t on t.id = b.tenant_id
      join service s on s.id = b.service_id
      join client  c on c.id = b.client_id
     where t.plan = 'pro'
       and t.rebook_on
       and s.rebook_weeks is not null
       and b.status = 'confirmed'
       and not c.rebook_opt_out
       and b.starts_at < now()                       -- she has actually been
       -- The latest visit she has had here, and only that one. Without this
       -- every appointment she ever had would come due in turn and she would
       -- get one message per visit on the same afternoon.
       and b.starts_at = (select max(b2.starts_at) from booking b2
                           where b2.client_id = c.id
                             and b2.status = 'confirmed'
                             and b2.starts_at < now())
       -- due, less the warning she wants to give. greatest(.., 1) because a
       -- weekly treatment with a long lead time would otherwise come due
       -- before the appointment had finished.
       and now() >= b.starts_at + make_interval(days =>
             greatest(s.rebook_weeks * 7 - t.rebook_lead_days, 1))
       -- Three months is the line between a nudge and a guilt trip. Past it,
       -- she has moved on or gone elsewhere, and an email about a treatment
       -- from the spring is just junk.
       and b.starts_at > now() - interval '90 days'
       -- Somebody with an appointment in the diary does not need telling to
       -- make one.
       and not exists (select 1 from booking b3
                        where b3.client_id = c.id
                          and b3.status = 'confirmed'
                          and b3.starts_at > now())
       and not exists (select 1 from rebook_nudge rn where rn.booking_id = b.id)
     for update of b skip locked
  loop
    insert into rebook_nudge (booking_id, tenant_id, client_id)
    values (r.booking_id, r.tenant_id, r.client_id)
    on conflict (booking_id) do nothing;
    if not found then continue; end if;      -- somebody else got there first

    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    select b.id, 'client_rebook', c.email, c.name,
      'Time for your ' || lower(s.name) || '?',
      'Hi ' || split_part(c.name, ' ', 1) || E',\n\n' ||
      'It has been ' ||
      (extract(day from now() - b.starts_at)::int / 7) || ' weeks since your ' ||
      lower(s.name) || ' with ' || t.display_name ||
      ', so you are about due.' || E'\n\n' ||
      'Pick a time that suits you: ' || v_site || '/' || t.slug || E'\n\n' ||
      'If you would rather not be reminded, turn these off here: ' ||
      v_site || '/book/manage.html?u=' || c.unsub_token::text
      from booking b
      join service s on s.id = b.service_id
      join tenant  t on t.id = b.tenant_id
      join client  c on c.id = b.client_id
     where b.id = r.booking_id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ----------------------------------------------------------- the unsubscribe
-- Public, because the person clicking it is not signed in to anything and
-- never will be. The token is the whole authorisation, which is why it reveals
-- only the studio's name: enough for her to know what she has just turned off.
create or replace function set_rebook_opt_out(p_token uuid, p_off boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio text;
begin
  update client c set rebook_opt_out = p_off, updated_at = now()
   where c.unsub_token = p_token
  returning (select t.display_name from tenant t where t.id = c.tenant_id) into v_studio;
  if v_studio is null then
    raise exception 'That link is not valid.' using errcode = 'P0002';
  end if;
  return jsonb_build_object('studio', v_studio, 'opted_out', p_off);
end $$;

-- ------------------------------------------------------- what the app reads
-- my_studio() gains the three new fields. Redefined whole rather than patched,
-- because that is the only way Postgres takes a change to a function body, and
-- leaving it alone would mean a dashboard that cannot see its own settings.
create or replace function my_studio()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'plan', t.plan, 'timezone', t.timezone,
    'notice_hours', t.notice_hours, 'slot_step_min', t.slot_step_min,
    'rebook_on', t.rebook_on, 'rebook_lead_days', t.rebook_lead_days,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'price_pence', s.price_pence,
               'duration_min', s.duration_min, 'active', s.active, 'sort', s.sort,
               'rebook_weeks', s.rebook_weeks)
             order by s.sort, s.name)
        from service s where s.tenant_id = t.id), '[]'::jsonb),
    'openings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'weekday', o.weekday, 'area', o.area,
               'starts', o.starts, 'ends', o.ends) order by o.weekday, o.starts)
        from opening o where o.tenant_id = t.id), '[]'::jsonb),
    'bookings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'ref', b.ref, 'starts_at', b.starts_at,
               'ends_at', b.ends_at, 'client_name', b.client_name,
               'client_email', b.client_email, 'client_phone', b.client_phone,
               'status', b.status, 'service', sv.name, 'price_pence', sv.price_pence)
             order by b.starts_at)
        from booking b join service sv on sv.id = b.service_id
       where b.tenant_id = t.id and b.starts_at > now() - interval '30 days'), '[]'::jsonb)
  )
  from tenant t where t.owner = auth.uid();
$$;

-- ------------------------------------------------------------------- grants
revoke execute on function guess_rebook_weeks(text)         from public;
revoke execute on function suggest_rebook_weeks()           from public;
revoke execute on function queue_rebook_nudges()            from public;
revoke execute on function set_rebook_opt_out(uuid, boolean) from public;
grant execute on function set_rebook_opt_out(uuid, boolean) to anon, authenticated;
-- my_studio was already granted in 009; replacing the body does not drop that,
-- but the revoke below keeps the default PUBLIC grant off the new definition.
revoke execute on function my_studio() from public;
grant  execute on function my_studio() to authenticated;
-- queue_rebook_nudges is service_role only, like the other senders

-- ----------------------------------------------------------------- schedule
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'no pg_cron: skipping the rebook schedule (not Supabase)';
    return;
  end if;
  perform cron.unschedule('bookedin-rebook')
    where exists (select 1 from cron.job where jobname = 'bookedin-rebook');
  -- Once a day, mid-morning UK time, because that is when somebody will
  -- actually read it and still have the day to book. Never at night.
  perform cron.schedule('bookedin-rebook', '18 10 * * *',
    $cron$ select queue_rebook_nudges(); $cron$);
end $$;

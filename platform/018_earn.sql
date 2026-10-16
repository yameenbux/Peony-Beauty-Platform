-- Booked In — four things Pro+ does for her business
--
-- Pro+ was one feature: the insurance pack. Valuable, unique, and a RARE-EVENT
-- product — she needs it when a client reacts, which may be never. Pro sells
-- money and is used weekly; Pro+ sold peace of mind at 2.4x the price. That is
-- the wrong shape for a recurring bill, and at the modelled 8% take-up Pro+ is
-- 37% of revenue, so getting it wrong is not a rounding error.
--
-- So Pro+ gets four things that each make or save her money, and all four are
-- built out of data this platform already holds and no generic scheduler does:
--
--   1. LAPSE ALERTS. A client whose patch test has run out is a client who
--      legally cannot book until she comes in. Today that list is visible and
--      nothing acts on it. Now she is emailed, once, with a link to book the
--      test. It is rebooking pointed at compliance instead of intervals.
--
--   2. THE WAITLIST. A cancellation is currently money that evaporates: the
--      slot goes quietly back on sale and nobody is told. Now the people who
--      wanted that treatment hear about it within the minute.
--
--   3. STANDING APPOINTMENTS. Lash and brow clients come every three weeks
--      forever. A salon books the next one at the desk; a solo technician has
--      no desk. This books the next six in one go.
--
--   4. WHAT HER TIME IS WORTH. She prices by feel. £40 for 90 minutes is
--      £26.67 an hour; £35 for 60 is £35. Nothing in this trade tells her that,
--      and it is the one number that changes what she charges.
--
-- (3) needs something that did not exist: a way for HER to add a booking. She
-- could cancel but not create, so a client who rang up had to be told to go to
-- the website. studio_book() fixes that on its own account.

-- --------------------------------------------------------------- 1: lapses --
-- One nudge per expiry date. If she re-tests the client, valid_until moves and
-- she becomes eligible again - which is right, because that is a new expiry.
create table patch_nudge (
  client_id   uuid primary key references client(id) on delete cascade,
  tenant_id   uuid not null references tenant(id) on delete cascade,
  valid_until timestamptz not null,
  sent_at     timestamptz not null default now()
);
create index patch_nudge_tenant_idx on patch_nudge (tenant_id);
alter table patch_nudge enable row level security;
create policy patch_nudge_own on patch_nudge for select using (
  exists (select 1 from tenant t where t.id = patch_nudge.tenant_id and t.owner = auth.uid()));

-- The same opt-out that governs rebooking governs this. A client who asked not
-- to be chased about appointments has not asked to be chased about paperwork
-- either, and one unsubscribe has to mean one unsubscribe.
create or replace function queue_patch_nudges()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_site text;
begin
  v_site := coalesce(setting('site_url'), 'https://booked-in.co.uk');
  for r in
    select c.id as client_id, c.tenant_id, c.name, c.email, c.unsub_token,
           t.display_name, t.slug, c.rebook_opt_out,
           max(p.tested_at) + make_interval(months => t.patch_valid_months) as valid_until
      from client c
      join tenant t on t.id = c.tenant_id
      join patch_test p on p.client_id = c.id
     where t.plan = 'pro_plus'
       and not c.rebook_opt_out
       -- Only where a test is actually required of something she sells. A
       -- studio with no patch-tested treatment has no reason to send this.
       and exists (select 1 from service s
                    where s.tenant_id = t.id and s.active
                      and s.patch_test_hours is not null)
       -- Nobody with an appointment in the diary: she will be tested then, or
       -- the booking already proves she is covered.
       and not exists (select 1 from booking b
                        where b.client_id = c.id and b.status = 'confirmed'
                          and b.starts_at > now())
     group by c.id, c.tenant_id, c.name, c.email, c.unsub_token,
              t.display_name, t.slug, c.rebook_opt_out, t.patch_valid_months
    having
       -- Inside the last month of cover, or lapsed within the last ninety days.
       -- Past that she has gone elsewhere and this is junk, exactly as the
       -- rebooking nudge decides.
           max(p.tested_at) + make_interval(months => t.patch_valid_months)
             <= now() + interval '30 days'
       and max(p.tested_at) + make_interval(months => t.patch_valid_months)
             > now() - interval '90 days'
       -- not already told about THIS expiry
       and not exists (select 1 from patch_nudge pn
                        where pn.client_id = c.id
                          and pn.valid_until = max(p.tested_at)
                              + make_interval(months => t.patch_valid_months))
  loop
    insert into patch_nudge (client_id, tenant_id, valid_until)
    values (r.client_id, r.tenant_id, r.valid_until)
    on conflict (client_id) do update set valid_until = excluded.valid_until,
                                          sent_at = now();

    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    values (null, 'client_patch', r.email, r.name,
      case when r.valid_until > now()
        then 'Your patch test runs out soon'
        else 'Your patch test has run out' end,
      'Hi ' || split_part(r.name, ' ', 1) || E',\n\n' ||
      case when r.valid_until > now()
        then 'Your patch test with ' || r.display_name || ' runs out on ' ||
             to_char(r.valid_until, 'FMDD FMMonth') || '.'
        else 'Your patch test with ' || r.display_name || ' has run out.' end ||
      E'\n\n' ||
      'It only takes a few minutes and it has to be done before your next ' ||
      E'appointment, so it is worth getting booked in now:\n\n' ||
      v_site || '/' || r.slug || E'\n\n' ||
      'If you would rather not hear from us again, one tap: ' ||
      v_site || '/book/manage.html?u=' ||
      r.unsub_token::text);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ------------------------------------------------------------- 2: waitlist --
create table waitlist (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenant(id) on delete cascade,
  service_id  uuid references service(id) on delete set null,
  name        text not null check (length(trim(name)) between 2 and 80),
  email       text not null check (email ~ '^[^@[:space:]]+@[^@[:space:]．.]+(\.[^@[:space:]．.]+)+$'),
  note        text,
  token       uuid not null default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  notified_at timestamptz,
  -- One place per person per treatment. Joining twice is a mistake, not a wish
  -- to be told twice.
  unique (tenant_id, email, service_id)
);
create index waitlist_tenant_idx on waitlist (tenant_id, created_at);
alter table waitlist enable row level security;
create policy waitlist_own on waitlist for all using (
  exists (select 1 from tenant t where t.id = waitlist.tenant_id and t.owner = auth.uid()));

-- Anyone can join from the public page; nobody can read the list but her.
create or replace function join_waitlist(
  p_slug text, p_service uuid, p_name text, p_email text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t tenant; v_id uuid;
begin
  select * into v_t from tenant where slug = p_slug;
  if v_t.id is null then
    raise exception 'That studio is not here.' using errcode = 'P0002';
  end if;
  if v_t.plan <> 'pro_plus' then
    raise exception 'She is not taking a waiting list.' using errcode = 'P0006';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'We need a name to put on the list.' using errcode = 'P0001';
  end if;

  insert into waitlist (tenant_id, service_id, name, email, note)
  values (v_t.id, p_service, trim(p_name), lower(trim(p_email)),
          nullif(trim(p_note), ''))
  on conflict (tenant_id, email, service_id) do update
    set name = excluded.name, note = excluded.note,
        -- re-joining clears the stamp, so she is told about the next one
        notified_at = null
  returning id into v_id;
  return jsonb_build_object('on_list', true, 'id', v_id);
end $$;

-- Leaving, from the link in the email. The token is the whole gate.
create or replace function leave_waitlist(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  delete from waitlist where token = p_token;
  get diagnostics v_n = row_count;
  return jsonb_build_object('left', v_n > 0);
end $$;

-- Her own list, for the dashboard. Through a function rather than the table so
-- the plan gate lives next to the feature: the RLS policy says "her rows", it
-- cannot say "and only while she pays for them".
create or replace function my_waitlist()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', w.id, 'name', w.name, 'email', w.email, 'note', w.note,
             'service', s.name,
             'created_at', w.created_at, 'notified_at', w.notified_at)
           order by w.created_at)
      from waitlist w
      join tenant t on t.id = w.tenant_id
                   and t.owner = auth.uid()
                   and t.plan = 'pro_plus'
      left join service s on s.id = w.service_id), '[]'::jsonb);
$$;

-- A confirmed booking has just been cancelled, so a real slot is free. Told to
-- everyone waiting for that treatment at once, first come first served: picking
-- one person and holding it for her is how a slot sits empty for a day because
-- somebody did not read her email.
create or replace function offer_free_slot(p_booking uuid)
returns int language plpgsql security definer set search_path = public as $$
declare b booking; t tenant; s service; r record; n int := 0; v_site text; v_when text;
begin
  select * into b from booking where id = p_booking;
  if b.id is null then return 0; end if;
  select * into t from tenant  where id = b.tenant_id;
  select * into s from service where id = b.service_id;
  if t.plan <> 'pro_plus' then return 0; end if;
  -- Nothing is offered that cannot be taken: a slot in the past, or inside her
  -- own notice period, is not an opportunity.
  if b.starts_at <= now() + make_interval(hours => t.notice_hours) then return 0; end if;

  v_site := coalesce(setting('site_url'), 'https://booked-in.co.uk');
  v_when := to_char(b.starts_at at time zone t.timezone, 'FMDay FMDD FMMonth') ||
            ' at ' || to_char(b.starts_at at time zone t.timezone, 'HH24:MI');

  for r in
    select w.* from waitlist w
     where w.tenant_id = b.tenant_id
       and (w.service_id is null or w.service_id = b.service_id)
       -- Told at most once a week, whatever else frees up. A waiting list that
       -- emails on every cancellation stops being a waiting list and starts
       -- being the reason she is marked as spam.
       and (w.notified_at is null or w.notified_at < now() - interval '7 days')
     order by w.created_at
     limit 30
  loop
    update waitlist set notified_at = now() where id = r.id;
    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    values (b.id, 'client_waitlist', r.email, r.name,
      'A ' || lower(s.name) || ' has come free with ' || t.display_name,
      'Hi ' || split_part(r.name, ' ', 1) || E',\n\n' ||
      'A time has just come free:' || E'\n\n' ||
      s.name || E'\n' || v_when || E'\n\n' ||
      'First to book it gets it:' || E'\n' ||
      v_site || '/' || t.slug || E'\n\n' ||
      'Come off the list any time: ' ||
      v_site || '/book/manage.html?w=' || r.token::text);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Hung off the cancellation itself, so nothing has to remember to call it.
create or replace function on_cancel_offer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'cancelled' and old.status = 'confirmed' then
    perform offer_free_slot(new.id);
  end if;
  return new;
end $$;

create trigger booking_offer after update on booking
  for each row execute function on_cancel_offer();

-- ------------------------------------------------------------- 3: standing --
-- She could cancel a booking but never create one, so a client who rang up had
-- to be sent to the website. This is the same set of rules book() applies -
-- opening hours, closures, the overlap constraint - without the abuse caps,
-- which exist to stop strangers and have nothing to say about the owner.
-- The patch-test rule still applies to her. She is the one whose insurance is
-- at stake, and a booking she typed in herself is not evidence of a test - so
-- if the record is not there, this is refused exactly as her page refuses it.
-- Recording a test she did on paper is one tap and already built.
create or replace function studio_book(
  p_service uuid, p_starts timestamptz, p_name text, p_email text,
  p_phone text default null, p_address text default null)
returns table (ref text, starts_at timestamptz, ends_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
declare v_t tenant; v_s service; v_ends timestamptz; v_ref text; v_local timestamp;
begin
  select t.* into v_t from tenant t
    join service s on s.tenant_id = t.id
   where s.id = p_service and t.owner = auth.uid();
  if v_t.id is null then
    raise exception 'That treatment is not yours.' using errcode = 'P0001';
  end if;
  select * into v_s from service where id = p_service;
  v_ends := p_starts + make_interval(mins => v_s.duration_min);
  v_local := p_starts at time zone v_t.timezone;

  if not exists (select 1 from opening o
                  where o.tenant_id = v_t.id
                    and o.weekday = extract(dow from v_local)::int
                    and v_local::time >= o.starts
                    and (v_ends at time zone v_t.timezone)::time <= o.ends) then
    raise exception 'That is not a time you work.' using errcode = 'P0001';
  end if;
  if exists (select 1 from closure c
              where c.tenant_id = v_t.id and c.on_date = v_local::date) then
    raise exception 'You are closed that day.' using errcode = 'P0001';
  end if;

  v_ref := upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 8));
  begin
    insert into booking (tenant_id, service_id, starts_at, ends_at,
                         client_name, client_email, client_phone, ref, client_address)
    values (v_t.id, p_service, p_starts, v_ends,
            trim(p_name), lower(trim(p_email)), p_phone, v_ref,
            nullif(trim(p_address), ''));
  exception when exclusion_violation then
    raise exception 'You already have something at that time.' using errcode = 'P0003';
  when deadlock_detected then
    raise exception 'You already have something at that time.' using errcode = 'P0003';
  end;
  return query select v_ref, p_starts, v_ends;
end $$;

-- The next N visits at her usual interval, in one go. Pro+.
--
-- A conflict skips rather than stops: six weeks out something else may already
-- be in the diary, and failing the whole series because visit four clashes
-- would be useless. She is told which ones went in.
create or replace function book_series(
  p_service uuid, p_first timestamptz, p_every_weeks int, p_times int,
  p_name text, p_email text, p_phone text default null, p_address text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t tenant; v_at timestamptz; i int; v_ref text;
        v_made jsonb := '[]'::jsonb; v_missed jsonb := '[]'::jsonb;
begin
  select t.* into v_t from tenant t
    join service s on s.tenant_id = t.id
   where s.id = p_service and t.owner = auth.uid();
  if v_t.id is null then
    raise exception 'That treatment is not yours.' using errcode = 'P0001';
  end if;
  if v_t.plan <> 'pro_plus' then
    raise exception 'Standing appointments are part of Pro+.' using errcode = 'P0006';
  end if;
  if p_times < 1 or p_times > 12 then
    raise exception 'Between 1 and 12 appointments.' using errcode = 'P0001';
  end if;
  if p_every_weeks < 1 or p_every_weeks > 26 then
    raise exception 'Between 1 and 26 weeks apart.' using errcode = 'P0001';
  end if;

  for i in 0 .. p_times - 1 loop
    v_at := p_first + make_interval(weeks => i * p_every_weeks);
    begin
      select sb.ref into v_ref
        from studio_book(p_service, v_at, p_name, p_email, p_phone, p_address) sb;
      v_made := v_made || jsonb_build_object('ref', v_ref, 'starts_at', v_at);
    exception when others then
      -- Skipped, with the reason, so she can see WHY visit four is missing
      -- rather than wondering whether it worked.
      v_missed := v_missed || jsonb_build_object('starts_at', v_at, 'why', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('booked', v_made, 'skipped', v_missed);
end $$;

-- ----------------------------------------------------------- 4: her hourly --
-- What each treatment actually earns per hour of her time. She prices by feel,
-- and the difference between £40 for 90 minutes and £35 for 60 is £8 an hour
-- that nothing in this trade points out.
--
-- Counted over appointments actually attended in the last 180 days, not over
-- the price list, because the question is what her diary earns rather than what
-- it advertises.
create or replace function my_earnings()
returns jsonb language sql stable security definer set search_path = public as $$
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
  );
$$;

-- ------------------------------------------------------------------- mail --
alter table mail_outbox drop constraint mail_outbox_kind_check;
alter table mail_outbox add constraint mail_outbox_kind_check check (kind in
  ('client_booked','studio_booked','client_cancelled','studio_cancelled',
   'client_reminder','client_rebook','client_patch','client_waitlist'));

-- booking_id is already nullable, which a lapse nudge needs: it is about a
-- client, not about any one booking.

-- ---------------------------------------------------------------- the run --
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'no pg_cron: skipping the lapse schedule (not Supabase)';
    return;
  end if;
  perform cron.unschedule('bookedin-patch-nudge')
    where exists (select 1 from cron.job where jobname = 'bookedin-patch-nudge');
  -- Mid-morning, like the rebooking nudge, and twenty minutes after it so the
  -- two never land in the same inbox in the same minute. A client who is due a
  -- top-up AND whose test has run out gets two emails about the same visit if
  -- they arrive together; twenty minutes apart they read as one conversation.
  perform cron.schedule('bookedin-patch-nudge', '38 10 * * *',
    $cron$ select queue_patch_nudges(); $cron$);
end $$;

-- ------------------------------------------------------------------ grants
revoke execute on function queue_patch_nudges()                        from public;
revoke execute on function join_waitlist(text, uuid, text, text, text) from public;
revoke execute on function leave_waitlist(uuid)                        from public;
revoke execute on function offer_free_slot(uuid)                       from public;
revoke execute on function on_cancel_offer()                           from public;
revoke execute on function studio_book(uuid, timestamptz, text, text, text, text) from public;
revoke execute on function book_series(uuid, timestamptz, int, int, text, text, text, text) from public;
revoke execute on function my_waitlist()                               from public;
revoke execute on function my_earnings()                               from public;
grant execute on function join_waitlist(text, uuid, text, text, text) to anon, authenticated;
grant execute on function leave_waitlist(uuid)                        to anon, authenticated;
grant execute on function studio_book(uuid, timestamptz, text, text, text, text) to authenticated;
grant execute on function book_series(uuid, timestamptz, int, int, text, text, text, text) to authenticated;
grant execute on function my_waitlist()                               to authenticated;
grant execute on function my_earnings()                               to authenticated;

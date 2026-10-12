-- Peony — Phase 1b: self-serve signup
--
-- The point of this file is that setting up a new studio costs us zero
-- minutes. She signs up, claims a link, edits the treatments we guessed for
-- her trade, and her page is live. Nobody hand-edits a file.

-- --------------------------------------------------------------- columns --
alter table tenant add column trade text not null default 'other'
  check (trade in ('lashes','nails','brows','hair','other'));
alter table tenant add column slot_step_min int not null default 15
  check (slot_step_min between 5 and 120);
alter table tenant add column updated_at timestamptz not null default now();

-- one studio per account for now; lifting this later is additive
create unique index tenant_one_per_owner on tenant (owner);

-- --------------------------------------------------------------- reserved --
-- without this somebody claims "app" or "book" and takes out the routing
create table reserved_slug (slug text primary key);
insert into reserved_slug (slug) values
  ('app'),('book'),('www'),('api'),('admin'),('help'),('support'),('status'),
  ('peony'),('about'),('pricing'),('blog'),('legal'),('privacy'),('terms'),
  ('login'),('signup'),('signin'),('account'),('billing'),('dashboard'),
  ('mail'),('email'),('static'),('assets'),('cdn'),('img'),('new'),('me');

-- Readable by anyone, because the signup form has to be able to tell her the
-- name is gone before she has an account.
alter table reserved_slug enable row level security;
create policy reserved_read on reserved_slug for select using (true);

create or replace function slug_available(p_slug text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'
     and not exists (select 1 from reserved_slug r where r.slug = p_slug)
     and not exists (select 1 from tenant t where t.slug = p_slug);
$$;

-- ------------------------------------------------------------ the studio --
-- Everything a new studio needs, in one transaction: if the services fail to
-- seed she does not end up owning a half-built page.
create or replace function create_studio(
  p_slug  text,
  p_name  text,
  p_trade text default 'other',
  p_tz    text default 'Europe/London'
) returns text
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Sign in first.' using errcode = 'P0001';
  end if;
  if exists (select 1 from tenant where owner = v_uid) then
    raise exception 'You already have a page.' using errcode = 'P0001';
  end if;
  if not slug_available(p_slug) then
    raise exception 'That link is taken.' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Your studio needs a name.' using errcode = 'P0001';
  end if;

  insert into tenant (owner, slug, display_name, trade, timezone)
  values (v_uid, p_slug, trim(p_name), p_trade, p_tz)
  returning id into v_id;

  -- a trade's usual treatments and prices, as a starting point she edits.
  -- A form she has to fill from nothing is where signups are lost.
  insert into service (tenant_id, name, price_pence, duration_min, sort)
  select v_id, s.name, s.pence, s.mins, s.sort from (values
    ('lashes','Classic full set',  4500, 120, 1),
    ('lashes','Hybrid full set',   5000, 120, 2),
    ('lashes','Russian full set',  5500, 150, 3),
    ('lashes','Hybrid infills',    3500,  90, 4),
    ('lashes','Russian infills',   4000,  90, 5),
    ('nails', 'BIAB full set',     3500,  90, 1),
    ('nails', 'Gel manicure',      2500,  60, 2),
    ('nails', 'Infills',           3000,  75, 3),
    ('nails', 'Soak off & removal',1000,  30, 4),
    ('brows', 'Brow lamination',   3500,  60, 1),
    ('brows', 'Brow wax & tint',   2000,  30, 2),
    ('brows', 'HD brows',          3000,  45, 3),
    ('hair',  'Cut & blow dry',    3500,  60, 1),
    ('hair',  'Root tint',         4500,  90, 2),
    ('hair',  'Full head highlights', 9000, 180, 3)
  ) as s(trade, name, pence, mins, sort)
  where s.trade = p_trade;

  -- Tuesday to Saturday, which is what most of them actually work
  insert into opening (tenant_id, weekday, starts, ends)
  select v_id, d, '09:00'::time, '18:00'::time from unnest(array[2,3,4,5,6]) d;

  return p_slug;
end $$;

-- ------------------------------------------------------- the public read --
-- One round trip for everything her page needs to render.
create or replace function get_studio(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'timezone', t.timezone, 'plan', t.plan,
    'notice_hours', t.notice_hours,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name,
               'price_pence', s.price_pence, 'duration_min', s.duration_min)
             order by s.sort, s.name)
        from service s where s.tenant_id = t.id and s.active), '[]'::jsonb),
    'openings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'weekday', o.weekday, 'area', o.area,
               'starts', o.starts, 'ends', o.ends) order by o.weekday)
        from opening o where o.tenant_id = t.id), '[]'::jsonb)
  )
  from tenant t where t.slug = p_slug;
$$;

-- Which start times are actually bookable. This runs in the database on
-- purpose: working it out in the browser would mean sending every booking to
-- every visitor, and her clients' names are not public information.
create or replace function free_slots(
  p_slug text, p_service uuid, p_from date, p_to date
) returns setof timestamptz
language sql stable security definer set search_path = public as $$
  with t as (
    select id, timezone, notice_hours, slot_step_min
      from tenant where slug = p_slug
  ),
  s as (
    select sv.duration_min
      from service sv join t on sv.tenant_id = t.id
     where sv.id = p_service and sv.active
  ),
  day as (
    select g::date as on_date
      from generate_series(p_from, least(p_to, p_from + 92), interval '1 day') g
  ),
  cand as (
    select ((day.on_date + o.starts) at time zone t.timezone)
           + make_interval(mins => step.n) as at
      from t
      cross join s
      cross join day
      join opening o
        on o.tenant_id = t.id
       and o.weekday = extract(dow from day.on_date)::int
      cross join lateral generate_series(
        0,
        (extract(epoch from (o.ends - o.starts)) / 60)::int - s.duration_min,
        t.slot_step_min
      ) as step(n)
     where not exists (
       select 1 from closure c where c.tenant_id = t.id and c.on_date = day.on_date)
       -- a treatment longer than the window fits nowhere in it. Clamping the
       -- series to 0 instead would offer the opening time and then refuse it.
       and (extract(epoch from (o.ends - o.starts)) / 60)::int >= s.duration_min
  )
  select cand.at from cand, t, s
   where cand.at >= now() + make_interval(hours => t.notice_hours)
     and not exists (
       select 1 from booking b
        where b.tenant_id = t.id
          and b.status = 'confirmed'
          and tstzrange(b.starts_at, b.ends_at, '[)')
           && tstzrange(cand.at, cand.at + make_interval(mins => s.duration_min), '[)')
     )
   order by 1;
$$;

-- -------------------------------------------------------------- her side --
create or replace function my_studio()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'plan', t.plan, 'timezone', t.timezone,
    'notice_hours', t.notice_hours, 'slot_step_min', t.slot_step_min,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'price_pence', s.price_pence,
               'duration_min', s.duration_min, 'active', s.active, 'sort', s.sort)
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

grant execute on function slug_available(text)                         to anon, authenticated;
grant execute on function get_studio(text)                             to anon, authenticated;
grant execute on function free_slots(text, uuid, date, date)           to anon, authenticated;
grant execute on function create_studio(text, text, text, text)        to authenticated;
grant execute on function my_studio()                                  to authenticated;

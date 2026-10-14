-- Booked In — the patch test, enforced rather than hoped for
--
-- This is the one thing in here that is not a convenience.
--
-- Tinting and lash extensions need a patch test 24 to 48 hours beforehand -
-- the exact window is the insurer's, and they differ. A signed disclaimer does
-- not replace it, and a test done at a different salon does not count. If a
-- client reacts and the studio cannot produce a dated record, the insurance
-- that was supposed to cover it may not, and a reaction claim is the kind that
-- ends a one-person business.
--
-- Every booking platform treats this as her problem. They sell appointments;
-- the compliance that has to sit around the appointment is left in a notebook,
-- or in her head, or nowhere. So the one thing a stranger can do on her page -
-- book herself in - is also the one thing that can quietly void her insurance,
-- and she finds out afterwards.
--
-- Here the database refuses. A treatment that needs a test cannot be booked by
-- somebody who has not had one in time, the refusal says what to do instead,
-- and the record is dated, kept and hers.
--
-- It is deliberately not a setting with a sensible default. She turns it on
-- per treatment, because she is the one insured and we are not going to guess
-- her policy's wording for her.

-- --------------------------------------------------------------- the rules
-- Null means this treatment needs no test. Otherwise it is how many hours
-- BEFORE the appointment a valid test must already have happened.
alter table service add column patch_test_hours int
  check (patch_test_hours is null or patch_test_hours between 1 and 168);

-- How long one lasts before it has to be done again. Insurers differ - three
-- months and six months are both common - so it is hers to set.
alter table tenant add column patch_valid_months int not null default 6
  check (patch_valid_months between 1 and 24);

-- A treatment that IS the patch test. Booking one and keeping it records the
-- test, so the client books a test and then books the set, and neither of them
-- has to remember to write anything down.
alter table service add column records_patch_test boolean not null default false;

-- Sensible starting points, by trade first and then by name. Trade first
-- because the seeded treatments are called "Classic full set" and "Hybrid
-- infills" - names that say nothing about lashes to a LIKE pattern while
-- being exactly the work that needs a test. A nail technician is asked for
-- nothing: she does not patch test a BIAB infill and should not be prompted
-- to, and a prompt she has to dismiss is how a safety feature gets ignored.
create or replace function guess_patch_hours(p_trade text, p_name text)
returns int language sql immutable set search_path = public as $$
  select case
    -- nothing is applied, so nothing can react
    when p_name ilike '%removal%' or p_name ilike '%soak off%'
      or p_name ilike '%patch%'                                  then null
    -- the whole of lashes and brows: adhesive, tint and lifting solution
    when p_trade in ('lashes', 'brows')                           then 48
    -- and tinting anywhere else
    when p_name ilike '%tint%'  or p_name ilike '%lamination%'
      or p_name ilike '%perm%'                                    then 48
    else null
  end;
$$;

-- The same guess for every treatment made from now on. Without this the
-- backfill below would be the whole feature and it would reach nobody who
-- signs up tomorrow: create_studio() seeds its treatments after this file has
-- run. INSERT only, so setting it back to null to turn the requirement off
-- stays off.
create or replace function suggest_patch_hours()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.patch_test_hours is null and not new.records_patch_test then
    new.patch_test_hours := guess_patch_hours(
      (select t.trade from tenant t where t.id = new.tenant_id), new.name);
  end if;
  return new;
end $$;

create trigger service_patch_default
  before insert on service
  for each row execute function suggest_patch_hours();

update service s set patch_test_hours = case
    -- nothing is applied, so nothing can react
    when s.name ilike '%removal%' or s.name ilike '%soak off%'
      or s.name ilike '%patch%'                                  then null
    -- the whole of lashes and brows: adhesive, tint and lifting solution
    when t.trade in ('lashes', 'brows')                          then 48
    -- and tinting anywhere else
    when s.name ilike '%tint%'  or s.name ilike '%lamination%'
      or s.name ilike '%perm%'                                   then 48
    else null
  end
 from tenant t
 where t.id = s.tenant_id;

-- ------------------------------------------------------------ the records
create table patch_test (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenant(id) on delete cascade,
  client_id  uuid not null references client(id) on delete cascade,
  tested_at  timestamptz not null default now(),
  -- Which booking recorded it, when it came from one. Kept so she can show
  -- the appointment as well as the date if she is ever asked to.
  booking_id uuid references booking(id) on delete set null,
  note       text,
  created_at timestamptz not null default now()
);
create index patch_client_idx on patch_test (client_id, tested_at desc);

alter table patch_test enable row level security;
create policy patch_own on patch_test for all
  using     (exists (select 1 from tenant t where t.id = patch_test.tenant_id and t.owner = auth.uid()))
  with check(exists (select 1 from tenant t where t.id = patch_test.tenant_id and t.owner = auth.uid()));

-- ------------------------------------------------------------- the refusal
-- A trigger rather than a change to book(). book() has been rewritten twice
-- and each rewrite is a chance to drop one of the checks in front of it; this
-- fires on any path that inserts a booking. The name matters: triggers at the
-- same timing run in alphabetical order, and booking_client has to set
-- client_id before this can look the client up.
create or replace function require_patch_test()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_hours int; v_months int; v_last timestamptz; v_name text;
begin
  select s.patch_test_hours, s.name into v_hours, v_name
    from service s where s.id = new.service_id;
  if v_hours is null then return new; end if;
  if new.client_id is null then return new; end if;   -- nothing to check against

  select t.patch_valid_months into v_months from tenant t where t.id = new.tenant_id;

  select max(p.tested_at) into v_last
    from patch_test p
   where p.client_id = new.client_id
     -- done early enough to count for THIS appointment
     and p.tested_at <= new.starts_at - make_interval(hours => v_hours)
     -- and not so long ago that it has lapsed
     and p.tested_at >= new.starts_at - make_interval(months => v_months);

  if v_last is null then
    raise exception
      '% needs a patch test at least % hours beforehand, and we do not have one on record for you. Book a patch test first and then come back for this.',
      v_name, v_hours
      using errcode = 'P0005';
  end if;
  return new;
end $$;

create trigger booking_patch_test
  before insert on booking
  for each row execute function require_patch_test();

-- A kept patch-test appointment IS the record. Written when the booking is
-- made rather than when the appointment happens, because the alternative is
-- her having to come back and tick something off, which nobody does.
create or replace function record_patch_test()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.client_id is null then return new; end if;
  if not exists (select 1 from service s
                  where s.id = new.service_id and s.records_patch_test) then
    return new;
  end if;
  insert into patch_test (tenant_id, client_id, tested_at, booking_id, note)
  values (new.tenant_id, new.client_id, new.starts_at, new.id,
          'Recorded from a patch test appointment');
  return new;
end $$;

create trigger booking_records_patch
  after insert on booking
  for each row execute function record_patch_test();

-- ------------------------------------------------------- what the pages read
-- Public: her booking page has to say "this needs a patch test" BEFORE a
-- client picks a time, not after she has typed her name in and been refused.
-- Keyed on the email she gives, and it answers about that email only.
create or replace function patch_status(p_slug text, p_email text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tenant uuid; v_months int; v_last timestamptz; v_client uuid;
begin
  select t.id, t.patch_valid_months into v_tenant, v_months
    from tenant t where t.slug = p_slug;
  if v_tenant is null then return null; end if;

  select c.id into v_client from client c
   where c.tenant_id = v_tenant and c.email = lower(trim(p_email));
  if v_client is not null then
    select max(p.tested_at) into v_last from patch_test p
     where p.client_id = v_client
       and p.tested_at >= now() - make_interval(months => v_months);
  end if;

  return jsonb_build_object(
    'tested_at', v_last,
    'valid_until', case when v_last is null then null
                   else v_last + make_interval(months => v_months) end);
end $$;

-- Hers: who is covered, who has lapsed, and when.
create or replace function my_patch_tests()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.client_id, jsonb_build_object(
           'tested_at', x.tested_at,
           'valid_until', x.tested_at + make_interval(months => x.months))), '{}'::jsonb)
    from (
      select p.client_id, max(p.tested_at) as tested_at, max(t.patch_valid_months) as months
        from patch_test p
        join tenant t on t.id = p.tenant_id and t.owner = auth.uid()
       group by p.client_id
    ) x;
$$;

create or replace function add_patch_test(p_client uuid, p_at timestamptz default null,
                                          p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_months int;
begin
  select c.tenant_id into v_tenant from client c
    join tenant t on t.id = c.tenant_id and t.owner = auth.uid()
   where c.id = p_client;
  if v_tenant is null then
    raise exception 'That client is not yours.' using errcode = 'P0002';
  end if;
  select t.patch_valid_months into v_months from tenant t where t.id = v_tenant;
  insert into patch_test (tenant_id, client_id, tested_at, note)
  values (v_tenant, p_client, coalesce(p_at, now()), nullif(trim(p_note), ''));
  return jsonb_build_object('tested_at', coalesce(p_at, now()),
    'valid_until', coalesce(p_at, now()) + make_interval(months => v_months));
end $$;

-- get_studio must say which treatments need one, and how long they last
create or replace function get_studio(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'timezone', t.timezone, 'plan', t.plan,
    'notice_hours', t.notice_hours, 'cancel_hours', t.cancel_hours,
    'brand_hex', t.brand_hex, 'logo_path', t.logo_path,
    'patch_valid_months', t.patch_valid_months,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'photo_path', s.photo_path,
               'price_pence', s.price_pence, 'duration_min', s.duration_min,
               'patch_test_hours', s.patch_test_hours,
               'records_patch_test', s.records_patch_test)
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

create or replace function my_studio()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'plan', t.plan, 'timezone', t.timezone,
    'notice_hours', t.notice_hours, 'slot_step_min', t.slot_step_min,
    'cancel_hours', t.cancel_hours, 'remind_hours', t.remind_hours,
    'rebook_on', t.rebook_on, 'rebook_lead_days', t.rebook_lead_days,
    'brand_hex', t.brand_hex, 'logo_path', t.logo_path,
    'card_theme', t.card_theme, 'card_align', t.card_align,
    'patch_valid_months', t.patch_valid_months,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'price_pence', s.price_pence,
               'duration_min', s.duration_min, 'active', s.active, 'sort', s.sort,
               'photo_path', s.photo_path, 'rebook_weeks', s.rebook_weeks,
               'patch_test_hours', s.patch_test_hours,
               'records_patch_test', s.records_patch_test)
             order by s.sort, s.name)
        from service s where s.tenant_id = t.id), '[]'::jsonb),
    'openings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'weekday', o.weekday, 'area', o.area,
               'starts', o.starts, 'ends', o.ends) order by o.weekday, o.starts)
        from opening o where o.tenant_id = t.id), '[]'::jsonb),
    'closures', coalesce((
      select jsonb_agg(jsonb_build_object('on_date', c.on_date, 'reason', c.reason)
             order by c.on_date)
        from closure c where c.tenant_id = t.id and c.on_date >= current_date), '[]'::jsonb),
    'bookings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'ref', b.ref, 'starts_at', b.starts_at,
               'ends_at', b.ends_at, 'client_name', b.client_name,
               'client_email', b.client_email, 'client_phone', b.client_phone,
               'client_id', b.client_id,
               'status', b.status, 'service', sv.name, 'price_pence', sv.price_pence)
             order by b.starts_at)
        from booking b join service sv on sv.id = b.service_id
       where b.tenant_id = t.id and b.starts_at > now() - interval '30 days'), '[]'::jsonb)
  )
  from tenant t where t.owner = auth.uid();
$$;

-- ------------------------------------------------------------------- grants
revoke execute on function guess_patch_hours(text, text)            from public;
revoke execute on function suggest_patch_hours()                    from public;
revoke execute on function require_patch_test()                     from public;
revoke execute on function record_patch_test()                      from public;
revoke execute on function patch_status(text, text)                 from public;
revoke execute on function my_patch_tests()                         from public;
revoke execute on function add_patch_test(uuid, timestamptz, text)  from public;
revoke execute on function my_studio()                              from public;
revoke execute on function get_studio(text)                         from public;

grant execute on function patch_status(text, text)                to anon, authenticated;
grant execute on function my_patch_tests()                        to authenticated;
grant execute on function add_patch_test(uuid, timestamptz, text) to authenticated;
grant execute on function my_studio()                             to authenticated;
grant execute on function get_studio(text)                        to anon, authenticated;

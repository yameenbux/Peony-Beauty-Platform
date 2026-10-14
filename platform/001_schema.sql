-- Booked In — Phase 1 schema (Postgres / Supabase)
--
-- The whole point of this file is the exclusion constraint on `booking`.
-- Everything else is bookkeeping.
--
-- Today the booking page cannot lock a slot: two people on two devices can
-- both take 09:00, and both get a confirmation. Checking "is it free?" in
-- application code does not fix that — it only narrows the window between the
-- check and the insert. The database has to refuse the second write itself.

create extension if not exists btree_gist;   -- lets one constraint mix = and &&
create extension if not exists pgcrypto;     -- gen_random_uuid, gen_random_bytes

-- ---------------------------------------------------------------- tenants --
create table tenant (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null references auth.users(id) on delete cascade,
  -- this becomes <slug>.booked-in.co.uk, so it is the one thing we cannot let change
  -- freely or collide
  slug          text not null unique
                check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'),
  display_name  text not null,
  tagline       text,
  plan          text not null default 'free' check (plan in ('free','pro')),
  timezone      text not null default 'Europe/London',
  notice_hours  int  not null default 24 check (notice_hours between 0 and 720),
  created_at    timestamptz not null default now()
);

create table service (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenant(id) on delete cascade,
  name         text not null,
  -- money in pence: a float here is how you end up charging someone £44.99999
  price_pence  int  not null check (price_pence >= 0),
  duration_min int  not null check (duration_min between 5 and 600),
  sort         int  not null default 0,
  active       boolean not null default true
);
create index service_tenant_idx on service (tenant_id) where active;

-- which weekday she covers which area, and between what hours. This is the
-- travel-day model: a client in Coventry cannot book a Birmingham day.
create table opening (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  weekday   int  not null check (weekday between 0 and 6),   -- 0 = Sunday
  area      text not null default '',
  starts    time not null,
  ends      time not null,
  check (ends > starts)
);
create index opening_tenant_idx on opening (tenant_id, weekday);

create table closure (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenant(id) on delete cascade,
  on_date   date not null,
  reason    text,
  unique (tenant_id, on_date)
);

-- --------------------------------------------------------------- bookings --
create table booking (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenant(id) on delete cascade,
  service_id   uuid not null references service(id) on delete restrict,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  client_name  text not null,
  client_email text not null,
  client_phone text,
  status       text not null default 'confirmed'
               check (status in ('confirmed','cancelled')),
  ref          text not null unique,
  created_at   timestamptz not null default now(),
  check (ends_at > starts_at)
);

-- THE IMPORTANT LINE.
-- No two confirmed bookings for one tenant may cover overlapping time. It is
-- a range overlap, not an equality test, because a 90-minute full set booked
-- at 09:00 has to block 10:00 as well. Two concurrent transactions cannot both
-- satisfy this: the second to commit raises 23P01 and rolls back. Cancelled
-- rows are excluded by the WHERE, so a cancellation frees the slot.
alter table booking add constraint booking_no_overlap
  exclude using gist (
    tenant_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status = 'confirmed');

-- the client side needs to know which times are gone, but not who took them
create view slot_taken with (security_invoker = false) as
  select tenant_id, starts_at, ends_at from booking where status = 'confirmed';

-- ------------------------------------------------------------- the write --
-- Public booking goes through this and only this. It is SECURITY DEFINER so a
-- signed-out visitor can create a booking without being able to write to, or
-- read, the booking table.
create or replace function book(
  p_slug    text,
  p_service uuid,
  p_starts  timestamptz,
  p_name    text,
  p_email   text,
  p_phone   text default null
) returns table (ref text, starts_at timestamptz, ends_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid; v_tz text; v_notice int; v_dur int;
  v_ends timestamptz; v_ref text; v_local timestamp;
begin
  select t.id, t.timezone, t.notice_hours into v_tenant, v_tz, v_notice
    from tenant t where t.slug = p_slug;
  if v_tenant is null then
    raise exception 'That page does not exist.' using errcode = 'P0002';
  end if;

  select s.duration_min into v_dur from service s
    where s.id = p_service and s.tenant_id = v_tenant and s.active;
  if v_dur is null then
    raise exception 'That treatment is not available.' using errcode = 'P0002';
  end if;

  v_ends  := p_starts + make_interval(mins => v_dur);
  v_local := p_starts at time zone v_tz;

  if p_starts < now() + make_interval(hours => v_notice) then
    raise exception 'That is too soon to book.' using errcode = 'P0001';
  end if;

  if not exists (
    select 1 from opening o
     where o.tenant_id = v_tenant
       and o.weekday = extract(dow from v_local)::int
       and v_local::time >= o.starts
       and (v_ends at time zone v_tz)::time <= o.ends
  ) then
    raise exception 'That is not a time she works.' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from closure c
     where c.tenant_id = v_tenant and c.on_date = v_local::date
  ) then
    raise exception 'She is closed that day.' using errcode = 'P0001';
  end if;

  v_ref := upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 8));

  begin
    insert into booking (tenant_id, service_id, starts_at, ends_at,
                         client_name, client_email, client_phone, ref)
    values (v_tenant, p_service, p_starts, v_ends,
            p_name, p_email, p_phone, v_ref);
  exception when exclusion_violation then
    -- somebody else committed an overlapping booking between this request
    -- arriving and this insert. This is the race, caught where it is real.
    raise exception 'Someone just took that time.' using errcode = 'P0003';
  when deadlock_detected then
    -- The same race, one step earlier, and the reason this is not paranoia:
    -- an exclusion constraint checks its index AFTER writing the row, so two
    -- requests for one slot can each write, then each wait for the other, and
    -- Postgres breaks the cycle by killing one. The survivor gets the slot, so
    -- the victim has lost exactly the race above and is told exactly that.
    -- Without this she is shown the words "deadlock detected", which are true
    -- and useless. Reproduced by 50 simultaneous attempts on one time.
    raise exception 'Someone just took that time.' using errcode = 'P0003';
  end;

  return query select v_ref, p_starts, v_ends;
end $$;

-- ------------------------------------------------------------------- RLS --
alter table tenant  enable row level security;
alter table service enable row level security;
alter table opening enable row level security;
alter table closure enable row level security;
alter table booking enable row level security;

-- the shop front is public: anyone can read what is on offer and when
create policy tenant_read  on tenant  for select using (true);
create policy service_read on service for select using (active);
create policy opening_read on opening for select using (true);
create policy closure_read on closure for select using (true);

-- she manages her own, and nothing else
create policy tenant_own on tenant for all
  using (owner = auth.uid()) with check (owner = auth.uid());

create policy service_own on service for all
  using     (exists (select 1 from tenant t where t.id = service.tenant_id and t.owner = auth.uid()))
  with check(exists (select 1 from tenant t where t.id = service.tenant_id and t.owner = auth.uid()));

create policy opening_own on opening for all
  using     (exists (select 1 from tenant t where t.id = opening.tenant_id and t.owner = auth.uid()))
  with check(exists (select 1 from tenant t where t.id = opening.tenant_id and t.owner = auth.uid()));

create policy closure_own on closure for all
  using     (exists (select 1 from tenant t where t.id = closure.tenant_id and t.owner = auth.uid()))
  with check(exists (select 1 from tenant t where t.id = closure.tenant_id and t.owner = auth.uid()));

-- client details are readable only by the person they booked with. There is
-- deliberately no public insert policy: booking goes through book() or not at all.
create policy booking_own on booking for select
  using (exists (select 1 from tenant t where t.id = booking.tenant_id and t.owner = auth.uid()));
create policy booking_cancel on booking for update
  using     (exists (select 1 from tenant t where t.id = booking.tenant_id and t.owner = auth.uid()))
  with check(exists (select 1 from tenant t where t.id = booking.tenant_id and t.owner = auth.uid()));

grant select on slot_taken to anon, authenticated;
grant execute on function book(text, uuid, timestamptz, text, text, text) to anon, authenticated;

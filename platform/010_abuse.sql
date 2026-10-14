-- Booked In — stop a stranger filling someone's diary
--
-- book() is a public RPC. Anyone who can open a studio's page can call it, and
-- until now there was nothing to stop a script calling it a thousand times:
-- every slot for the next month taken by "asdf" with a junk email, the studio's
-- real clients locked out, and a confirmation email fired at whatever address
-- the script felt like naming. Costing nothing to run, that is the kind of
-- vandalism a bored person does to a stranger for fun.
--
-- Three defences, in order of how much they are worth.
--
--   1. The caps below, which are the only ones that matter. They are counted
--      from the booking table itself rather than from a log of attempts, which
--      makes them survive a rollback: a call that raises leaves no booking, so
--      it consumes no allowance, and a call that succeeds is counted forever
--      whatever happens afterwards in the transaction. A log would be wiped by
--      the very rollback it was meant to record.
--
--   2. A format check on the email, so the address at least could exist.
--
--   3. A honeypot field, which costs nothing and catches the dumb half of the
--      traffic before any of the above has to run.
--
-- What is deliberately NOT here: a CAPTCHA. Every one of them is a third-party
-- script on a page a client reaches while already slightly unsure whether this
-- is a real business, and the caps make a flood pointless anyway.

-- -------------------------------------------------------------- who called
-- A salted hash of the caller's address, never the address. It is enough to
-- count against, cannot be read back into an IP without the salt, and is wiped
-- once it is too old to be counted (prune_ip_keys below).
alter table booking add column ip_key text;

-- One salt, generated here, known only to the database. gen_random_bytes is
-- already relied on for booking references, and sha256() is a Postgres builtin,
-- so neither of these needs an extension that Supabase puts in another schema.
insert into platform_setting (key, value)
values ('ip_salt', encode(gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

-- setting() only ever returns the three harmless keys, so this one stays
-- unreadable from a browser even though it sits in the same table.

-- The windows below all look back an hour or ask for upcoming bookings, so
-- every count is served by one of these.
create index booking_recent_idx   on booking (created_at desc);
create index booking_email_idx    on booking (lower(client_email), created_at desc);
create index booking_ip_idx       on booking (ip_key, created_at desc) where ip_key is not null;

-- ------------------------------------------------------------- the limits
-- Numbers chosen so that a real client never meets one and a script meets one
-- almost immediately. The busiest single-chair studio in the country does not
-- take twenty bookings in an hour, and nobody books themselves in six times in
-- an hour by accident.
create table booking_limit (
  id                smallint primary key default 1 check (id = 1),
  per_email_hour    int not null default 5,   -- bookings from one address, any studio
  per_ip_hour       int not null default 10,  -- from one connection, any studio
  per_tenant_hour   int not null default 20,  -- into one diary, from anyone
  open_per_email    int not null default 3    -- upcoming, unfinished, one studio
);
insert into booking_limit (id) values (1);

alter table booking_limit enable row level security;  -- service_role only: no policy

-- --------------------------------------------------------------- the rules
-- Split out of book() so the tests can exercise them directly and so book()
-- stays readable. SECURITY DEFINER because it reads the salt.
create or replace function booking_ip_key()
returns text language plpgsql stable security definer set search_path = public as $$
declare v_ip text; v_salt text;
begin
  -- PostgREST puts the request headers here. On a bare Postgres - the test
  -- harness, psql, a migration - there is no request and this is null, so the
  -- per-connection cap simply does not apply. That is the right failure
  -- direction: it never blocks a real booking because of a missing header.
  begin
    v_ip := split_part(
              coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for',
                       current_setting('request.headers', true)::json ->> 'cf-connecting-ip',
                       ''),
              ',', 1);
  exception when others then
    v_ip := '';            -- malformed header: treat as absent, never as an error
  end;
  v_ip := nullif(trim(v_ip), '');
  if v_ip is null then return null; end if;

  select value into v_salt from platform_setting where key = 'ip_salt';
  if v_salt is null then return null; end if;

  return encode(sha256(convert_to(v_ip || v_salt, 'UTF8')), 'hex');
end $$;

create or replace function check_booking_limits(
  p_tenant uuid, p_email text, p_ip_key text
) returns void language plpgsql security definer set search_path = public as $$
declare lim booking_limit; n int; v_email text := lower(trim(p_email));
begin
  select * into lim from booking_limit where id = 1;
  if lim is null then return; end if;   -- no row, no limits: fail open, not shut

  select count(*) into n from booking
   where lower(client_email) = v_email and created_at > now() - interval '1 hour';
  if n >= lim.per_email_hour then
    raise exception 'That is a lot of bookings from one email address in one hour. Try again later, or message the studio directly.'
      using errcode = 'P0004';
  end if;

  select count(*) into n from booking
   where tenant_id = p_tenant
     and lower(client_email) = v_email
     and status = 'confirmed'
     and starts_at > now();
  if n >= lim.open_per_email then
    raise exception 'You already have % appointments booked here. Cancel one before booking another.'
      , lim.open_per_email using errcode = 'P0004';
  end if;

  select count(*) into n from booking
   where tenant_id = p_tenant and created_at > now() - interval '1 hour';
  if n >= lim.per_tenant_hour then
    raise exception 'This page is unusually busy right now. Please try again in a little while.'
      using errcode = 'P0004';
  end if;

  if p_ip_key is not null then
    select count(*) into n from booking
     where ip_key = p_ip_key and created_at > now() - interval '1 hour';
    if n >= lim.per_ip_hour then
      raise exception 'That is a lot of bookings from one connection in one hour. Try again later.'
        using errcode = 'P0004';
    end if;
  end if;
end $$;

-- ------------------------------------------------------------------ book()
-- Same function, with the three defences in front of the insert and the hash
-- recorded on the row. The old six-argument version is dropped rather than
-- left as an overload: a forgotten unguarded copy of exactly this function is
-- the whole problem being fixed.
drop function if exists book(text, uuid, timestamptz, text, text, text);

create or replace function book(
  p_slug    text,
  p_service uuid,
  p_starts  timestamptz,
  p_name    text,
  p_email   text,
  p_phone   text default null,
  p_trap    text default null
) returns table (ref text, token uuid, starts_at timestamptz, ends_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid; v_tz text; v_notice int; v_dur int;
  v_ends timestamptz; v_ref text; v_token uuid; v_local timestamp;
  v_email text; v_ip text;
begin
  -- The honeypot, first because it is free. The field it comes from is in the
  -- form but not on the screen, so a person cannot fill it in and a script
  -- that fills every field it finds will.
  if coalesce(trim(p_trap), '') <> '' then
    raise exception 'We could not take that booking.' using errcode = 'P0004';
  end if;

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

  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_email), '') = '' then
    raise exception 'We need a name and an email.' using errcode = 'P0001';
  end if;

  -- Deliberately loose. The job is to catch "asdf" and a missing domain, not
  -- to adjudicate RFC 5322 - every strict email regex ever written rejects
  -- somebody's real address, and the confirmation email is the real test.
  v_email := lower(trim(p_email));
  if v_email !~ '^[^@[:space:]]+@[^@[:space:].]+(\.[^@[:space:].]+)+$' then
    raise exception 'That email address does not look right.' using errcode = 'P0001';
  end if;
  if length(trim(p_name)) < 2 then
    raise exception 'Please give the name the appointment is for.' using errcode = 'P0001';
  end if;

  v_ip := booking_ip_key();
  perform check_booking_limits(v_tenant, v_email, v_ip);

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
                         client_name, client_email, client_phone, ref, ip_key)
    values (v_tenant, p_service, p_starts, v_ends,
            trim(p_name), v_email, nullif(trim(p_phone), ''), v_ref, v_ip);
    select b.cancel_token into v_token from booking b where b.ref = v_ref;
  exception when exclusion_violation then
    raise exception 'Someone just took that time.' using errcode = 'P0003';
  -- An exclusion constraint checks its index after writing the row, so two
  -- requests for one slot can each write and then each wait for the other.
  -- Postgres breaks the cycle by killing one; the survivor keeps the slot, so
  -- the victim has lost precisely the race above. See 001_schema.sql.
  when deadlock_detected then
    raise exception 'Someone just took that time.' using errcode = 'P0003';
  end;

  return query select v_ref, v_token, p_starts, v_ends;
end $$;

-- ------------------------------------------------------------ forgetting
-- The hash is only ever counted over the last hour, so keeping it for a week
-- is already generous and keeping it forever would be collecting something we
-- have no use for. Schedule alongside the jobs in 006:
--   select cron.schedule('bookedin-prune-ip', '40 3 * * *', $$select prune_ip_keys()$$);
create or replace function prune_ip_keys()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with done as (
    update booking set ip_key = null
     where ip_key is not null and created_at < now() - interval '7 days'
    returning 1)
  select count(*) into n from done;
  return n;
end $$;

-- ------------------------------------------------------------------ grants
-- 009 revoked EXECUTE from PUBLIC across the schema, but these functions are
-- new and so were created with the default grant to PUBLIC all over again.
revoke execute on function booking_ip_key()                    from public;
revoke execute on function check_booking_limits(uuid, text, text) from public;
revoke execute on function prune_ip_keys()                     from public;
revoke execute on function book(text, uuid, timestamptz, text, text, text, text) from public;

-- book() is the only one of them a browser may call. The helpers run inside
-- it as definer and have no business being reachable on their own: one of them
-- reads the salt and the other would let a caller probe how close someone is
-- to a limit.
grant execute on function book(text, uuid, timestamptz, text, text, text, text)
  to anon, authenticated;

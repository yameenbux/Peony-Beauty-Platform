-- Booked In — for the ones who do not travel
--
-- Everything so far quietly assumed a mobile technician: openings carry an
-- "area", the copy talks about turning up, and nothing anywhere holds an
-- address. That is one half of the trade. The other half works from a room at
-- home, a chair rented in a salon, or a shop - and for her the single most
-- asked question is not "when are you free", it is "where are you and where do
-- I park".
--
-- Three shapes, and the page changes for each:
--
--   salon   she has an address. Clients come to her. The page shows where,
--           the confirmation says it again, and the calendar file carries it
--           so the appointment has a location on her client's phone.
--   mobile  she travels. The booking has to collect the client's address, or
--           she is driving to a town rather than a door.
--   both    the client chooses when she books, and only then is an address
--           asked for.
--
-- Defaulting to 'salon' rather than 'mobile', because a room at home is the
-- commoner of the two and a setting that is wrong for most people is a setting
-- most people have to find and change.

alter table tenant add column venue_kind text not null default 'salon'
  check (venue_kind in ('salon', 'mobile', 'both'));

-- Free text on purpose. "Flat 2, 14 Mill Road" and "the white door beside the
-- chippy" are both correct answers and no address form holds the second.
alter table tenant add column address text;
-- The part nobody puts in an address field and everybody needs: parking, the
-- buzzer number, which bell, the dog.
alter table tenant add column address_note text;

-- Her clients' addresses live on the client, so a regular does not retype it
-- every visit, and on the booking, so a move does not rewrite her history.
alter table client  add column address text;
alter table booking add column client_address text;

-- The existing studio travels; everything new starts at a premises.
update tenant set venue_kind = 'mobile'
 where exists (select 1 from opening o
                where o.tenant_id = tenant.id and nullif(trim(o.area), '') is not null);

-- -------------------------------------------------------------------- book()
-- The address has to arrive with the booking - it comes from the client and
-- there is nowhere else to get it - so this is the one change that cannot be a
-- trigger. Everything else is 010's function, unchanged.
drop function if exists book(text, uuid, timestamptz, text, text, text, text);

create or replace function book(
  p_slug    text,
  p_service uuid,
  p_starts  timestamptz,
  p_name    text,
  p_email   text,
  p_phone   text default null,
  p_trap    text default null,
  p_address text default null
) returns table (ref text, token uuid, starts_at timestamptz, ends_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tenant uuid; v_tz text; v_notice int; v_dur int;
  v_ends timestamptz; v_ref text; v_token uuid; v_local timestamp;
  v_email text; v_ip text; v_venue text; v_addr text;
begin
  -- The honeypot, first because it is free. The field it comes from is in the
  -- form but not on the screen, so a person cannot fill it in and a script
  -- that fills every field it finds will.
  if coalesce(trim(p_trap), '') <> '' then
    raise exception 'We could not take that booking.' using errcode = 'P0004';
  end if;

  select t.id, t.timezone, t.notice_hours, t.venue_kind
    into v_tenant, v_tz, v_notice, v_venue
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

  -- She is driving to this, so it has to be somewhere she can find. A length
  -- alone does not do it: "Coventry" is eight characters and is a forty minute
  -- search for a door. A digit is the honest test, because a house number or a
  -- postcode is what makes an address findable and a UK address without either
  -- is rare enough that being asked again is the right outcome.
  v_addr := nullif(trim(p_address), '');
  if v_venue = 'mobile'
     and (v_addr is null or length(v_addr) < 10 or v_addr !~ '[0-9]') then
    raise exception 'We need the full address she should come to, including the number and postcode.'
      using errcode = 'P0001';
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
                         client_name, client_email, client_phone, ref, ip_key,
                         client_address)
    values (v_tenant, p_service, p_starts, v_ends,
            trim(p_name), v_email, nullif(trim(p_phone), ''), v_ref, v_ip,
            v_addr);
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

-- An address given once is remembered, the same way a phone number is. Runs
-- after booking_client, which is what creates the row to update.
create or replace function keep_client_address()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.client_id is not null and nullif(trim(new.client_address), '') is not null then
    update client set address = new.client_address, updated_at = now()
     where id = new.client_id;
  end if;
  return new;
end $$;

create trigger booking_client_address
  after insert on booking
  for each row execute function keep_client_address();

-- Her client list, with the address she gave last time. Already stored by
-- keep_client_address(); this is what makes it visible to the one person
-- entitled to see it.
create or replace function my_clients()
returns jsonb language sql stable security definer set search_path = public as $$
  with agg as (
    select c.id, c.name, c.email, c.phone, c.notes, c.address, c.created_at,
           count(b.id)       filter (where b.status = 'confirmed' and b.starts_at < now()) as visits,
           coalesce(sum(s.price_pence)
                             filter (where b.status = 'confirmed' and b.starts_at < now()), 0) as spent_pence,
           min(b.starts_at)  filter (where b.status = 'confirmed' and b.starts_at < now()) as first_visit,
           max(b.starts_at)  filter (where b.status = 'confirmed' and b.starts_at < now()) as last_visit,
           min(b.starts_at)  filter (where b.status = 'confirmed' and b.starts_at > now()) as next_visit,
           count(b.id)       filter (where b.status = 'cancelled') as cancelled
      from client c
      join tenant t on t.id = c.tenant_id and t.owner = auth.uid()
      left join booking b on b.client_id = c.id
      left join service s on s.id = b.service_id
     group by c.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'name', name, 'email', email, 'phone', phone, 'notes', notes,
           'address', address,
           'visits', visits, 'spent_pence', spent_pence, 'cancelled', cancelled,
           'first_visit', first_visit, 'last_visit', last_visit, 'next_visit', next_visit,
           'since', created_at)
         -- whoever she saw most recently, first: that is who she is thinking about
         order by last_visit desc nulls last, name), '[]'::jsonb)
    from agg;
$$;

-- ------------------------------------------------------------------- email
-- The confirmation is the thing she reads on the morning, so it is the thing
-- that has to say where. Two directions, and they are not symmetrical: the
-- client needs the studio's address when she is travelling to it, and the
-- studio needs the client's when the travelling is hers. Her own address is
-- only ever put in a mail going to the one client who is coming to it - never
-- in the studio's own copy, which she already knows, and never on any page.
create or replace function queue_mail_for(p_booking uuid, p_cancelled boolean)
returns int language plpgsql security definer set search_path = public as $$
declare
  b booking; s service; t tenant;
  v_when text; v_site text; v_manage text; v_owner_email text; n int := 0;
  v_client_at text := '';   -- said to the client: where to go
  v_studio_at text := '';   -- said to the studio: where to drive
begin
  select * into b from booking where id = p_booking;
  if b.id is null then return 0; end if;
  select * into s from service where id = b.service_id;
  select * into t from tenant  where id = b.tenant_id;

  v_site := coalesce(setting('site_url'), 'https://booked-in.co.uk');
  v_when := to_char(b.starts_at at time zone t.timezone, 'FMDay FMDD FMMonth') ||
            ' at ' || to_char(b.starts_at at time zone t.timezone, 'HH24:MI');
  v_manage := v_site || '/book/manage.html?r=' || b.ref || '&t=' || b.cancel_token::text;

  select u.email into v_owner_email from auth.users u where u.id = t.owner;

  -- An address on the booking means the studio is travelling, whatever the
  -- tenant's shape says: that is the booking the client actually made.
  if nullif(trim(b.client_address), '') is not null then
    v_client_at := E'\n' || t.display_name || ' is coming to you at ' ||
                   b.client_address || E'.\n';
    v_studio_at := E'\n' || b.client_address || E'\n';
    if nullif(trim(t.address_note), '') is not null then
      v_client_at := v_client_at || t.address_note || E'\n';
    end if;
  elsif nullif(trim(t.address), '') is not null then
    v_client_at := E'\nWhere:\n' || t.address || E'\n';
    if nullif(trim(t.address_note), '') is not null then
      v_client_at := v_client_at || t.address_note || E'\n';
    end if;
  end if;

  if not p_cancelled then
    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    values (b.id, 'client_booked', b.client_email, b.client_name,
      'Your appointment with ' || t.display_name || ' is booked',
      'Hi ' || split_part(b.client_name, ' ', 1) || E',\n\n' ||
      'You are booked in with ' || t.display_name || E'.\n\n' ||
      s.name || E'\n' || v_when || E'\n' ||
      '£' || trim(to_char(s.price_pence / 100.0, 'FM999990.00')) || E'\n' ||
      'Reference ' || b.ref || E'\n' ||
      v_client_at || E'\n' ||
      'Need to change it? ' || v_manage || E'\n\n' ||
      'See you then.');
    n := n + 1;

    if v_owner_email is not null then
      insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
      values (b.id, 'studio_booked', v_owner_email, t.display_name,
        'New booking: ' || b.client_name || ', ' || v_when,
        b.client_name || ' has booked ' || s.name || E'.\n\n' ||
        v_when || E'\n' ||
        '£' || trim(to_char(s.price_pence / 100.0, 'FM999990.00')) || E'\n' ||
        b.client_email || coalesce(E'\n' || b.client_phone, '') || E'\n' ||
        v_studio_at ||
        'Reference ' || b.ref || E'\n\n' ||
        'Your diary: ' || v_site || '/app/');
      n := n + 1;
    end if;
  else
    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    values (b.id, 'client_cancelled', b.client_email, b.client_name,
      'Your appointment with ' || t.display_name || ' is cancelled',
      'Hi ' || split_part(b.client_name, ' ', 1) || E',\n\n' ||
      'Your ' || s.name || ' on ' || v_when || ' is cancelled.' ||
      case when b.cancelled_by = 'studio'
        then ' ' || t.display_name || ' cancelled it, so do get in touch to rearrange.'
        else '' end || E'\n\n' ||
      'Book another any time: ' || v_site || '/book/?s=' || t.slug);
    n := n + 1;

    if v_owner_email is not null then
      insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
      values (b.id, 'studio_cancelled', v_owner_email, t.display_name,
        'Cancelled: ' || b.client_name || ', ' || v_when,
        b.client_name || ' is no longer coming for ' || s.name || E'.\n\n' ||
        v_when || E'\n' ||
        case when b.cancelled_by = 'client'
          then 'She cancelled it herself, and the time is back on sale.'
          else 'You cancelled this one.' end || E'\n\n' ||
        'Your diary: ' || v_site || '/app/');
      n := n + 1;
    end if;
  end if;
  return n;
end $$;

-- The reminder the night before is the one email that gets read standing up,
-- and "where" is the only thing in it she might not already know.
create or replace function queue_reminders()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    select b.id, b.starts_at
      from booking b
      join tenant t on t.id = b.tenant_id
     where b.status = 'confirmed'
       and b.reminded_at is null
       and t.plan = 'pro'
       and b.starts_at > now()
       and b.starts_at <= now() + make_interval(hours => t.remind_hours)
     for update of b skip locked
  loop
    update booking set reminded_at = now() where id = r.id;
    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    select r.id, 'client_reminder', b.client_email, b.client_name,
      'Tomorrow: your appointment with ' || t.display_name,
      'Hi ' || split_part(b.client_name, ' ', 1) || E',\n\n' ||
      'Just a reminder that you are booked in with ' || t.display_name || E'.\n\n' ||
      s.name || E'\n' ||
      to_char(b.starts_at at time zone t.timezone, 'FMDay FMDD FMMonth') || ' at ' ||
      to_char(b.starts_at at time zone t.timezone, 'HH24:MI') || E'\n' ||
      case
        when nullif(trim(b.client_address), '') is not null
          then E'\n' || t.display_name || ' is coming to you at ' ||
               b.client_address || E'.\n' ||
               coalesce(trim(t.address_note) || E'\n', '')
        when nullif(trim(t.address), '') is not null
          then E'\nWhere:\n' || t.address || E'\n' ||
               coalesce(trim(t.address_note) || E'\n', '')
        else ''
      end || E'\n' ||
      'Cannot make it? Let her know here: ' ||
      coalesce(setting('site_url'), 'https://booked-in.co.uk') ||
      '/book/manage.html?r=' || b.ref || '&t=' || b.cancel_token::text
      from booking b
      join service s on s.id = b.service_id
      join tenant  t on t.id = b.tenant_id
     where b.id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ------------------------------------------------------- what the pages read
create or replace function get_studio(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'timezone', t.timezone, 'plan', t.plan,
    'notice_hours', t.notice_hours, 'cancel_hours', t.cancel_hours,
    'brand_hex', t.brand_hex, 'logo_path', t.logo_path,
    'patch_valid_months', t.patch_valid_months,
    'venue_kind', t.venue_kind, 'address', t.address, 'address_note', t.address_note,
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

-- Her own read of her studio. Two additions: the venue settings, so the
-- dashboard can show her what she chose, and client_address on every booking -
-- without which a mobile studio's diary tells her she has a 10am and declines
-- to say where, which is the one thing she needs from it at 9:40.
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
    'venue_kind', t.venue_kind, 'address', t.address, 'address_note', t.address_note,
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
               'client_id', b.client_id, 'client_address', b.client_address,
               'status', b.status, 'service', sv.name, 'price_pence', sv.price_pence)
             order by b.starts_at)
        from booking b join service sv on sv.id = b.service_id
       where b.tenant_id = t.id and b.starts_at > now() - interval '30 days'), '[]'::jsonb)
  )
  from tenant t where t.owner = auth.uid();
$$;

revoke execute on function book(text, uuid, timestamptz, text, text, text, text, text) from public;
revoke execute on function keep_client_address()  from public;
revoke execute on function get_studio(text)       from public;
revoke execute on function my_studio()            from public;
revoke execute on function my_clients()           from public;
grant execute on function my_clients() to authenticated;
revoke execute on function queue_mail_for(uuid, boolean) from public;
revoke execute on function queue_reminders()      from public;
grant execute on function my_studio() to authenticated;
grant execute on function book(text, uuid, timestamptz, text, text, text, text, text)
  to anon, authenticated;
grant execute on function get_studio(text) to anon, authenticated;

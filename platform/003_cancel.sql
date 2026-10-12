-- Booked In — cancelling, and blocking out days
--
-- Until now a booking could be made and never unmade. She had no way to clear
-- a cancellation out of her diary, and a client who could not come had no way
-- to say so except a message — which is the admin this is supposed to remove.

-- How close to the appointment a client may still cancel themselves. Inside
-- that window it becomes a conversation, which is what she actually wants: a
-- no-show an hour before is not the same as a change of mind on Tuesday.
alter table tenant add column cancel_hours int not null default 24
  check (cancel_hours between 0 and 336);

-- The client's proof that this booking is theirs. It is not a secret worth
-- much, but it is unguessable, and it never appears on a public page.
alter table booking add column cancel_token uuid not null default gen_random_uuid();
alter table booking add column cancelled_at timestamptz;
alter table booking add column cancelled_by text
  check (cancelled_by in ('client','studio'));

create index booking_ref_idx on booking (ref);

-- book() has to hand the token back now, so the return type changes
drop function if exists book(text, uuid, timestamptz, text, text, text);

create or replace function book(
  p_slug    text,
  p_service uuid,
  p_starts  timestamptz,
  p_name    text,
  p_email   text,
  p_phone   text default null
) returns table (ref text, token uuid, starts_at timestamptz, ends_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid; v_tz text; v_notice int; v_dur int;
  v_ends timestamptz; v_ref text; v_token uuid; v_local timestamp;
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

  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_email), '') = '' then
    raise exception 'We need a name and an email.' using errcode = 'P0001';
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
            trim(p_name), lower(trim(p_email)), nullif(trim(p_phone), ''), v_ref)
    returning booking.cancel_token into v_token;
  exception when exclusion_violation then
    raise exception 'Someone just took that time.' using errcode = 'P0003';
  end;

  return query select v_ref, v_token, p_starts, v_ends;
end $$;

-- What the client sees on their "manage this booking" link. Keyed on the token
-- so a guessed reference alone shows nothing.
create or replace function get_booking(p_ref text, p_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ref', b.ref, 'starts_at', b.starts_at, 'ends_at', b.ends_at,
    'status', b.status, 'client_name', b.client_name,
    'service', s.name, 'price_pence', s.price_pence,
    'studio', t.display_name, 'slug', t.slug, 'timezone', t.timezone,
    'cancel_hours', t.cancel_hours,
    'can_cancel', (b.status = 'confirmed'
                   and b.starts_at > now() + make_interval(hours => t.cancel_hours))
  )
  from booking b
  join service s on s.id = b.service_id
  join tenant  t on t.id = b.tenant_id
  where b.ref = p_ref and b.cancel_token = p_token;
$$;

create or replace function cancel_booking(p_ref text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v booking; v_hours int; v_name text;
begin
  select b.* into v from booking b where b.ref = p_ref and b.cancel_token = p_token;
  if v.id is null then
    raise exception 'We cannot find that booking.' using errcode = 'P0002';
  end if;
  if v.status = 'cancelled' then
    raise exception 'That booking is already cancelled.' using errcode = 'P0001';
  end if;

  select t.cancel_hours, t.display_name into v_hours, v_name
    from tenant t where t.id = v.tenant_id;

  if v.starts_at <= now() + make_interval(hours => v_hours) then
    raise exception
      'It is too close to your appointment to cancel here. Please message % directly.', v_name
      using errcode = 'P0001';
  end if;

  update booking set status = 'cancelled', cancelled_at = now(), cancelled_by = 'client'
   where id = v.id;

  -- the slot is free again the moment this commits: the overlap constraint
  -- only looks at confirmed rows
  return jsonb_build_object('ref', v.ref, 'cancelled', true);
end $$;

-- Her side. The update policy already lets her write her own bookings; this
-- just stamps the row consistently so the diary can tell the two apart.
create or replace function studio_cancel(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  select t.owner into v_owner
    from booking b join tenant t on t.id = b.tenant_id where b.id = p_id;
  if v_owner is null or v_owner <> auth.uid() then
    raise exception 'That is not your booking.' using errcode = 'P0002';
  end if;
  -- reporting success for a booking that was already cancelled would let the
  -- diary show a cancellation as hers when the client made it
  if not exists (select 1 from booking where id = p_id and status = 'confirmed') then
    raise exception 'That booking is already cancelled.' using errcode = 'P0001';
  end if;
  update booking set status = 'cancelled', cancelled_at = now(), cancelled_by = 'studio'
   where id = p_id and status = 'confirmed';
  return jsonb_build_object('cancelled', true);
end $$;

-- Blocking out a day. The closure table existed from the start but nothing
-- could write to it, so a holiday meant unticking a weekday for everyone.
create or replace function set_closure(p_date date, p_on boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select id into v_tenant from tenant where owner = auth.uid();
  if v_tenant is null then
    raise exception 'Sign in first.' using errcode = 'P0001';
  end if;
  if p_on then
    insert into closure (tenant_id, on_date, reason) values (v_tenant, p_date, p_reason)
    on conflict (tenant_id, on_date) do update set reason = excluded.reason;
  else
    delete from closure where tenant_id = v_tenant and on_date = p_date;
  end if;
  return jsonb_build_object('date', p_date, 'closed', p_on);
end $$;

-- my_studio() gains the booking id's cancel state and her closures
create or replace function my_studio()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'plan', t.plan, 'timezone', t.timezone,
    'notice_hours', t.notice_hours, 'slot_step_min', t.slot_step_min,
    'cancel_hours', t.cancel_hours,
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
    'closures', coalesce((
      select jsonb_agg(jsonb_build_object('on_date', c.on_date, 'reason', c.reason)
             order by c.on_date)
        from closure c where c.tenant_id = t.id and c.on_date >= current_date), '[]'::jsonb),
    'bookings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'ref', b.ref, 'starts_at', b.starts_at,
               'ends_at', b.ends_at, 'client_name', b.client_name,
               'client_email', b.client_email, 'client_phone', b.client_phone,
               'status', b.status, 'cancelled_by', b.cancelled_by,
               'service', sv.name, 'price_pence', sv.price_pence)
             order by b.starts_at)
        from booking b join service sv on sv.id = b.service_id
       where b.tenant_id = t.id and b.starts_at > now() - interval '30 days'), '[]'::jsonb)
  )
  from tenant t where t.owner = auth.uid();
$$;

grant execute on function book(text, uuid, timestamptz, text, text, text) to anon, authenticated;
grant execute on function get_booking(text, uuid)      to anon, authenticated;
grant execute on function cancel_booking(text, uuid)   to anon, authenticated;
grant execute on function studio_cancel(uuid)          to authenticated;
grant execute on function set_closure(date, boolean, text) to authenticated;

-- Booked In — the client, as something more than a name on a booking
--
-- Until now a client existed only as three columns copied onto every booking:
-- name, email, phone, repeated in full each time she came. So nothing could
-- answer the question a studio actually asks - "how long since I saw Ruby, and
-- is she due?" - and nothing could be built on top of it. This is the table
-- every revenue feature needs first.
--
-- ONE DELIBERATE CONSTRAINT, worth stating plainly because it costs us
-- something: a client belongs to ONE studio. The same woman booking with two
-- studios is two rows that know nothing of each other.
--
-- A single global client identity would be more elegant and it is what every
-- marketplace does, because a client list that spans studios is the asset you
-- sell: it is what lets you say "people who booked lashes near you also
-- booked...". We have promised never to be that, and the surest way to keep a
-- promise is to make it structurally impossible to break. It also keeps the
-- law simple - each studio is the controller of her own clients and we are her
-- processor, which is exactly what the privacy notice already says. A shared
-- row would quietly make us the controller of everyone.

create table client (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenant(id) on delete cascade,
  -- Lowercased on the way in. It is the only thing a client reliably gives the
  -- same way twice - names get shortened, phones get typed with and without
  -- the leading zero - so it is what identifies her within one studio.
  email      text not null,
  name       text not null,
  phone      text,
  -- Her notes, not ours: patch test dates, allergies, "likes them shorter at
  -- the inner corner". Free text because the alternative is a form that never
  -- fits what she actually needs to remember.
  notes      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, email)
);
create index client_tenant_idx on client (tenant_id, name);

alter table booking add column client_id uuid references client(id) on delete set null;
-- "her bookings, newest first" is the only way this is ever read
create index booking_client_idx on booking (client_id, starts_at desc);

-- ------------------------------------------------------------- the backfill
-- Every booking already taken becomes a client. The most recent spelling of a
-- name wins, because that is the one she gave last; the most recent phone
-- number that exists wins, because a later booking without a phone is a client
-- who did not bother, not a client who lost her phone.
insert into client (tenant_id, email, name, phone, created_at)
select b.tenant_id,
       lower(trim(b.client_email)),
       (array_agg(b.client_name  order by b.created_at desc))[1],
       (array_agg(b.client_phone order by b.created_at desc)
          filter (where nullif(trim(b.client_phone), '') is not null))[1],
       min(b.created_at)
  from booking b
 where nullif(trim(b.client_email), '') is not null
 group by b.tenant_id, lower(trim(b.client_email))
on conflict (tenant_id, email) do nothing;

update booking b
   set client_id = c.id
  from client c
 where c.tenant_id = b.tenant_id
   and c.email = lower(trim(b.client_email))
   and b.client_id is null;

-- ------------------------------------------------------------ keeping it so
create or replace function upsert_client(
  p_tenant uuid, p_email text, p_name text, p_phone text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into client (tenant_id, email, name, phone)
  values (p_tenant, lower(trim(p_email)), trim(p_name), nullif(trim(p_phone), ''))
  on conflict (tenant_id, email) do update
     set name  = excluded.name,
         -- coalesce, not excluded.phone: booking again without typing a phone
         -- number must not delete the one she gave last time
         phone = coalesce(excluded.phone, client.phone),
         updated_at = now()
  returning id into v_id;
  return v_id;
end $$;

-- A trigger rather than a change to book(). book() has been rewritten twice
-- already and every rewrite is a chance to drop one of the checks in front of
-- it; this way the linking happens on ANY path that inserts a booking,
-- including ones not written yet, and book() is left alone.
create or replace function link_booking_client()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.client_id is null and nullif(trim(new.client_email), '') is not null then
    new.client_id := upsert_client(new.tenant_id, new.client_email,
                                   new.client_name, new.client_phone);
  end if;
  return new;
end $$;

create trigger booking_client
  before insert on booking
  for each row execute function link_booking_client();

-- ---------------------------------------------------------------------- RLS
alter table client enable row level security;

-- Her clients, and nobody else's. There is deliberately no public read policy:
-- a booking page must never be able to ask who else has booked.
create policy client_own on client for all
  using     (exists (select 1 from tenant t where t.id = client.tenant_id and t.owner = auth.uid()))
  with check(exists (select 1 from tenant t where t.id = client.tenant_id and t.owner = auth.uid()));

-- -------------------------------------------------------------- the reading
-- Counted on the way out rather than kept in columns on the row. A stored
-- "visits" total is a number that silently goes wrong the first time a booking
-- is cancelled or deleted, and this table will never be big enough for the
-- difference to matter: a busy solo studio sees a few hundred clients a year.
create or replace function my_clients()
returns jsonb language sql stable security definer set search_path = public as $$
  with agg as (
    select c.id, c.name, c.email, c.phone, c.notes, c.created_at,
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
           'visits', visits, 'spent_pence', spent_pence, 'cancelled', cancelled,
           'first_visit', first_visit, 'last_visit', last_visit, 'next_visit', next_visit,
           'since', created_at)
         -- whoever she saw most recently, first: that is who she is thinking about
         order by last_visit desc nulls last, name), '[]'::jsonb)
    from agg;
$$;

create or replace function set_client_notes(p_client uuid, p_notes text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update client c
     set notes = nullif(trim(p_notes), ''), updated_at = now()
   where c.id = p_client
     and exists (select 1 from tenant t where t.id = c.tenant_id and t.owner = auth.uid());
  if not found then
    raise exception 'That client is not yours.' using errcode = 'P0002';
  end if;
end $$;

-- ------------------------------------------------------------------- grants
-- 009 revoked EXECUTE from PUBLIC across the schema, but these are new and so
-- were created with the default grant to PUBLIC all over again.
revoke execute on function upsert_client(uuid, text, text, text) from public;
revoke execute on function link_booking_client()                 from public;
revoke execute on function my_clients()                          from public;
revoke execute on function set_client_notes(uuid, text)          from public;

grant execute on function my_clients()                  to authenticated;
grant execute on function set_client_notes(uuid, text)  to authenticated;
-- upsert_client runs inside the trigger as definer. Reachable on its own it
-- would let any signed-in person write a row into any studio's client list.

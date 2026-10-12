-- Booked In — the confirmations both pages already promise
--
-- The booking page tells a client "we have emailed you a copy" and the diary
-- tells her bookings "arrive in your inbox". Until this file, neither was true.
--
-- Mail is queued into an outbox rather than posted from the trigger. A booking
-- must never fail because an email provider is having a bad afternoon, and a
-- confirmation must not be lost because one HTTP call timed out. The trigger
-- writes a row; something else drains it and can retry.

create table platform_setting (
  key   text primary key,
  value text not null
);
insert into platform_setting (key, value) values
  ('site_url', 'https://booked-in.co.uk'),
  ('from_name', 'Booked In')
on conflict (key) do nothing;

alter table platform_setting enable row level security;
-- nothing public needs to read this; the drainer runs as service_role

create table mail_outbox (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid references booking(id) on delete cascade,
  kind       text not null check (kind in
               ('client_booked','studio_booked','client_cancelled','studio_cancelled')),
  to_email   text not null,
  to_name    text,
  subject    text not null,
  body       text not null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  attempts   int not null default 0,
  last_error text
);
create index mail_pending_idx on mail_outbox (created_at) where sent_at is null;

alter table mail_outbox enable row level security;
-- no policy at all: only service_role, which bypasses RLS, may touch this.
-- Client details sit in here, so nothing in a browser should ever read it.

create or replace function setting(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from platform_setting where key = p_key;
$$;

-- Composed here rather than in the edge function so the wording is covered by
-- the same tests as everything else. The function that sends it only wraps
-- this text in a branded shell.
create or replace function queue_mail_for(p_booking uuid, p_cancelled boolean)
returns int language plpgsql security definer set search_path = public as $$
declare
  b booking; s service; t tenant; o uuid;
  v_when text; v_site text; v_manage text; v_owner_email text; n int := 0;
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

  if not p_cancelled then
    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    values (b.id, 'client_booked', b.client_email, b.client_name,
      'Your appointment with ' || t.display_name || ' is booked',
      'Hi ' || split_part(b.client_name, ' ', 1) || E',\n\n' ||
      'You are booked in with ' || t.display_name || E'.\n\n' ||
      s.name || E'\n' || v_when || E'\n' ||
      '£' || trim(to_char(s.price_pence / 100.0, 'FM999990.00')) || E'\n' ||
      'Reference ' || b.ref || E'\n\n' ||
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

create or replace function on_booking_mail()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform queue_mail_for(new.id, false);
  elsif tg_op = 'UPDATE'
    and new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    perform queue_mail_for(new.id, true);
  end if;
  return new;
end $$;

-- AFTER, so a booking that is about to be rolled back by the overlap
-- constraint never queues a confirmation for a slot it did not get
create trigger booking_mail
  after insert or update of status on booking
  for each row execute function on_booking_mail();

-- What the sender drains. service_role only.
create or replace function next_mail(p_limit int default 20)
returns setof mail_outbox language sql volatile security definer set search_path = public as $$
  update mail_outbox m set attempts = m.attempts + 1
   where m.id in (
     select id from mail_outbox
      where sent_at is null and attempts < 5
      order by created_at
      limit p_limit
      for update skip locked          -- two drainers must not send the same mail twice
   )
  returning m.*;
$$;

create or replace function mail_sent(p_id uuid, p_error text default null)
returns void language sql volatile security definer set search_path = public as $$
  update mail_outbox
     set sent_at = case when p_error is null then now() else null end,
         last_error = p_error
   where id = p_id;
$$;

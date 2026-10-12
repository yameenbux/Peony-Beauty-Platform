-- Peony — the reminder the day before
--
-- This is the first thing Pro actually buys that the free tier does not, and
-- it is on the pricing card, so it had better exist. It is also the cheapest
-- no-show prevention there is.

alter table booking add column reminded_at timestamptz;

-- How far ahead to warn. Null means she has not chosen, so use the default.
alter table tenant add column remind_hours int not null default 24
  check (remind_hours between 1 and 168);

-- Pro only. The free tier gets the booking confirmation and nothing else,
-- which is the honest difference between the two.
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
       -- inside the window, and not already past: a reminder for an
       -- appointment that has started is worse than none
       and b.starts_at > now()
       and b.starts_at <= now() + make_interval(hours => t.remind_hours)
     for update of b skip locked
  loop
    -- stamped first, so two runs overlapping cannot both send it
    update booking set reminded_at = now() where id = r.id;
    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    select r.id, 'client_reminder', b.client_email, b.client_name,
      'Tomorrow: your appointment with ' || t.display_name,
      'Hi ' || split_part(b.client_name, ' ', 1) || E',\n\n' ||
      'Just a reminder that you are booked in with ' || t.display_name || E'.\n\n' ||
      s.name || E'\n' ||
      to_char(b.starts_at at time zone t.timezone, 'FMDay FMDD FMMonth') || ' at ' ||
      to_char(b.starts_at at time zone t.timezone, 'HH24:MI') || E'\n\n' ||
      'Cannot make it? Let her know here: ' ||
      coalesce(setting('site_url'), 'https://peony.uk') ||
      '/book/manage.html?r=' || b.ref || '&t=' || b.cancel_token::text
      from booking b
      join service s on s.id = b.service_id
      join tenant  t on t.id = b.tenant_id
     where b.id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- the outbox check constraint has to allow the new kind
alter table mail_outbox drop constraint mail_outbox_kind_check;
alter table mail_outbox add constraint mail_outbox_kind_check check (kind in
  ('client_booked','studio_booked','client_cancelled','studio_cancelled','client_reminder'));

-- a cancelled booking must not go on to be reminded about
create or replace function on_booking_mail()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform queue_mail_for(new.id, false);
  elsif tg_op = 'UPDATE'
    and new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    perform queue_mail_for(new.id, true);
    update booking set reminded_at = coalesce(reminded_at, now()) where id = new.id;
  end if;
  return new;
end $$;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'no pg_cron: skipping the reminder schedule (not Supabase)';
    return;
  end if;
  perform cron.unschedule('peony-reminders')
    where exists (select 1 from cron.job where jobname = 'peony-reminders');
  -- every fifteen minutes is close enough for a day-before reminder and keeps
  -- the query off the hour, where everything else is
  perform cron.schedule('peony-reminders', '7,22,37,52 * * * *',
    $cron$ select queue_reminders(); $cron$);
end $$;

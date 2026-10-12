-- Booked In — run the sender every minute
--
-- Supabase only. Guarded, so a bare Postgres (which is what the tests use)
-- skips it rather than failing.
--
-- !! THIS REPOSITORY IS PUBLIC. DO NOT PASTE A KEY INTO THIS FILE. !!
--
-- This is the template. To use it:
--     cp 006_cron.sql 006_cron.local.sql
-- then fill the two placeholders in the copy and run that. *.local.sql is
-- gitignored, so the filled-in version cannot be committed by accident.
-- Running it straight in the Supabase SQL editor and never saving it is
-- equally fine.
--
-- Before this works, set the two settings below to your project's values:
--   select set_config('app.functions_url','https://<ref>.functions.supabase.co',false);
-- or simply edit the insert.

insert into platform_setting (key, value) values
  ('functions_url', 'https://CHANGE-ME.functions.supabase.co')
on conflict (key) do nothing;

-- The service_role key is deliberately NOT stored in platform_setting: that
-- table has a SECURITY DEFINER reader, and a secret one function can read is a
-- secret. Paste it into the schedule below instead, where it lives in
-- cron.job, which only the postgres role can read.

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'no pg_cron: skipping the schedule (not Supabase)';
    return;
  end if;
  create extension if not exists pg_cron;
  create extension if not exists pg_net;

  perform cron.unschedule('bookedin-send-mail')
    where exists (select 1 from cron.job where jobname = 'bookedin-send-mail');

  perform cron.schedule('bookedin-send-mail', '* * * * *', $cron$
    select net.http_post(
      url     := (select value from platform_setting where key = 'functions_url') || '/send-mail',
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   -- replace in your .local.sql copy, never here
                   'Authorization', 'Bearer PASTE_SERVICE_ROLE_KEY_HERE'),
      body    := '{}'::jsonb
    );
  $cron$);
end $$;

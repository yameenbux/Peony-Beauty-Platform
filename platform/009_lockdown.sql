-- Booked In — close three holes the billing tests found
--
-- 1. Postgres grants EXECUTE on a new function to PUBLIC by default. Every
--    SECURITY DEFINER function written so far was therefore callable by an
--    anonymous visitor. Most check auth.uid() and fail safely, but three did
--    not: next_mail() hands back the outbox, which holds client names and
--    email addresses; setting() returns any row of platform_setting, which
--    006 uses to store a service_role key; and set_plan() would let anybody
--    put any studio on Pro.
--
-- 2. The tenant_own policy is FOR ALL on the whole row, and RLS cannot
--    restrict columns, so a studio could set its own plan to 'pro' with an
--    ordinary update.
--
-- 3. The service_role key should not sit in a table any function can read.

-- ---------------------------------------------------------------- 1: grants
-- Default-deny, then hand back only what each caller genuinely needs.
revoke execute on all functions in schema public from public;

-- the public booking page, signed out
grant execute on function get_studio(text)                       to anon, authenticated;
grant execute on function free_slots(text, uuid, date, date)     to anon, authenticated;
grant execute on function book(text, uuid, timestamptz, text, text, text) to anon, authenticated;
grant execute on function get_booking(text, uuid)                to anon, authenticated;
grant execute on function cancel_booking(text, uuid)             to anon, authenticated;
grant execute on function slug_available(text)                   to anon, authenticated;

-- her, signed in
grant execute on function create_studio(text, text, text, text)  to authenticated;
grant execute on function my_studio()                            to authenticated;
grant execute on function studio_cancel(uuid)                    to authenticated;
grant execute on function set_closure(date, boolean, text)       to authenticated;
grant execute on function photo_prefix()                         to authenticated;
grant execute on function my_billing()                           to authenticated;
grant execute on function my_tenant_for_checkout()               to authenticated;

-- nobody but service_role, which bypasses these grants entirely:
--   setting, queue_mail_for, next_mail, mail_sent, queue_reminders,
--   set_plan, expire_plans

-- ------------------------------------------------------- 2: billing columns
-- RLS cannot restrict columns, so the refusal goes in a trigger. set_plan and
-- expire_plans raise a transaction-local flag; nothing else can, because they
-- are the only writers and they are no longer reachable from a browser.
create or replace function guard_billing_columns()
returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('bookedin.billing_write', true), '') = 'on' then
    return new;
  end if;
  if new.plan                   is distinct from old.plan
  or new.plan_until             is distinct from old.plan_until
  or new.stripe_customer_id     is distinct from old.stripe_customer_id
  or new.stripe_subscription_id is distinct from old.stripe_subscription_id then
    raise exception 'Your plan is set by billing, not from here.'
      using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger tenant_billing_guard
  before update on tenant
  for each row execute function guard_billing_columns();

create or replace function set_plan(
  p_customer     text,
  p_plan         text,
  p_until        timestamptz default null,
  p_subscription text default null,
  p_tenant       uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_plan not in ('free','pro') then
    raise exception 'unknown plan %', p_plan using errcode = 'P0001';
  end if;
  select id into v_id from tenant
   where (p_tenant is not null and id = p_tenant)
      or (p_tenant is null and stripe_customer_id = p_customer);
  if v_id is null then
    raise exception 'no studio for customer %', p_customer using errcode = 'P0002';
  end if;

  perform set_config('bookedin.billing_write', 'on', true);   -- this transaction only
  update tenant
     set plan = p_plan,
         plan_until = p_until,
         stripe_customer_id = coalesce(p_customer, stripe_customer_id),
         stripe_subscription_id = coalesce(p_subscription, stripe_subscription_id),
         updated_at = now()
   where id = v_id;
  perform set_config('bookedin.billing_write', 'off', true);

  return jsonb_build_object('tenant', v_id, 'plan', p_plan, 'until', p_until);
end $$;

create or replace function expire_plans()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform set_config('bookedin.billing_write', 'on', true);
  with done as (
    update tenant set plan = 'free', updated_at = now()
     where plan = 'pro' and plan_until is not null and plan_until < now()
    returning 1)
  select count(*) into n from done;
  perform set_config('bookedin.billing_write', 'off', true);
  return n;
end $$;

revoke execute on function set_plan(text, text, timestamptz, text, uuid) from public;
revoke execute on function expire_plans() from public;

-- --------------------------------------------------------------- 3: secrets
-- The cron job carries the key inline instead. pg_cron's job table is readable
-- only by the postgres role, which is a far better place for it than a table
-- with a SECURITY DEFINER reader.
delete from platform_setting where key = 'service_role_key';

create or replace function setting(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from platform_setting
   where key = p_key
     and key in ('site_url', 'from_name', 'functions_url');  -- never anything secret
$$;
revoke execute on function setting(text) from public;

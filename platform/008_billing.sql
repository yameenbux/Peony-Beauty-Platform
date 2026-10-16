-- Booked In — subscriptions
--
-- Plan state is written only by the Stripe webhook, running as service_role.
-- Nothing in a browser can set its own plan: there is no policy that allows
-- writing these columns, and the app reads them through a function.

alter table tenant add column stripe_customer_id     text unique;
alter table tenant add column stripe_subscription_id text unique;
-- When the paid period runs out. A cancellation at period end leaves her on
-- Pro until this moment rather than cutting her off mid-month.
alter table tenant add column plan_until timestamptz;

create index tenant_expiring_idx on tenant (plan_until) where plan = 'pro';

-- Written by the webhook only. SECURITY DEFINER with no grant to anon or
-- authenticated: service_role reaches it, a browser does not.
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

  -- the first event of a new subscription knows the tenant from the session's
  -- metadata; every later one knows only the customer
  select id into v_id from tenant
   where (p_tenant is not null and id = p_tenant)
      or (p_tenant is null and stripe_customer_id = p_customer);
  if v_id is null then
    raise exception 'no studio for customer %', p_customer using errcode = 'P0002';
  end if;

  update tenant
     set plan = p_plan,
         plan_until = p_until,
         stripe_customer_id = coalesce(p_customer, stripe_customer_id),
         stripe_subscription_id = coalesce(p_subscription, stripe_subscription_id),
         updated_at = now()
   where id = v_id;

  return jsonb_build_object('tenant', v_id, 'plan', p_plan, 'until', p_until);
end $$;

-- A subscription cancelled at period end stays Pro until the period ends, so
-- something has to notice when it has. Scheduled below.
create or replace function expire_plans()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with done as (
    update tenant set plan = 'free', updated_at = now()
     where plan = 'pro' and plan_until is not null and plan_until < now()
    returning 1)
  select count(*) into n from done;
  return n;
end $$;

-- What the app shows her. Her own row only.
create or replace function my_billing()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'plan', t.plan,
    'until', t.plan_until,
    'subscribed', t.stripe_subscription_id is not null,
    -- the customer id is what the billing portal needs; it is hers and
    -- useless to anybody else
    'customer', t.stripe_customer_id)
  from tenant t where t.owner = auth.uid();
$$;

-- The checkout function needs to know who is asking and hand Stripe a tenant
-- to put in the session metadata.
create or replace function my_tenant_for_checkout()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tenant', t.id, 'slug', t.slug, 'name', t.display_name,
    'customer', t.stripe_customer_id, 'email', u.email)
  from tenant t join auth.users u on u.id = t.owner
  where t.owner = auth.uid();
$$;

grant execute on function my_billing()              to authenticated;
grant execute on function my_tenant_for_checkout()  to authenticated;
-- deliberately NOT granted to anon or authenticated:
--   set_plan, expire_plans

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'no pg_cron: skipping the expiry schedule (not Supabase)';
    return;
  end if;
  perform cron.unschedule('bookedin-expire-plans')
    where exists (select 1 from cron.job where jobname = 'bookedin-expire-plans');
  perform cron.schedule('bookedin-expire-plans', '13 * * * *',
    $cron$ select expire_plans(); $cron$);
end $$;

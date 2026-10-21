-- Booked In — Pro+, and the thing nobody else can produce
--
-- The pricing strategy's finding, in one line: the real competitor is *free*,
-- so there is no winning on cheaper booking. What a generic scheduler cannot
-- do is know what a patch test is — and the tier above Pro is built entirely
-- out of that, because it is the only ground we hold alone.
--
-- Three tiers now: free, pro, pro_plus. Two rules follow from adding a third.
--
--   1. Every gate that said plan = 'pro' has to mean "Pro OR BETTER". A studio
--      who upgrades and silently loses her reminders is the worst bug this
--      file could ship, and it is one word away at every one of these sites.
--      So the comparison moves into is_pro() and nothing compares plan to a
--      literal again.
--   2. expire_plans() drops a lapsed subscription to free whatever it lapsed
--      from, so it has to stop naming 'pro' too.
--
-- What Pro+ actually buys, today:
--
--   The insurance pack. One call returns every dated patch test and every
--   appointment for one client, as the record an insurer asks for after a
--   reaction. The data has been sitting there since 014; nobody could get it
--   out. This is the feature the strategy calls "the document nobody else can
--   produce", and it is true because nobody else stores the test.
--
-- What it does not buy yet, and must not be sold as though it does: consent
-- forms, travel-time buffers, her own domain, Instagram publishing. The page
-- names those as next rather than included, which is what makes the tier
-- sellable at all. Pro+ shipped at a £19 launch price for that reason and is
-- £24 now that deposits are live — but note that §6's trigger wanted Instagram
-- publishing live too, and it is not. See founder/pricing-strategy.md §6.

-- ------------------------------------------------------------------- plan --
alter table tenant drop constraint tenant_plan_check;
alter table tenant add constraint tenant_plan_check
  check (plan in ('free', 'pro', 'pro_plus'));

-- One place that decides whether a plan clears the Pro bar. Stable, so it can
-- sit in an index predicate; every caller below uses it instead of a literal.
create or replace function is_pro(p_plan text)
returns boolean language sql immutable set search_path = public as $$
  select p_plan in ('pro', 'pro_plus');
$$;

create or replace function set_plan(
  p_customer     text,
  p_plan         text,
  p_until        timestamptz default null,
  p_subscription text default null,
  p_tenant       uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_plan not in ('free', 'pro', 'pro_plus') then
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

-- A lapsed subscription drops to free from whichever tier it lapsed from. This
-- said plan = 'pro', which would have left a lapsed Pro+ paying nothing and
-- keeping everything.
create or replace function expire_plans()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform set_config('bookedin.billing_write', 'on', true);
  with done as (
    update tenant set plan = 'free', updated_at = now()
     where is_pro(plan) and plan_until is not null and plan_until < now()
    returning 1)
  select count(*) into n from done;
  perform set_config('bookedin.billing_write', 'off', true);
  return n;
end $$;

-- The index behind that sweep named the literal too.
drop index if exists tenant_expiring_idx;
create index tenant_expiring_idx on tenant (plan_until) where plan <> 'free';

-- ----------------------------------------------------------- the Pro gates --
-- Two functions gate on the plan, and both are long: queue_rebook_nudges is
-- fifty lines of carefully reasoned SQL about who deserves a nudge, and
-- queue_reminders carries the whole reminder email. Retyping either of them
-- here to change one comparison is how a subtle rule gets lost in transcription
-- - and a rule lost in THIS function is a client emailed twice or not at all.
--
-- So take the definition the database currently holds, change exactly the one
-- comparison, and put it back. The body cannot drift from the original because
-- it IS the original, and if the text is not found the migration stops rather
-- than silently leaving a Pro+ studio without reminders.
do $gates$
declare
  f text;
  src text;
  out_src text;
begin
  foreach f in array array['queue_reminders', 'queue_rebook_nudges'] loop
    select pg_get_functiondef(p.oid) into src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = f;
    if src is null then
      raise exception '016: % is not there to patch', f;
    end if;

    -- Both spell it the same way: "t.plan = 'pro'".
    out_src := replace(src, 't.plan = ''pro''', 'is_pro(t.plan)');
    if out_src = src then
      raise exception '016: the plan gate in % is not where it was. Read it '
        'before changing this - a Pro+ studio silently losing % is the bug '
        'this check exists to stop.', f, f;
    end if;
    execute out_src;
  end loop;
end $gates$;

-- ------------------------------------------------------- the insurance pack
-- The document an insurer asks for when a client reacts: who she is, every
-- dated patch test, and every appointment she has had. All of it has been in
-- the database since 014 and there has been no way to get it out.
--
-- Pro+ only, and checked here rather than in the browser, because a feature
-- gated in JavaScript is not gated. Returns jsonb for the page to lay out and
-- print: a PDF built server-side would mean a renderer, a font stack and a
-- storage bucket for something her browser already does on Ctrl-P.
create or replace function client_record(p_client uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_t tenant; v_c client; v_out jsonb;
begin
  select t.* into v_t
    from tenant t join client c on c.tenant_id = t.id
   where c.id = p_client and t.owner = auth.uid();
  if v_t.id is null then
    raise exception 'That client is not yours.' using errcode = 'P0001';
  end if;
  if v_t.plan <> 'pro_plus' then
    raise exception 'The insurance pack is part of Pro+.' using errcode = 'P0006';
  end if;

  select * into v_c from client where id = p_client;

  select jsonb_build_object(
    'studio', jsonb_build_object(
      'name', v_t.display_name, 'slug', v_t.slug,
      'address', v_t.address, 'timezone', v_t.timezone),
    'client', jsonb_build_object(
      'name', v_c.name, 'email', v_c.email, 'phone', v_c.phone,
      'address', v_c.address, 'since', v_c.created_at),
    'valid_months', v_t.patch_valid_months,
    'produced_at', now(),
    'patch_tests', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tested_at', p.tested_at, 'note', p.note,
               -- a test recorded BY an appointment is stronger evidence than
               -- one typed in afterwards, so the pack says which it was
               'from_booking', p.booking_id is not null,
               'valid_until', p.tested_at + make_interval(months => v_t.patch_valid_months))
             order by p.tested_at desc)
        from patch_test p where p.client_id = p_client), '[]'::jsonb),
    'appointments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ref', b.ref, 'starts_at', b.starts_at, 'service', s.name,
               'status', b.status, 'price_pence', s.price_pence,
               'needed_patch_hours', s.patch_test_hours,
               'address', b.client_address)
             order by b.starts_at desc)
        from booking b join service s on s.id = b.service_id
       where b.client_id = p_client), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $$;

-- --------------------------------------------------------------- my_studio --
-- The dashboard has to be able to tell Pro from Pro+ to show the right things.
-- plan already rides along in my_studio; nothing to add but the note that
-- 'pro_plus' is now a value it can carry.

-- ------------------------------------------------------------------ grants
revoke execute on function is_pro(text)                                 from public;
revoke execute on function set_plan(text, text, timestamptz, text, uuid) from public;
revoke execute on function expire_plans()                               from public;
revoke execute on function queue_reminders()                            from public;
revoke execute on function queue_rebook_nudges()                        from public;
revoke execute on function client_record(uuid)                          from public;
grant execute on function is_pro(text) to anon, authenticated;
grant execute on function client_record(uuid) to authenticated;

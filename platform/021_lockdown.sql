-- 021 — the lockdown, made standing instead of point-in-time.
--
-- 009 revoked EXECUTE on every function in public from PUBLIC, and on a bare
-- Postgres that is the whole job. On Supabase it is not, for two reasons that
-- compound:
--
--   1. anon and authenticated never held EXECUTE through PUBLIC. They hold it
--      through a default ACL Supabase installs on the public schema, so
--      revoking from PUBLIC never touched either of them.
--   2. A default ACL applies at CREATE time. 009 is the ninth migration of
--      twenty-one, and 010 to 020 go on to create sixty-three more functions -
--      every one of them handed straight back to anon as it was created.
--
-- What that meant on a real project, measured rather than guessed:
--
--     set_plan      anon_can_call = true     <- hands out Pro+
--     deposit_lines anon_can_call = true     <- her bank details
--     client_record anon_can_call = true     <- a client's patch-test history
--     next_mail     anon_can_call = true     <- the mail queue
--
-- The anon key is published in the browser, so "anon can call it" means
-- anybody can. test_billing.sh asserts that she cannot grant herself Pro and
-- passes locally, because a bare Postgres has no such default ACL: the test
-- was right, the environment it ran in was not.

-- A standing sweep, not another one-off.
--
-- The obvious fix - teach the schema's default privileges to stop handing
-- functions to anon - does not work, and it is worth recording why rather
-- than leaving the next person to find out:
--
--   alter default privileges in schema public
--     revoke execute on functions from public, anon, authenticated;
--
-- removes Supabase's grant, but a default ACL that ends up equal to
-- Postgres's own built-in default is simply deleted, and the built-in default
-- for a function is EXECUTE to PUBLIC. Every role is in PUBLIC. Measured on
-- 16 across four different orderings, including FOR ROLE and keeping the row
-- alive with an unrelated grant: anon=t every time. An event trigger would
-- catch it, but creating one needs superuser, which the postgres role on
-- Supabase is not.
--
-- So the sweep is a function, and every migration that adds a function ends
-- by calling it. That is a rule a person has to remember, which is why the
-- last thing it does is assert the outcome and raise if it is wrong.
create or replace function lockdown()
returns int language plpgsql security definer set search_path = public as $lock$
declare sig text; n int := 0; bad text;
  public_fns text[] := array[
    'book(text,uuid,timestamptz,text,text,text,text,text)',
    'get_studio(text)', 'free_slots(text,uuid,date,date)',
    'get_booking(text,uuid)', 'cancel_booking(text,uuid)',
    'slug_available(text)', 'patch_status(text,text)',
    'join_waitlist(text,uuid,text,text,text)', 'leave_waitlist(uuid)',
    'set_rebook_opt_out(uuid,boolean)', 'is_pro(text)',
    'trade_profile(text)', 'trade_cancel_hours(text)',
    'busy_spans(timestamptz,timestamptz,int,int)'
  ];
  studio_fns text[] := array[
    'create_studio(text,text,text,text)',
    'my_studio()', 'my_billing()', 'my_clients()', 'my_earnings()',
    'my_patch_tests()', 'my_waitlist()', 'my_tenant_for_checkout()',
    'studio_book(uuid,timestamptz,text,text,text,text)',
    'book_series(uuid,timestamptz,int,int,text,text,text,text)',
    'studio_cancel(uuid)', 'set_closure(date,boolean,text)',
    'set_client_notes(uuid,text)', 'set_deposit_paid(uuid,boolean)',
    'add_patch_test(uuid,timestamptz,text)', 'client_record(uuid)',
    'photo_prefix()', 'plan_state(text,timestamptz,timestamptz,text)'
  ];
begin
  -- Swept one at a time rather than with "all functions in schema public",
  -- because btree_gist installs its own support functions into public and
  -- those belong to the extension, not to us. Stripping privileges from
  -- gbt_int4_consistent and friends gains nothing and is somebody else's
  -- code to break.
  --
  -- service_role keeps everything: the edge functions reach set_plan,
  -- next_mail and mail_sent with the service key, which is never in a browser.
  for sig in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and not exists (select 1 from pg_depend d
                        where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', sig);
  end loop;

  foreach sig in array public_fns loop
    if to_regprocedure('public.' || sig) is null then
      raise exception 'lockdown: % is granted but does not exist.', sig;
    end if;
    execute format('grant execute on function public.%s to anon, authenticated', sig);
    n := n + 1;
  end loop;
  foreach sig in array studio_fns loop
    if to_regprocedure('public.' || sig) is null then
      raise exception 'lockdown: % is granted but does not exist.', sig;
    end if;
    execute format('grant execute on function public.%s to authenticated', sig);
    n := n + 1;
  end loop;

  -- Assert the outcome rather than trusting the list. Anything reachable by
  -- anon that is not one of the fourteen public entry points is a mistake,
  -- and this is the line that catches a migration that forgot to call us.
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into bad
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prokind = 'f'
     and has_function_privilege('anon', p.oid, 'EXECUTE')
     and not exists (select 1 from pg_depend d
                      where d.objid = p.oid and d.deptype = 'e')
     and not exists (
       select 1 from unnest(public_fns) w
        where to_regprocedure('public.' || w) = p.oid);
  if bad is not null then
    raise exception 'lockdown: still reachable by anon: %', bad;
  end if;
  return n;
end $lock$;

revoke execute on function lockdown() from public, anon, authenticated;

do $run$
declare n int;
begin
  n := lockdown();
  raise notice 'lockdown: % functions granted', n;
end $run$;

-- 032 — the default ACL, for the fourth time, on seven tables at once.
--
-- 023 found it on `tenant`, which was handing out bank details. 024 found it
-- on `mail_outbox`. 029 found it on the `slot_taken` view, where it meant anon
-- could delete every booking on the platform. Each was closed where it was
-- found, and the thing that kept producing them was never closed at all.
--
-- Supabase grants every new object to anon and authenticated as it is created.
-- Seven tables in this schema carry RLS with NO POLICY - booking_limit,
-- platform_setting, rebook_nudge, trade_palette, trade_seed, trial_notice, and
-- what 024 left behind on mail_outbox. The rows are already unreachable, which
-- is exactly why nobody looked twice.
--
-- TRUNCATE is why it matters. RLS DOES NOT GATE TRUNCATE. A policy-less table
-- is not readable, not writable and - until this file - perfectly emptiable by
-- a role that cannot see a single row in it. Nothing in a browser has ever
-- reached these tables (every one is used only from a SECURITY DEFINER
-- function, checked before writing this), and PostgREST exposes no TRUNCATE,
-- so this was not reachable in practice. It should still never have been true.
--
-- The fix is the rule rather than the seven tables. A table with RLS and no
-- policy has declared that nobody but a definer function may touch it, so
-- lockdown() now makes that true and refuses while it is not. Write a policy
-- and the table leaves the sweep by itself.

create or replace function lockdown()
returns int language plpgsql security definer set search_path = public as $lock$
declare sig text; n int := 0; bad text;
  public_fns text[] := array[
    'book(text,uuid,timestamptz,text,text,text,text,text)',
    'get_studio(text)', 'free_slots(text,uuid,date,date)',
    'get_booking(text,uuid)', 'cancel_booking(text,uuid)',
    'slug_available(text)',
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
  open_tables text[] := array['opening', 'closure', 'reserved_slug'];
  -- Triggers that may run as the caller. See the note above each.
  invoker_triggers text[] := array['guard_billing_columns', 'snap_gap'];
  -- Views anyone may WRITE through. Empty, and it should stay empty: a view
  -- is how this schema hands out a narrowed READ. Every write goes through a
  -- definer function so it can be checked. If you ever add one here, say why.
  writable_views text[] := array[]::text[];
  -- Tables with RLS on and NO policy that someone may nevertheless hold a
  -- privilege on. Empty. A table in that state has declared that nobody but
  -- a definer function may touch it; if you ever need an exception, the
  -- honest way is to write the policy, not to list it here.
  open_service_tables text[] := array[]::text[];
begin
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

  select string_agg(format('%s.%s', pol.tablename, pol.policyname), ', '
                    order by pol.tablename, pol.policyname) into bad
    from pg_policies pol
   where pol.schemaname = 'public'
     and pol.permissive = 'PERMISSIVE'
     and pol.cmd in ('SELECT', 'ALL')
     and coalesce(pol.qual, 'true') = 'true'
     and not (pol.tablename = any (open_tables));
  if bad is not null then
    raise exception 'lockdown: these policies hand a whole table to anyone: %', bad;
  end if;

  if has_table_privilege('anon', 'public.tenant', 'SELECT') then
    raise exception
      'lockdown: anon can select from tenant. It carries her bank details; '
      'the public read is get_studio(), which is definer.';
  end if;

  -- The one this file was written for. A trigger that is not SECURITY DEFINER
  -- runs as whoever fired it, so every function in its body has to be
  -- executable by a studio - and the whole point of the sweep above is that
  -- most of them are not. That breaks on her first edit, in production, with a
  -- message about a function she has never heard of.
  select string_agg(p.proname, ', ' order by p.proname) into bad
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prorettype = 'trigger'::regtype
     and not p.prosecdef
     and exists (select 1 from pg_trigger t
                  where t.tgfoid = p.oid and not t.tgisinternal)
     and not (p.proname = any (invoker_triggers));
  if bad is not null then
    raise exception
      'lockdown: these triggers run as the caller, so everything they call '
      'must be granted to her: %. Make them SECURITY DEFINER, or add them to '
      'invoker_triggers with a reason.', bad;
  end if;

  -- THE ONE 029 WAS WRITTEN FOR. A view in this schema exists to hand out a
  -- narrowed read - slot_taken gives the booking page the times that are gone
  -- without the names that took them. It has to be security_invoker = false to
  -- do that, because anon cannot read `booking` at all.
  --
  -- But Supabase's default ACL grants a NEW VIEW to anon the same way it grants
  -- a new table, and a simple view over one table is auto-updatable. So the
  -- grant that made the read work also made DELETE work - executing as the view
  -- owner, which bypasses the RLS on booking that is the only thing protecting
  -- it. `DELETE /rest/v1/slot_taken` with no filter, with the key that ships in
  -- the browser, against every studio's diary at once.
  --
  -- 001 granted SELECT and nothing else. It did not have to grant the rest;
  -- they were already there. That is the same shape as 023 and 024, and the
  -- reason this sweep exists is that those two checked tables and functions
  -- and never thought to look at a view.
  for sig in
    select c.relname
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'public' and c.relkind in ('v', 'm')
       and not (c.relname = any (writable_views))
  loop
    execute format(
      'revoke insert, update, delete, truncate, references, trigger '
      'on public.%I from public, anon, authenticated', sig);
  end loop;

  select string_agg(distinct format('%s:%s', g.grantee, g.privilege_type), ', '
                    order by format('%s:%s', g.grantee, g.privilege_type)) into bad
    from information_schema.role_table_grants g
    join pg_class c on c.relname = g.table_name
    join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = 'public'
   where g.table_schema = 'public' and c.relkind in ('v', 'm')
     and g.grantee in ('anon', 'authenticated', 'PUBLIC')
     and g.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
     and not (g.table_name = any (writable_views));
  if bad is not null then
    raise exception
      'lockdown: a view is writable by someone who should only read it: %. '
      'A view here is a narrowed read; writes go through a definer function.',
      bad;
  end if;

  -- THE ONE 032 WAS WRITTEN FOR, and the fourth time this has been the shape
  -- of it: 023 (tenant), 024 (mail_outbox), 029 (slot_taken) and now seven
  -- tables at once. Supabase grants every new object to anon and authenticated
  -- as it is created. For a table carrying RLS and NO POLICY the rows are
  -- already unreachable, so this looks harmless - and TRUNCATE is the
  -- exception that makes it not: RLS does not gate TRUNCATE at all, so the
  -- grant left every one of these emptiable by a role that should not be able
  -- to see them.
  --
  -- The rule is the table's own declaration. RLS on with no policy means
  -- "nobody but a definer function", so nobody but a definer function holds
  -- anything. Write a policy and the table leaves this sweep by itself.
  for sig in
    select c.relname
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
       and not exists (select 1 from pg_policies p
                        where p.schemaname = 'public' and p.tablename = c.relname)
       and not (c.relname = any (open_service_tables))
  loop
    execute format('revoke all on public.%I from public, anon, authenticated', sig);
  end loop;

  select string_agg(distinct format('%s(%s:%s)', g.table_name, g.grantee,
                                    g.privilege_type), ', '
                    order by format('%s(%s:%s)', g.table_name, g.grantee,
                                    g.privilege_type)) into bad
    from information_schema.role_table_grants g
    join pg_class c on c.relname = g.table_name
    join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = 'public'
   where g.table_schema = 'public' and c.relkind = 'r' and c.relrowsecurity
     and g.grantee in ('anon', 'authenticated', 'PUBLIC')
     and not exists (select 1 from pg_policies p
                      where p.schemaname = 'public' and p.tablename = c.relname)
     and not (g.table_name = any (open_service_tables));
  if bad is not null then
    raise exception
      'lockdown: a table with RLS and no policy is still granted to somebody: '
      '%. RLS does not gate TRUNCATE, so that grant is not harmless.', bad;
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

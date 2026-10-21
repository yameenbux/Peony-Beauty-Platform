-- 029 — anon could delete every booking in the database.
--
-- Found by the Supabase linter flagging `slot_taken` as a SECURITY DEFINER
-- view, and confirmed against production with a DELETE filtered to a tenant_id
-- that cannot exist: PostgREST answered 204, not 403. The permission is real.
-- Unfiltered, the same request empties `booking` for every studio at once, and
-- the key it needs is the one served to every visitor's browser.
--
-- Three things had to line up, and 001 only chose the first:
--
--   1. The view is `security_invoker = false`, deliberately and correctly: the
--      booking page must see which times are taken, and anon cannot read
--      `booking`. So the view runs as its owner.
--   2. It is a plain select of three columns from one table, which makes it
--      AUTO-UPDATABLE in Postgres. Nobody wrote an INSTEAD OF trigger, so
--      Postgres happily rewrites a DELETE on the view into a DELETE on booking.
--   3. Supabase's default ACL had already granted anon everything on it. 001's
--      `grant select on slot_taken to anon` reads like the whole story and is
--      actually a no-op on top of a grant that was there first.
--
-- Running as the owner is what makes (3) fatal rather than untidy: the write
-- bypasses the RLS on `booking`, which is the only thing standing between a
-- visitor and every diary on the platform.
--
-- The fix is the grant, not the view. security_invoker = true would close the
-- write and break the read it exists for.

revoke insert, update, delete, truncate, references, trigger
  on public.slot_taken from public, anon, authenticated;

-- 028 set search_path on every function it added except this one, which the
-- linter noticed. It takes a numeric and returns a numeric, so nothing was
-- reachable through it; left unset it is still one more function whose
-- behaviour depends on who calls it.
alter function srgb_channel(numeric) set search_path = public;

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

  return n;
end $lock$;

revoke execute on function lockdown() from public, anon, authenticated;

do $run$
declare n int;
begin
  n := lockdown();
  raise notice 'lockdown: % functions granted', n;
end $run$;

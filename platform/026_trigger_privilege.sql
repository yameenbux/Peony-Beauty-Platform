-- 026 — two triggers that ran as the caller and called what she may not.
--
-- THE BUG, as it appeared: saving treatments in the dashboard failed with
--
--     permission denied for function guess_patch_hours
--
-- 021's sweep revokes EXECUTE on every function in public and grants back only
-- the entry points the pages call. guess_patch_hours is not one - it is a
-- lookup helper, and nothing in a browser should be able to call it. That part
-- was right.
--
-- What was missed is that a SECURITY INVOKER trigger runs as whoever fired it.
-- `suggest_patch_hours` is attached to `service` and calls guess_patch_hours
-- in its body, so when a studio saves her treatments - a plain PostgREST
-- update, as `authenticated` - the trigger needs HER to hold EXECUTE on a
-- function she must not hold EXECUTE on. The seeding in create_studio never
-- showed it, because that is SECURITY DEFINER and everything its statements
-- fire runs as the owner. It only breaks on the first edit from the dashboard.
--
-- suggest_rebook_weeks sits on the same table with the same shape and calls
-- guess_rebook_weeks. It had not been reached yet; it would have failed the
-- moment it was.
--
-- The fix is the trigger, not the grant. Granting guess_patch_hours to
-- authenticated would work and would be the wrong direction: it puts a private
-- helper on the public API to serve a call that is internal bookkeeping. A
-- trigger doing internal bookkeeping should run as the owner.
alter function suggest_patch_hours()  security definer;
alter function suggest_rebook_weeks() security definer;

-- Deliberately NOT changed, so the exception list below is a decision rather
-- than an oversight:
--
--   guard_billing_columns  reads current_setting and compares columns. It
--                          calls nothing and must see the caller's own
--                          transaction-local flag.
--   snap_gap               reads `service`, which the caller can already read,
--                          and calls nothing. It only ever fires from inside
--                          book() and studio_book(), both definer.

-- -------------------------------------------------- and the standing version
-- The same shape as every other assertion here: fixing these two does not stop
-- the next trigger being written as an invoker and calling a helper, and that
-- failure appears for the first time in front of a customer rather than in a
-- test. So lockdown() now refuses while a trigger it does not know about runs
-- as the caller.
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

  return n;
end $lock$;

revoke execute on function lockdown() from public, anon, authenticated;

do $run$
declare n int;
begin
  n := lockdown();
  raise notice 'lockdown: % functions granted', n;
end $run$;

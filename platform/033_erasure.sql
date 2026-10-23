-- 033 — the right to erasure, without destroying her insurance defence.
--
-- The privacy notice already tells a client to "ask her first": the studio is
-- the controller and we are her processor, so erasure is her decision to make
-- and ours to carry out. Until now there was no way for her to carry it out.
--
-- WHY "DELETE THE ROW" IS THE WRONG ANSWER.
--
-- Article 17 gives a client the right to be forgotten. Article 17(3) takes it
-- back where the data is needed to comply with a legal obligation, or for the
-- establishment, exercise or defence of legal claims. Both apply here:
--
--   * The patch test is the studio's evidence. 014 exists because a reaction
--     the studio cannot produce a dated test for is a reaction her insurance
--     may not cover, and that is the kind of claim that ends a one-person
--     business. Deleting the test on request would hand the client a way to
--     destroy the studio's defence, which is not what the right is for.
--   * The money is HMRC's business for six years, and the privacy notice
--     already says so.
--
-- So this erases everything that identifies her and keeps the smallest record
-- that still works as evidence. It does NOT ask the studio to make that call -
-- a lash technician should not have to reason about Article 17(3)(e) with a
-- client on the phone - it works it out, does it, and hands her a sentence she
-- can read out.
--
-- ALWAYS GONE, immediately, with no retention argument available for any of it:
--   her phone, her address, the address on every booking she ever made, the
--   hashed IP, the studio's free-text notes about her, the note on a patch
--   test, anything queued to her that has not been sent, her place on a
--   waiting list - and her email, replaced by an address at .invalid, which
--   RFC 2606 guarantees can never resolve, so nothing can ever mail her again.
--
-- KEPT, and only if there is something to defend: her name, the dates she was
--   treated, and the dates she was tested. Nothing else. A dated patch test
--   attached to "Erased" proves nothing to an insurer, which is the whole
--   reason the name is the one identifying thing that can survive.
--
-- AND THE RETENTION ENDS. purge_erasures() finishes the job when the period
-- runs out. A promise to keep something "until" is only honest if something
-- actually stops.
--
-- Six years is not a law, it is a setting: it matches the figure already in
-- the privacy notice for tax records, and it comfortably covers the three-year
-- limitation period a personal injury claim runs on. Her insurer may say
-- different, which is why it is an argument to the function.

create table if not exists erasure (
  client_id  uuid primary key references client(id) on delete cascade,
  tenant_id  uuid not null references tenant(id) on delete cascade,
  erased_at  timestamptz not null default now(),
  kept_until timestamptz,   -- null when nothing needed keeping
  reason     text,          -- why, in the words she can repeat
  purged_at  timestamptz
);
-- `if not exists` throughout, and `create or replace` below: a file applied
-- by hand in a SQL editor gets run twice sooner or later, usually halfway
-- through recovering from something else.
create index if not exists erasure_due_idx on erasure (kept_until) where purged_at is null;
alter table erasure enable row level security;   -- definer functions only

-- ------------------------------------------------------------------ erase --
create or replace function erase_client(p_client uuid, p_keep_years int default 6)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid; v_email text; v_name text;
  v_patch boolean; v_recent boolean; v_keep boolean;
  v_until timestamptz; v_reason text; v_tomb text; v_years int;
begin
  v_years := greatest(coalesce(p_keep_years, 6), 1);

  select c.tenant_id, c.email, c.name into v_tenant, v_email, v_name
    from client c join tenant t on t.id = c.tenant_id
   where c.id = p_client and t.owner = auth.uid();
  if v_tenant is null then
    raise exception 'That client is not yours.' using errcode = 'P0001';
  end if;
  if exists (select 1 from erasure e where e.client_id = p_client) then
    raise exception 'She has already been erased.' using errcode = 'P0006';
  end if;

  v_patch  := exists (select 1 from patch_test p where p.client_id = p_client);
  v_recent := exists (select 1 from booking b
                       where b.client_id = p_client
                         and b.status = 'confirmed'
                         and b.starts_at > now() - make_interval(years => v_years));
  v_keep := v_patch or v_recent;

  -- .invalid is reserved and can never resolve, so this address is not a
  -- forwarding address, it is a dead end that happens to satisfy NOT NULL and
  -- the one-client-per-email index.
  v_tomb := 'erased-' || p_client::text || '@invalid';

  update client set
      email          = v_tomb,
      phone          = null,
      address        = null,
      notes          = null,
      rebook_opt_out = true,
      name           = case when v_keep then name else 'Erased at her request' end,
      updated_at     = now()
   where id = p_client;

  update booking set
      client_email   = v_tomb,
      client_phone   = null,
      client_address = null,
      ip_key         = null,
      client_name    = case when v_keep then client_name
                            else 'Erased at her request' end
   where client_id = p_client;

  -- The DATE is the evidence. Whatever she wrote beside it is not, and it is
  -- free text, which is where the things nobody meant to keep end up.
  update patch_test set note = null where client_id = p_client;

  delete from mail_outbox  where to_email = v_email and sent_at is null;
  delete from waitlist     where tenant_id = v_tenant and email = v_email;
  delete from rebook_nudge where client_id = p_client;
  delete from patch_nudge  where client_id = p_client;

  if v_keep then
    v_until := now() + make_interval(years => v_years);
    v_reason := case
      when v_patch and v_recent then
        'a patch test on record, and treatments in the last ' || v_years || ' years'
      when v_patch then 'a patch test on record'
      else 'treatments in the last ' || v_years || ' years' end;
  end if;

  insert into erasure (client_id, tenant_id, kept_until, reason)
  values (p_client, v_tenant, v_until, v_reason);

  return jsonb_build_object(
    'erased', true,
    'kept_anything', v_keep,
    'kept_until', v_until,
    'reason', v_reason,
    -- Something she can read down the phone without having to translate it.
    'tell_her', case when v_keep then
        'I have deleted your contact details, my notes and everything I had ' ||
        'that identifies you. I have to keep a record of your treatment dates ' ||
        'and your patch test until ' ||
        to_char(v_until, 'FMDD FMMonth YYYY') ||
        ', because that is what my insurer needs if there is ever a claim. '
        'After that it goes too.'
      else
        'I have deleted everything I had about you. There was nothing I am ' ||
        'required to keep.' end);
end $$;

-- ------------------------------------------------------------------ purge --
-- What makes the retention a period rather than a word.
create or replace function purge_erasures()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update client c set name = 'Erased at her request', updated_at = now()
    from erasure e
   where e.client_id = c.id and e.purged_at is null
     and e.kept_until is not null and e.kept_until < now();

  update booking b set client_name = 'Erased at her request'
    from erasure e
   where e.client_id = b.client_id and e.purged_at is null
     and e.kept_until is not null and e.kept_until < now();

  with done as (
    update erasure set purged_at = now()
     where purged_at is null and kept_until is not null and kept_until < now()
    returning 1)
  select count(*) into n from done;
  return n;
end $$;

do $c$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice '033: pg_cron is not installed here, so nothing was scheduled';
    return;
  end if;
  begin perform cron.unschedule('bookedin-purge-erasures'); exception when others then null; end;
  perform cron.schedule('bookedin-purge-erasures', '17 4 * * *',
                        'select purge_erasures()');
end $c$;

-- erase_client is hers to call; purge_erasures is the cron job's and nobody
-- else's, so it is not on either list and the sweep revokes it.
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
    'photo_prefix()', 'plan_state(text,timestamptz,timestamptz,text)',
    'erase_client(uuid,int)'
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

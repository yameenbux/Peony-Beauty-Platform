-- 023 — the tenant table stops being a public read.
--
-- THE BUG. 001 created this, and at the time it was right:
--
--     create policy tenant_read on tenant for select using (true);
--
-- `tenant` then held the shop front and nothing else - slug, display name,
-- tagline, timezone, notice hours - and all of it is meant to be on an open
-- page. Then 008, 013, 015, 016, 017 and 020 added, to the same table:
--
--     deposit_name  deposit_sort  deposit_account  deposit_paypal
--     deposit_link  deposit_note  stripe_customer_id  stripe_subscription_id
--
-- and nobody went back to the policy. RLS cannot restrict columns - 009 says
-- so itself, which is why the billing guard had to be a trigger - so
-- `using (true)` was handing out every one of those to anybody holding the
-- anon key, which is published in every browser:
--
--     GET /rest/v1/tenant?select=slug,deposit_name,deposit_sort,deposit_account
--
-- Sort code, account number and account holder for every studio on the
-- platform, in one request, with ?deposit_sort=not.is.null to skip the ones
-- not worth taking. It also handed any signed-in studio the same thing about
-- every other studio.
--
-- 017 states the intended rule in as many words: "The AMOUNT is public ... The
-- ACCOUNT is not. A sort code and account number on an open page is a thing to
-- scrape; on the confirmation that follows a real booking it is a thing one
-- client needs. So get_studio() carries the amount and get_booking() carries
-- the account." Both functions implement that correctly. Both were bypassed by
-- not calling them and reading the table instead.
--
-- WHY NO TEST CAUGHT IT. test_booking.sh asserts that get_studio() does not
-- return account details, which is true. Nothing asserted that the table does
-- not. Same shape as the hole 021 documents: the test was right about the
-- thing it tested.

-- ------------------------------------------------------------------ the fix
-- Lock one: the policy goes. Nothing in a browser ever selected from this
-- table - all eleven call sites in app/index.html are .update(), and every
-- read goes through get_studio() or my_studio(), both SECURITY DEFINER and so
-- unaffected by RLS. With this gone, anon sees no rows at all and a signed-in
-- studio sees exactly her own, through tenant_own.
drop policy if exists tenant_read on tenant;

-- Lock two: take the privilege away as well, so the policy is not the only
-- thing standing there. Supabase's default ACL grants anon SELECT, INSERT,
-- UPDATE and DELETE on every table in public; RLS is what makes that safe, and
-- "the dangerous grant plus a policy that happens to be right" is precisely
-- the arrangement that failed above. anon has no business reading or writing
-- this table under any policy: it books through book(), which is definer.
--
-- NOT DONE WITH COLUMN PRIVILEGES, and it is worth saying why, because
-- `revoke select (deposit_sort) on tenant from anon` reads like the obvious
-- answer and does nothing at all. A table-level SELECT grant overrides any
-- column-level revoke under it; to restrict by column you must revoke the
-- table privilege and then grant back an explicit list of columns, which then
-- has to be extended by hand every time a migration adds one. The failure mode
-- is quiet and the maintenance is forever. Two whole-table locks, both of which
-- fail closed, are worth more than one brittle column list.
revoke select, insert, update, delete on tenant from anon;

-- authenticated keeps SELECT because PostgREST needs it to resolve the WHERE
-- clause of her own updates (.eq("id", ...) and .eq("slug", ...)), and
-- tenant_own already confines that to her own row. Her deposit details being
-- readable by her is the point of them.

-- -------------------------------------------------- and the standing version
-- The same lesson as 021. Fixing this policy today does not stop the next
-- migration adding a column to a table that is still handed out wholesale, so
-- the sweep learns to check policies as well as functions.
--
-- Three tables are genuinely public and are named here rather than inferred:
-- opening and closure are her working hours, reserved_slug is read by the
-- signup form before an account exists. Anything else with a blanket read is a
-- mistake, and this is the line that says so. A fourth table joining that list
-- is a decision somebody should have to write down here.
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
  -- Tables a policy may hand to everyone. See the note above.
  open_tables text[] := array['opening', 'closure', 'reserved_slug'];
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

  -- And the same assertion for tables. A permissive SELECT or ALL policy whose
  -- USING clause deparses to exactly `true` is a whole table handed to every
  -- role, because these policies are created without TO and so apply to
  -- PUBLIC. That is what 023 was written to undo; this is what stops it coming
  -- back. tenant_own survives because its clause is `owner = auth.uid()`, and
  -- service_read survives because its clause is `active` - neither is blanket.
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

  -- The table that actually went wrong, named outright. The two checks above
  -- are general and would both pass if somebody granted anon SELECT back
  -- without adding a policy, so this one closes the loop on the specific
  -- mistake: no privilege, no policy, no route in.
  if has_table_privilege('anon', 'public.tenant', 'SELECT') then
    raise exception
      'lockdown: anon can select from tenant. It carries her bank details; '
      'the public read is get_studio(), which is definer.';
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

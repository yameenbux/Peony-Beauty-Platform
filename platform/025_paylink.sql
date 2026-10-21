-- 025 — two bits of surface the audit found, closed.
--
-- 1. A PAYMENT LINK COULD BE A javascript: URI.
--
-- `esc()` on the client pages replaces & < > " and ' and nothing else, which
-- is right for text and does nothing to a scheme. `javascript:alert(1)`
-- contains none of those five characters, so it survived intact into:
--
--     <a href="javascript:...">            book/manage.html, book/index.html
--
-- and ran when her client tapped "Pay here", on a page that is already talking
-- about money. The only check was in the browser - app/index.html tested
-- `^https?://` before saving - and her settings are written with
-- sb.from("tenant").update(...), so a studio with her own token could PATCH
-- PostgREST directly and skip it. Her clients are the victims, not her, which
-- is the part that makes it worth a constraint rather than a note.
--
-- The scheme is now settled in the database, where PostgREST cannot go round
-- it. The two pages get a safeUrl() as well: one lock in each layer, because
-- the browser is where the damage happens and the database is where the rule
-- belongs.
--
-- Note the app said "A payment link has to start with https://" while testing
-- `^https?://`, so http was accepted and the message was wrong. This settles
-- it as https, which is what a payment link should be anyway, and the page now
-- matches what it says.
--
-- deposit_paypal deliberately gets NO constraint: paypal.me/hername with no
-- scheme is the documented format for that field and the pages already prefix
-- it, so a constraint here would reject the normal case.
-- Guarded because `add constraint` has no `if not exists`, and this file is
-- applied by hand in a SQL editor where a second attempt after a half-applied
-- first one is the normal way to recover. Everything else here is already
-- idempotent.
do $add$
begin
  alter table tenant add constraint tenant_deposit_link_scheme check (
    deposit_link is null or deposit_link ~* '^https://'
  );
exception when duplicate_object then
  null;
end $add$;

-- 2. patch_status() WAS REACHABLE BY ANYONE, AND CALLED BY NOTHING.
--
-- It takes a studio slug and an email address and answers from the client and
-- patch_test tables, so a positive answer tells an anonymous caller two
-- things: that the address is a client of that studio, and when she last had
-- a patch test. A patch test evidences allergy testing, which puts it close to
-- special-category data; 011 names allergies outright as an example of what
-- goes in client.notes. There is no rate limit on it - the caps in 010 are
-- counted from the booking table and so only exist for book().
--
-- The fix is not a rate limit, because the function has no caller. Checked
-- across app/index.html, book/index.html and book/manage.html: the booking
-- page does patch tests entirely through get_studio()'s patch_test_hours and
-- records_patch_test, and through book()'s P0005 refusal. 014 granted this to
-- anon for a lookup the page was going to do and never did.
--
-- So it comes off the public list. The function stays in the schema and
-- service_role keeps it; whoever writes the caller it was meant for puts it
-- back on the list, and has to answer the enumeration question then rather
-- than inheriting the answer by accident.
revoke execute on function patch_status(text, text) from public, anon, authenticated;

-- 014 still carries `grant execute on function patch_status(text, text) to
-- anon, authenticated` and is left alone: migrations are history, not a
-- statement of the current grants. lockdown() below is the current statement,
-- and its assertion is what catches a re-grant.
create or replace function lockdown()
returns int language plpgsql security definer set search_path = public as $lock$
declare sig text; n int := 0; bad text;
  -- patch_status is gone from here as of 025. Thirteen, not fourteen.
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

  return n;
end $lock$;

revoke execute on function lockdown() from public, anon, authenticated;

do $run$
declare n int;
begin
  n := lockdown();
  raise notice 'lockdown: % functions granted', n;
end $run$;

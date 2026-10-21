-- 027 — the booking page a new client cannot book anything on.
--
-- THE BUG, found by using it rather than by reading it. A lash studio signs
-- up, the wizard seeds her five treatments, and her page goes live. Every one
-- of those five needs a patch test 48 hours ahead, because 014 and 019 are
-- right that lash adhesive is a sensitiser. A client who has never been before
-- has no test on record, so every treatment refuses her with:
--
--     Classic full set needs a patch test at least 48 hours beforehand, and we
--     do not have one on record for you. Book a patch test first and then come
--     back for this.
--
-- There is no patch test to book. trade_seed has no records_patch_test column
-- at all, so nothing it creates can ever be the test, and nothing else seeds
-- one. The page tells her to do a thing the page does not offer.
--
-- How wide it goes, counted from trade_seed rather than guessed:
--
--     lashes   5 of 5 treatments need a test   nothing bookable at all
--     brows    3 of 3                          nothing bookable at all
--     pmu      3 of 3                          nothing bookable at all
--     hair     4 of 5                          one treatment bookable
--     skin     1 of 3                          two bookable
--
-- Three trades out of eleven shipped a page that cannot be booked. It is not a
-- new fault - it has been there since 014 gave treatments a patch-test
-- requirement and 019 moved seeding into trade_seed - and no test caught it
-- because every test seeds a studio and then books AS somebody with a test
-- already recorded, or books a trade that needs none.

-- ------------------------------------------------------------------- seed --
alter table trade_seed add column if not exists records_patch_test boolean not null default false;

-- Free and fifteen minutes, deliberately.
--
-- Free because it is ten minutes and a dab behind the ear, and it is the thing
-- that wins her the booking: a client who has to pay to be allowed to book
-- goes somewhere that does not ask. take_deposit() already asks nothing up
-- front for a zero-price service, so this also never collides with deposits.
--
-- Fifteen minutes so it drops into a gap rather than eating a slot, and sort 0
-- so it sits at the top of her list where a new client meets it first.
--
-- Named "Patch test" on purpose: guess_patch_hours() and guess_rebook_weeks()
-- both return null for '%patch%', so it needs no test of its own and never
-- earns a rebook nudge. The name is load-bearing - renaming it to "Allergy
-- test" would quietly give it a 48-hour requirement of its own and a nudge.
insert into trade_seed (trade, name, pence, mins, sort, rebook_weeks,
                        gap_after_min, gap_min, records_patch_test)
values ('lashes', 'Patch test', 0, 15, 0, null, null, null, true),
       ('brows',  'Patch test', 0, 15, 0, null, null, null, true),
       ('pmu',    'Patch test', 0, 15, 0, null, null, null, true),
       ('hair',   'Patch test', 0, 15, 0, null, null, null, true),
       ('skin',   'Patch test', 0, 15, 0, null, null, null, true)
on conflict (trade, name) do update
   set pence = excluded.pence, mins = excluded.mins, sort = excluded.sort,
       records_patch_test = excluded.records_patch_test;

-- ----------------------------------------------------------- create_studio --
-- Replaced outright rather than patched in place. 019 rewrote this one with
-- pg_get_functiondef() and a regex, which works until the text moves; the
-- whole body is short enough to state.
create or replace function create_studio(
  p_slug  text,
  p_name  text,
  p_trade text default 'other',
  p_tz    text default 'Europe/London'
) returns text
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Sign in first.' using errcode = 'P0001';
  end if;
  if exists (select 1 from tenant where owner = v_uid) then
    raise exception 'You already have a page.' using errcode = 'P0001';
  end if;
  if not slug_available(p_slug) then
    raise exception 'That link is taken.' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Your studio needs a name.' using errcode = 'P0001';
  end if;

  insert into tenant (owner, slug, display_name, trade, timezone,
                      cancel_hours, plan, plan_until, trial_until)
  values (v_uid, p_slug, trim(p_name), p_trade, p_tz,
          trade_cancel_hours(p_trade), 'pro_plus',
          now() + interval '14 days', now() + interval '14 days')
  returning id into v_id;

  -- records_patch_test is the column 027 added, and the reason this function
  -- is being rewritten: without it the seeded patch test is just another
  -- treatment that needs a patch test.
  insert into service (tenant_id, name, price_pence, duration_min, sort,
                       rebook_weeks, gap_after_min, gap_min, records_patch_test)
  select v_id, s.name, s.pence, s.mins, s.sort,
         s.rebook_weeks, s.gap_after_min, s.gap_min, s.records_patch_test
    from trade_seed s where s.trade = p_trade;

  insert into opening (tenant_id, weekday, starts, ends)
  select v_id, d, '09:00'::time, '18:00'::time from unnest(array[2,3,4,5,6]) d;

  return p_slug;
end $$;

-- ---------------------------------------------------------------- backfill --
-- Every studio already signed up in an affected trade has the broken page
-- right now. One insert each, and only where she has not already made her own.
insert into service (tenant_id, name, price_pence, duration_min, sort,
                     records_patch_test, active)
select t.id, 'Patch test', 0, 15, 0, true, true
  from tenant t
 where exists (select 1 from service s
                where s.tenant_id = t.id and s.active
                  and s.patch_test_hours is not null)
   and not exists (select 1 from service s
                    where s.tenant_id = t.id and s.records_patch_test);

select lockdown();

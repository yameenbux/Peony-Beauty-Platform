-- 019 — the platform stops being a lash product that other trades can log into.
--
-- Three things were wrong, and they compound.
--
-- 1. `trade` was write-once. It seeded a price list and guessed patch-test
--    hours, and after that nothing ever read it again. A salon and a lash
--    studio used an identical product from minute six onwards.
--
-- 2. The patch-test guess, which is the whole marketing position, MISSED HAIR
--    COLOUR. 'Full head highlights' - one of the three seeded hair treatments -
--    asked for no test at all, and so did balayage, bleach and 'Colour & cut'.
--    The two that passed did so by accident: 'Root tint' matched a pattern
--    written for lash tint, and 'Permanent colour' matched one written for
--    perm lotion. Hair colour allergy is the most dangerous patch test in the
--    trade, and it was the one case the product did not cover.
--
-- 3. A colour appointment is not one block of time. It is twenty minutes of
--    application, half an hour of development during which the chair is EMPTY,
--    and half an hour of finishing. Booking it as one contiguous span told
--    every hairdresser her chair was full when a third of it was free.
--
-- The fix for (3) is the interesting one. The overlap guarantee is an
-- exclusion constraint over a range; it becomes an exclusion constraint over a
-- MULTIRANGE, so one booking can hold two separate spans with a bookable hole
-- between them. Double booking stays structurally impossible - it is the same
-- mechanism, over a shape that can have a gap in it.

-- ------------------------------------------------------------- 1: trades --
-- Twelve, because 'Something else' was a cliff: an empty price list, no patch
-- defaults, and no help, handed to every trade outside the original four.
alter table tenant drop constraint if exists tenant_trade_check;
alter table tenant add constraint tenant_trade_check check (trade in (
  'lashes','brows','nails','hair','barber','skin','massage',
  'tanning','makeup','waxing','pmu','other'));

-- ------------------------------------------------- 2: seeds, as data --
-- Moved out of create_studio's body and into a table. Adding a trade was a
-- function rewrite; now it is an insert.
create table trade_seed (
  trade         text not null,
  name          text not null,
  pence         int  not null,
  mins          int  not null,
  sort          int  not null,
  -- her usual interval for this treatment, which is not a global number:
  -- infills come round every three weeks and a colour every six.
  rebook_weeks  int,
  -- the hole in the middle, where she is free (see part 5)
  gap_after_min int,
  gap_min       int,
  primary key (trade, name)
);
alter table trade_seed enable row level security;   -- read through the function only

insert into trade_seed (trade, name, pence, mins, sort, rebook_weeks, gap_after_min, gap_min) values
  ('lashes','Classic full set',      4500, 120, 1, 3, null, null),
  ('lashes','Hybrid full set',       5000, 120, 2, 3, null, null),
  ('lashes','Russian full set',      5500, 150, 3, 3, null, null),
  ('lashes','Hybrid infills',        3500,  90, 4, 3, null, null),
  ('lashes','Russian infills',       4000,  90, 5, 3, null, null),

  ('brows', 'Brow lamination',       3500,  60, 1, 6, null, null),
  ('brows', 'Brow wax & tint',       2000,  30, 2, 4, null, null),
  ('brows', 'HD brows',              3000,  45, 3, 4, null, null),

  ('nails', 'BIAB full set',         3500,  90, 1, 3, null, null),
  ('nails', 'Gel manicure',          2500,  60, 2, 3, null, null),
  ('nails', 'Infills',               3000,  75, 3, 3, null, null),
  ('nails', 'Soak off & removal',    1000,  30, 4, null, null, null),

  -- hair carries the gaps, because hair is why they exist
  ('hair',  'Cut & blow dry',        3500,  60, 1, 6, null, null),
  ('hair',  'Root tint',             4500,  90, 2, 6,   20,  35),
  ('hair',  'Full head highlights',  9000, 180, 3, 10,  60,  45),
  ('hair',  'Balayage',              9500, 180, 4, 12,  60,  45),
  ('hair',  'Cut & colour',          7500, 150, 5, 6,   25,  35),

  ('barber','Skin fade',             1800,  30, 1, 3, null, null),
  ('barber','Cut & beard trim',      2500,  45, 2, 3, null, null),
  ('barber','Beard trim',            1200,  20, 3, 3, null, null),

  ('skin',  'Signature facial',      4500,  60, 1, 4, null, null),
  ('skin',  'Dermaplaning',          5000,  60, 2, 4, null, null),
  ('skin',  'Chemical peel',         6500,  45, 3, 4, null, null),

  ('massage','Back, neck & shoulders',3000, 30, 1, 4, null, null),
  ('massage','Swedish full body',    4500,  60, 2, 4, null, null),
  ('massage','Deep tissue',          5500,  60, 3, 4, null, null),

  ('tanning','Full body spray tan',  2500,  30, 1, 2, null, null),
  ('tanning','Half body spray tan',  1800,  20, 2, 2, null, null),

  ('makeup','Occasion makeup',       5000,  60, 1, null, null, null),
  ('makeup','Bridal trial',          6500,  90, 2, null, null, null),
  ('makeup','Bridal, on the day',   12000,  90, 3, null, null, null),

  ('waxing','Lip & chin',            1200,  20, 1, 4, null, null),
  ('waxing','Full leg',              3000,  45, 2, 5, null, null),
  ('waxing','Brazilian',             3500,  40, 3, 5, null, null),

  -- the top-up is not optional work, it is part of the treatment
  ('pmu',   'Powder brows',         25000, 180, 1, null, null, null),
  ('pmu',   'Lip blush',            25000, 180, 2, null, null, null),
  ('pmu',   'Six-week top-up',       5000,  90, 3, null, null, null);

-- ------------------------------------------- 3: the patch test, properly --
-- Trade-aware rather than one list of patterns against every name, because a
-- pattern that is right for hair is wrong for nails. "Gloss" is a colour
-- service on hair and a top coat on nails; "root" is a regrowth tint on hair
-- and nothing at all anywhere else. Matching those globally would put a prompt
-- in front of a nail tech that she has to dismiss, and a safety prompt people
-- learn to dismiss is worse than no prompt.
create or replace function guess_patch_hours(p_trade text, p_name text)
returns int language sql immutable set search_path = public as $$
  select case
    -- nothing is applied, so nothing can react
    when p_name ilike '%removal%' or p_name ilike '%soak off%'
      or p_name ilike '%patch%'   or p_name ilike '%consultation%'  then null

    -- the whole of lashes and brows: adhesive, tint and lifting solution
    when p_trade in ('lashes', 'brows')                             then 48

    -- Hair and barbering. This is the block that was missing, and it is the
    -- one that matters most: PPD in permanent and semi-permanent colour is
    -- the allergen behind the serious cases in this trade. Bleach on its own
    -- is not a sensitiser in the same way, but a bleach service is finished
    -- with a toner that is, and nobody books "bleach, definitely no toner".
    when p_trade in ('hair', 'barber') and (
           p_name ilike '%colour%'    or p_name ilike '%color%'
        or p_name ilike '%tint%'      or p_name ilike '%bleach%'
        or p_name ilike '%highlight%' or p_name ilike '%foil%'
        or p_name ilike '%balayage%'  or p_name ilike '%babylight%'
        or p_name ilike '%ombre%'     or p_name ilike '%toner%'
        or p_name ilike '%gloss%'     or p_name ilike '%root%'
        or p_name ilike '%henna%'     or p_name ilike '%relax%'
        -- 'perm' deliberately also catches 'permanent' and 'semi-permanent',
        -- which is how 'Permanent colour' used to pass by accident. Now it
        -- passes on purpose, and so does the perm lotion it was written for.
        or p_name ilike '%perm%')                                   then 48

    -- Pigment under the skin. Every awarding body and insurer wants a test,
    -- and the treatment is permanent, so there is no undoing a reaction.
    when p_trade = 'pmu'                                            then 48

    -- Anywhere else: tint, lamination, henna and perm lotion are the same
    -- chemistry whoever is holding the brush, and a peel is an acid.
    when p_name ilike '%tint%'       or p_name ilike '%lamination%'
      or p_name ilike '%henna%'      or p_name ilike '%perm%'
      or p_name ilike '%peel%'                                      then 48
    else null
  end;
$$;

-- Everything already in the database was guessed with the old rules, so a
-- hairdresser who signed up yesterday has a colour on her list asking for no
-- test. Re-guess, but ONLY where the current value is exactly what the old
-- function would have produced - a number she typed herself is her decision
-- and her policy, and this migration has no business overwriting it.
--
-- A function rather than a bare UPDATE so the rule can be tested, and so it
-- can be run again by hand if a later migration widens the patterns.
create or replace function reguess_patch_hours()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  with reguess as (
    select sv.id,
           guess_patch_hours(t.trade, sv.name) as should_be,
           -- what 014 would have said, reproduced exactly
           case
             when sv.name ilike '%removal%' or sv.name ilike '%soak off%'
               or sv.name ilike '%patch%'                        then null
             when t.trade in ('lashes', 'brows')                 then 48
             when sv.name ilike '%tint%' or sv.name ilike '%lamination%'
               or sv.name ilike '%perm%'                         then 48
             else null
           end as old_would_be
      from service sv join tenant t on t.id = sv.tenant_id
  )
  update service s
     set patch_test_hours = r.should_be
    from reguess r
   where s.id = r.id
     -- untouched since 014 guessed it, so it is ours to correct
     and s.patch_test_hours is not distinct from r.old_would_be
     and r.should_be is distinct from r.old_would_be
     and not s.records_patch_test;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

select reguess_patch_hours();

-- ------------------------------------------------ 4: the hole in the middle --
-- Both or neither, and the gap has to end before the appointment does.
alter table service add column if not exists gap_after_min int;
alter table service add column if not exists gap_min       int;
alter table service drop constraint if exists service_gap_pair;
alter table service add constraint service_gap_pair
  check ((gap_after_min is null) = (gap_min is null));
alter table service drop constraint if exists service_gap_fits;
alter table service add constraint service_gap_fits check (
  gap_min is null or (
    gap_after_min >= 5 and gap_min >= 5
    and gap_after_min + gap_min <= duration_min - 5));

-- Snapshotted onto the booking, like the deposit, so that editing a treatment
-- tomorrow cannot silently reshape an appointment somebody already has.
alter table booking add column if not exists gap_after_min int;
alter table booking add column if not exists gap_min       int;

-- The shape of the time a booking actually occupies. One span when there is no
-- gap, two when there is. Immutable, so a generated column can be built from
-- it and the index can rely on it.
create or replace function busy_spans(
  p_starts timestamptz, p_ends timestamptz, p_gap_after int, p_gap int)
returns tstzmultirange language sql immutable set search_path = public as $$
  select case
    when p_gap is null or p_gap_after is null
      or p_gap <= 0 or p_gap_after <= 0
      or p_starts + make_interval(mins => p_gap_after + p_gap) >= p_ends
      then multirange(tstzrange(p_starts, p_ends, '[)'))
    else tstzmultirange(
           tstzrange(p_starts, p_starts + make_interval(mins => p_gap_after), '[)'),
           tstzrange(p_starts + make_interval(mins => p_gap_after + p_gap), p_ends, '[)'))
  end;
$$;

alter table booking add column if not exists busy tstzmultirange
  generated always as (busy_spans(starts_at, ends_at, gap_after_min, gap_min)) stored;

-- The guarantee, restated over a shape that can have a hole in it. Same
-- mechanism, same index type, same 23P01 on a collision: two people still
-- cannot hold the same minute of her time. They can now hold the same minute
-- of her waiting.
alter table booking drop constraint if exists booking_no_overlap;
alter table booking add constraint booking_no_overlap
  exclude using gist (tenant_id with =, busy with &&) where (status = 'confirmed');

-- Nothing that writes a booking needs to know about any of this. book(),
-- studio_book() and book_series() insert exactly as they did; the gap is
-- copied off the treatment on the way in, and the generated column is computed
-- after this trigger has run.
create or replace function snap_gap()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.gap_min is null and new.service_id is not null then
    select sv.gap_after_min, sv.gap_min into new.gap_after_min, new.gap_min
      from service sv where sv.id = new.service_id;
  end if;
  return new;
end $$;
drop trigger if exists booking_gap on booking;
-- "booking_gap" sorts before booking_patch_test and after booking_client, and
-- none of the three read each other, so the order is only documented here.
create trigger booking_gap before insert on booking
  for each row execute function snap_gap();

-- Her free times, with the holes in other people's appointments offered as
-- bookable. This is the function that actually gives a hairdresser back the
-- third of her day she was never selling.
create or replace function free_slots(
  p_slug text, p_service uuid, p_from date, p_to date
) returns setof timestamptz
language sql stable security definer set search_path = public as $$
  with t as (
    select id, timezone, notice_hours, slot_step_min
      from tenant where slug = p_slug
  ),
  s as (
    select sv.duration_min, sv.gap_after_min, sv.gap_min
      from service sv join t on sv.tenant_id = t.id
     where sv.id = p_service and sv.active
  ),
  day as (
    select g::date as on_date
      from generate_series(p_from, least(p_to, p_from + 92), interval '1 day') g
  ),
  cand as (
    select ((day.on_date + o.starts) at time zone t.timezone)
           + make_interval(mins => step.n) as at
      from t
      cross join s
      cross join day
      join opening o
        on o.tenant_id = t.id
       and o.weekday = extract(dow from day.on_date)::int
      cross join lateral generate_series(
        0,
        (extract(epoch from (o.ends - o.starts)) / 60)::int - s.duration_min,
        t.slot_step_min
      ) as step(n)
     where not exists (
       select 1 from closure c where c.tenant_id = t.id and c.on_date = day.on_date)
       and (extract(epoch from (o.ends - o.starts)) / 60)::int >= s.duration_min
  )
  select cand.at from cand, t, s
   where cand.at >= now() + make_interval(hours => t.notice_hours)
     and not exists (
       select 1 from booking b
        where b.tenant_id = t.id
          and b.status = 'confirmed'
          -- multirange against multirange: the candidate's own shape against
          -- everything already in the diary. A colour's development window is
          -- not part of its shape, so somebody else can be sold it.
          and b.busy && busy_spans(
                cand.at,
                cand.at + make_interval(mins => s.duration_min),
                s.gap_after_min, s.gap_min)
     )
   order by 1;
$$;

-- -------------------------------------------- 5: create_studio, from data --
-- Patched in place rather than retyped, so the parts of it this migration has
-- no opinion about cannot drift. The seeds move from a VALUES block in the
-- body to the table above; everything else is left exactly as it was.
do $seed$
declare src text; out_src text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_studio';

  out_src := regexp_replace(
    src,
    'insert into service \(tenant_id, name, price_pence, duration_min, sort\).*?where s\.trade = p_trade;',
    'insert into service (tenant_id, name, price_pence, duration_min, sort,'
    || ' rebook_weeks, gap_after_min, gap_min)' || chr(10) ||
    '  select v_id, s.name, s.pence, s.mins, s.sort,'
    || ' s.rebook_weeks, s.gap_after_min, s.gap_min' || chr(10) ||
    '    from trade_seed s where s.trade = p_trade;',
    'ns');

  if out_src = src then
    raise exception '019: the seed block in create_studio is not where it was. '
      'Read it and move the VALUES list into trade_seed by hand.';
  end if;
  execute out_src;
end $seed$;

-- --------------------------------------------- 6: what her trade means --
-- `trade` stops being a value that is only read during signup. One function,
-- so the dashboard and the marketing site cannot disagree about what a sector
-- is called or what it is sold on.
create or replace function trade_profile(p_trade text)
returns jsonb language sql immutable set search_path = public as $$
  select case p_trade
    when 'lashes' then jsonb_build_object(
      'label','Lashes','client','client',
      'patch','Adhesive, tint and lifting solution all need a test first.',
      'lead','rebook','gaps',false)
    when 'brows' then jsonb_build_object(
      'label','Brows','client','client',
      'patch','Tint, henna and lamination all need a test first.',
      'lead','rebook','gaps',false)
    when 'nails' then jsonb_build_object(
      'label','Nails','client','client',
      'patch','Nothing here needs a patch test, so nothing asks for one.',
      'lead','rebook','gaps',false)
    when 'hair' then jsonb_build_object(
      'label','Hair','client','client',
      'patch','Colour needs an allergy alert test 48 hours before. That is the one your insurer will ask about.',
      'lead','gaps','gaps',true)
    when 'barber' then jsonb_build_object(
      'label','Barbering','client','customer',
      'patch','Beard tint and colour need a test first; a cut does not.',
      'lead','gaps','gaps',true)
    when 'skin' then jsonb_build_object(
      'label','Skin and facials','client','client',
      'patch','Peels and actives need a test. A facial does not.',
      'lead','rebook','gaps',true)
    when 'massage' then jsonb_build_object(
      'label','Massage and holistic','client','client',
      'patch','Nothing here needs a patch test, so nothing asks for one.',
      'lead','rebook','gaps',false)
    when 'tanning' then jsonb_build_object(
      'label','Spray tanning','client','client',
      'patch','Some insurers want a DHA test. Set it per treatment if yours does.',
      'lead','venue','gaps',false)
    when 'makeup' then jsonb_build_object(
      'label','Makeup','client','client',
      'patch','Nothing here needs a patch test by default.',
      'lead','deposit','gaps',false)
    when 'waxing' then jsonb_build_object(
      'label','Waxing','client','client',
      'patch','Nothing here needs a patch test by default.',
      'lead','rebook','gaps',false)
    when 'pmu' then jsonb_build_object(
      'label','Permanent makeup','client','client',
      'patch','Pigment under the skin: a test first, every time, and it cannot be undone.',
      'lead','series','gaps',true)
    else jsonb_build_object(
      'label','Your treatments','client','client',
      'patch','Set a test on any treatment that needs one. Nothing is assumed.',
      'lead','rebook','gaps',true)
  end;
$$;

-- ------------------------------------------------------------------ cron --
-- nothing new to schedule

-- ---------------------------------------------------------------- grants --
revoke execute on function reguess_patch_hours()                          from public;
revoke execute on function busy_spans(timestamptz, timestamptz, int, int) from public;
revoke execute on function trade_profile(text)                            from public;
revoke execute on function snap_gap()                                     from public;
grant  execute on function trade_profile(text)            to anon, authenticated;
grant  execute on function busy_spans(timestamptz, timestamptz, int, int) to anon, authenticated;

-- ----------------------------------------------- 7: the reads carry it --
-- Patched in place for the same reason as create_studio: these two functions
-- have been rewritten by six migrations between them, and retyping one to add
-- three keys is how the seventh quietly drops something the sixth added.
do $reads$
declare f text; src text; out_src text; n int;
begin
  foreach f in array array['my_studio', 'get_studio'] loop
    select pg_get_functiondef(p.oid) into src
      from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
     where n2.nspname = 'public' and p.proname = f;

    -- the gap, on every treatment, so her diary and her page can draw it
    out_src := replace(src,
      '''patch_test_hours'', s.patch_test_hours,',
      '''patch_test_hours'', s.patch_test_hours,' || chr(10) ||
      '               ''gap_after_min'', s.gap_after_min, ''gap_min'', s.gap_min,');
    if out_src = src then
      raise exception '019: the service list in % is not where it was.', f;
    end if;

    -- her diary needs the gap on the booking, not on the treatment: the
    -- booking is what was actually sold, and the treatment may have moved
    -- since. Only my_studio has a bookings list; get_studio has none.
    if f = 'my_studio' then
      src := out_src;
      out_src := replace(src,
        '''deposit_pence'', b.deposit_pence, ''deposit_paid_at'', b.deposit_paid_at,',
        '''deposit_pence'', b.deposit_pence, ''deposit_paid_at'', b.deposit_paid_at,' || chr(10) ||
        '               ''gap_after_min'', b.gap_after_min, ''gap_min'', b.gap_min,');
      if out_src = src then
        raise exception '019: the booking list in my_studio is not where it was.';
      end if;
    end if;

    -- and what her trade means, beside the trade itself
    src := out_src;
    out_src := replace(src, '''trade'', t.trade,',
                            '''trade'', t.trade, ''trade_profile'', trade_profile(t.trade),');
    if out_src = src then
      raise exception '019: the trade key in % is not where it was.', f;
    end if;

    execute out_src;
  end loop;

  -- and prove it, rather than trusting the replace
  select count(*) into n from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname in ('my_studio','get_studio')
     and pg_get_functiondef(p.oid) like '%trade_profile%';
  if n <> 2 then
    raise exception '019: expected both reads to carry trade_profile, found %', n;
  end if;
end $reads$;

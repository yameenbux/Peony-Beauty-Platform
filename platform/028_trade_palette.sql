-- 028 — a palette per trade.
--
-- A barber's booking page is blush pink, because every page is. Her brand
-- colour and her logo have been in the schema since 013 and the booking page
-- reads neither: get_studio() returns brand_hex and logo_path and
-- book/index.html never looks at them. So "customise your brand" has meant
-- customising the Stories card and nothing her clients ever see.
--
-- Two halves, and this file is only the first. The DEFAULT per trade lives
-- here, because it is data. The override from her own brand_hex happens in the
-- page, because the page already does colour arithmetic for the Stories card
-- and a second implementation of it in SQL would be a second thing to be wrong.
--
-- A TABLE rather than a case block, for the reason 019 gives when it moved the
-- treatment seeds out of create_studio: adding a trade was a function rewrite,
-- and now it is an insert.
create table if not exists trade_palette (
  trade  text primary key,
  accent text not null check (accent ~* '^#[0-9a-f]{6}$'),   -- links, prices, focus
  deep   text not null check (deep   ~* '^#[0-9a-f]{6}$'),   -- the button hover fill
  ink    text not null check (ink    ~* '^#[0-9a-f]{6}$'),   -- headings, button ground
  petal  text not null check (petal  ~* '^#[0-9a-f]{6}$'),   -- tinted blocks, button text
  blush  text not null check (blush  ~* '^#[0-9a-f]{6}$'),   -- borders, chips
  ground text not null check (ground ~* '^#[0-9a-f]{6}$')    -- the page itself
);
alter table trade_palette enable row level security;   -- read through the function only

-- WHICH PAIRS WERE CHECKED, because the first attempt checked the wrong ones.
-- app.css renders .btn-primary as background:var(--plum); color:var(--petal) -
-- ink ground, tint text - and fills the hover from --carmine-deep. So the
-- pairs that matter are petal-on-ink, petal-on-deep, accent-on-ground,
-- accent-on-petal and ink-on-both grounds. A first pass tested white-on-accent,
-- which this product never draws, and "fixed" nine palettes against a pair that
-- does not exist. Every row below clears 4.5:1 on the accent pairs and 7:1 on
-- the ink pairs, measured, not judged by eye.
--
-- Lashes is the existing Booked In carmine unchanged: it was designed for this
-- trade, so no studio already open sees her page move.
insert into trade_palette (trade, accent, deep, ink, petal, blush, ground) values
  ('lashes', '#B8465C','#8E2F43','#43192A','#FAEFF0','#F2D7DB','#FDFAFA'),
  ('brows',  '#9C5A44','#7A4232','#3A2219','#F7EFEA','#EBD8CC','#FDFAF8'),
  ('nails',  '#BB3F71','#872C53','#3D1430','#FBEDF4','#F2D3E2','#FDFAFC'),
  ('hair',   '#A8582C','#823F1C','#3A2113','#FAF0E8','#EFD9C7','#FDFBF8'),
  -- The one this file was written for. Cool slate ink and oxblood instead of
  -- plum and carmine, and grey-blue tints instead of blush.
  ('barber', '#7E3038','#5E2129','#1F262B','#EFF2F4','#D8DFE4','#FBFCFD'),
  ('skin',   '#3C7868','#2A584C','#17322C','#ECF4F1','#CFE3DC','#FAFDFC'),
  ('massage','#4E7851','#395A3C','#1D2F20','#EFF4EE','#D5E3D4','#FBFDFA'),
  ('tanning','#986425','#704817','#3A2810','#FBF3E6','#F0DEBF','#FDFBF6'),
  ('makeup', '#9A3D74','#762C58','#331331','#F8EDF4','#E9D1E0','#FDFAFC'),
  ('waxing', '#A65465','#813F4D','#35191F','#F9EFF1','#EDD5DA','#FDFAFB'),
  ('pmu',    '#6A4C7A','#4E3759','#241A2B','#F3EFF6','#DED3E6','#FCFAFD'),
  ('other',  '#B8465C','#8E2F43','#43192A','#FAEFF0','#F2D7DB','#FDFAFA')
on conflict (trade) do update
   set accent = excluded.accent, deep   = excluded.deep,
       ink    = excluded.ink,    petal  = excluded.petal,
       blush  = excluded.blush,  ground = excluded.ground;

-- ------------------------------------------------------------ the function
-- trade_profile() already carries everything else that differs by trade - the
-- label, whether she says client or customer, the patch-test sentence - and
-- get_studio() already embeds it. Putting the palette here means no change to
-- get_studio or my_studio at all, which between them are two hundred lines
-- that nothing should rewrite for a colour.
--
-- It stops being IMMUTABLE: it reads a table now, and an immutable function
-- that reads a table is a wrong answer waiting to be cached. It becomes
-- SECURITY DEFINER for the same reason 026's triggers did - trade_palette is
-- RLS'd with no policy, so an invoker running as anon would read nothing and
-- the page would silently fall back to pink.
create or replace function trade_profile(p_trade text)
returns jsonb language sql stable security definer set search_path = public as $$
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
  end
  -- An unknown trade falls back to 'other' rather than to nothing, so a page
  -- can always paint itself.
  || jsonb_build_object('palette', (
       select to_jsonb(p) - 'trade' from trade_palette p
        where p.trade = coalesce(
          (select x.trade from trade_palette x where x.trade = p_trade), 'other')));
$$;

-- --------------------------------------------------- readable, or refused
-- The contrast rule, in the database, so it survives the next person adding a
-- trade in a hurry. The marketing page shipped a 1.35:1 eyebrow once and the
-- only thing that caught it was a test somebody remembered to run.
create or replace function srgb_channel(c numeric)
returns numeric language sql immutable as $$
  select case when c <= 0.04045 then c / 12.92
              else power((c + 0.055) / 1.055, 2.4) end;
$$;

create or replace function rel_luminance(p_hex text)
returns numeric language sql immutable set search_path = public as $$
  select 0.2126 * srgb_channel(('x' || substr(p_hex, 2, 2))::bit(8)::int / 255.0)
       + 0.7152 * srgb_channel(('x' || substr(p_hex, 4, 2))::bit(8)::int / 255.0)
       + 0.0722 * srgb_channel(('x' || substr(p_hex, 6, 2))::bit(8)::int / 255.0);
$$;

create or replace function wcag_ratio(a text, b text)
returns numeric language sql immutable set search_path = public as $$
  select round((greatest(rel_luminance(a), rel_luminance(b)) + 0.05)
             / (least(rel_luminance(a), rel_luminance(b)) + 0.05), 2);
$$;

-- The six pairs app.css actually renders, named so a failure says which one.
create or replace function palette_unreadable(p trade_palette)
returns text language sql stable set search_path = public as $$
  select string_agg(format('%s %s (needs %s)', pair, got, need), '; ')
    from (values
      ('petal on ink',     wcag_ratio(p.petal,  p.ink),    7.0),
      ('petal on deep',    wcag_ratio(p.petal,  p.deep),   4.5),
      ('accent on ground', wcag_ratio(p.accent, p.ground), 4.5),
      ('accent on petal',  wcag_ratio(p.accent, p.petal),  4.5),
      ('ink on ground',    wcag_ratio(p.ink,    p.ground), 7.0),
      ('ink on petal',     wcag_ratio(p.ink,    p.petal),  7.0)
    ) as x(pair, got, need)
   where got < need;
$$;

create or replace function check_palette_readable()
returns trigger language plpgsql security definer set search_path = public as $$
declare bad text;
begin
  bad := palette_unreadable(new);
  if bad is not null then
    raise exception 'palette for % is not readable: %', new.trade, bad
      using errcode = 'P0001';
  end if;
  return new;
end $$;

-- `create or replace trigger` rather than drop-then-create: Postgres has had
-- it since 14, it makes this file re-runnable without a DROP, and a DROP is
-- the one statement the Supabase MCP connector refuses to pass through.
create or replace trigger trade_palette_readable
  before insert or update on trade_palette
  for each row execute function check_palette_readable();

-- And the twelve already in the table, which the trigger did not see because
-- it did not exist when they went in.
do $check$
declare bad text;
begin
  select string_agg(format('%s: %s', p.trade, palette_unreadable(p)), ' | ')
    into bad from trade_palette p where palette_unreadable(p) is not null;
  if bad is not null then
    raise exception '028: %', bad;
  end if;
end $check$;

select lockdown();

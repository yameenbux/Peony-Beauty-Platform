-- Booked In — her colours on her card, and ours on every page
--
-- Two changes that pull in opposite directions, which is the point.
--
-- The Stories card is HER marketing. It goes out under her name, next to her
-- own photographs, and a card that looks like Booked In rather than like her
-- is a card she will not post. So she gets her colour, her logo and a choice
-- about how it is laid out.
--
-- The booking page is OURS as well as hers. "Powered by Booked In" now sits in
-- its footer on every plan, not just the free one, which is a deliberate
-- reversal: it used to come off at Pro and that was sold as part of the price.
-- The copy on the pricing card and in the app has been changed to match -
-- continuing to sell the removal of something that no longer gets removed is
-- the kind of thing that gets a first customer refunded.

-- --------------------------------------------------------------- her brand
-- Checked here rather than trusted from the browser. It ends up in a canvas
-- fillStyle and in a stylesheet, and "#fff; background:url(...)" is not a
-- colour. Six digits only: shorthand and named colours are not worth the
-- parsing, and the picker always sends six.
alter table tenant add column brand_hex text
  check (brand_hex is null or brand_hex ~ '^#[0-9A-Fa-f]{6}$');

-- <tenant_id>/logo.png in the same bucket as the treatment photographs, so the
-- storage policy that already decides ownership from the first path segment
-- covers it without a second policy.
alter table tenant add column logo_path text;

alter table tenant add column card_theme text not null default 'light'
  check (card_theme in ('light', 'dark'));
alter table tenant add column card_align text not null default 'left'
  check (card_align in ('left', 'centre'));

-- --------------------------------------------------------- what the app reads
create or replace function my_studio()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'plan', t.plan, 'timezone', t.timezone,
    'notice_hours', t.notice_hours, 'slot_step_min', t.slot_step_min,
    'cancel_hours', t.cancel_hours, 'remind_hours', t.remind_hours,
    'rebook_on', t.rebook_on, 'rebook_lead_days', t.rebook_lead_days,
    'brand_hex', t.brand_hex, 'logo_path', t.logo_path,
    'card_theme', t.card_theme, 'card_align', t.card_align,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'price_pence', s.price_pence,
               'duration_min', s.duration_min, 'active', s.active, 'sort', s.sort,
               'photo_path', s.photo_path, 'rebook_weeks', s.rebook_weeks)
             order by s.sort, s.name)
        from service s where s.tenant_id = t.id), '[]'::jsonb),
    'openings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'weekday', o.weekday, 'area', o.area,
               'starts', o.starts, 'ends', o.ends) order by o.weekday, o.starts)
        from opening o where o.tenant_id = t.id), '[]'::jsonb),
    'closures', coalesce((
      select jsonb_agg(jsonb_build_object('on_date', c.on_date, 'reason', c.reason)
             order by c.on_date)
        from closure c where c.tenant_id = t.id and c.on_date >= current_date), '[]'::jsonb),
    'bookings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'ref', b.ref, 'starts_at', b.starts_at,
               'ends_at', b.ends_at, 'client_name', b.client_name,
               'client_email', b.client_email, 'client_phone', b.client_phone,
               'status', b.status, 'service', sv.name, 'price_pence', sv.price_pence)
             order by b.starts_at)
        from booking b join service sv on sv.id = b.service_id
       where b.tenant_id = t.id and b.starts_at > now() - interval '30 days'), '[]'::jsonb)
  )
  from tenant t where t.owner = auth.uid();
$$;

-- Her booking page needs the colour and the logo too: the page a client opens
-- should look like her as much as the card does.
create or replace function get_studio(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'timezone', t.timezone, 'plan', t.plan,
    'notice_hours', t.notice_hours, 'cancel_hours', t.cancel_hours,
    'brand_hex', t.brand_hex, 'logo_path', t.logo_path,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'photo_path', s.photo_path,
               'price_pence', s.price_pence, 'duration_min', s.duration_min)
             order by s.sort, s.name)
        from service s where s.tenant_id = t.id and s.active), '[]'::jsonb),
    'openings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'weekday', o.weekday, 'area', o.area,
               'starts', o.starts, 'ends', o.ends) order by o.weekday)
        from opening o where o.tenant_id = t.id), '[]'::jsonb)
  )
  from tenant t where t.slug = p_slug;
$$;

revoke execute on function my_studio()        from public;
revoke execute on function get_studio(text)   from public;
grant  execute on function my_studio()        to authenticated;
grant  execute on function get_studio(text)   to anon, authenticated;

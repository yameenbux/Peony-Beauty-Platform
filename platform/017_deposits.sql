-- Booked In — deposits, without ever touching the money
--
-- The earlier plan for this (INTEGRATIONS.md) was Stripe Connect: every studio
-- completes Stripe's onboarding, we hold a platform account, money moves
-- through us to her. That was wrong, and expensively so.
--
-- What is actually wanted is simpler and better: she puts HER OWN details in —
-- a PayPal link, her bank account, or a payment link she already has — and the
-- client pays HER, directly. We never see the money, never hold it, never take
-- a cut, and have no say in it. The platform's job is to ask for the deposit at
-- the right moment, say exactly how to pay it, and keep the score.
--
-- That removes, in one decision:
--
--   * Stripe Connect onboarding — a passport photograph and a bank account in
--     the middle of a ninety-second signup, which is where signups die.
--   * payouts_ready, and the days of identity checks behind it.
--   * A pending booking status, an expiry to release abandoned checkouts, a
--     webhook to confirm payment, and widening the overlap constraint to cover
--     a state that can expire. That was the fortnight of careful work on the
--     one path where a mistake costs somebody real money.
--   * Being a payment facilitator at all, with everything that follows.
--
-- And it means deposits work on day one for a studio who has nothing but a bank
-- account, which is most of them.
--
-- THE HONEST LIMIT, said out loud because the design has to carry it: we cannot
-- see her bank. Nothing here can verify that a deposit arrived, so a deposit
-- cannot automatically hold or release a slot. She marks it received. The page
-- never pretends otherwise — it says "she will confirm once it arrives", not
-- "paid". A feature that implied enforcement it does not have would be worse
-- than no feature, because she would stop checking.
--
-- WHERE THE DETAILS ARE SHOWN, and where they are not. The AMOUNT is public:
-- "£10 deposit" has to be visible before anybody picks a time, or the deposit
-- is a surprise at the end. The ACCOUNT is not. A sort code and account number
-- on an open page is a thing to scrape; on the confirmation that follows a real
-- booking it is a thing one client needs. So get_studio() carries the amount
-- and get_booking() carries the account.

-- ------------------------------------------------------------------ tenant --
alter table tenant add column deposit_pence int not null default 0
  check (deposit_pence >= 0 and deposit_pence <= 100000);

-- How she wants it. Not a payment integration: a set of instructions we repeat
-- back to her client accurately.
alter table tenant add column deposit_how text not null default 'none'
  check (deposit_how in ('none', 'bank', 'paypal', 'link'));

alter table tenant add column deposit_name text;       -- the name on the account
alter table tenant add column deposit_sort text;       -- sort code, as she writes it
alter table tenant add column deposit_account text;    -- account number
alter table tenant add column deposit_paypal text;     -- paypal.me/hername
alter table tenant add column deposit_link text;       -- her own Stripe, SumUp, Monzo…
alter table tenant add column deposit_note text;       -- "within 24 hours or it is released"

-- A deposit that is switched on but has nowhere to send the money is the one
-- state that must not exist: her client would be asked for £10 and told nothing
-- about where to put it.
-- Named deposit_route rather than deposit_how: Postgres auto-names the inline
-- check on the deposit_how column "tenant_deposit_how_check" already, and the
-- collision stops the migration dead.
alter table tenant add constraint tenant_deposit_route_check check (
  deposit_pence = 0
  or (deposit_how = 'bank'   and nullif(trim(deposit_name), '') is not null
                             and nullif(trim(deposit_sort), '') is not null
                             and nullif(trim(deposit_account), '') is not null)
  or (deposit_how = 'paypal' and nullif(trim(deposit_paypal), '') is not null)
  or (deposit_how = 'link'   and nullif(trim(deposit_link), '') is not null)
);

-- ----------------------------------------------------------------- booking --
-- Snapshotted, like the client's address: changing what she charges next month
-- must not rewrite what somebody was asked for last month.
alter table booking add column deposit_pence int not null default 0;
alter table booking add column deposit_paid_at timestamptz;

create index booking_deposit_due_idx on booking (tenant_id, starts_at)
  where deposit_pence > 0 and deposit_paid_at is null and status = 'confirmed';

-- Set as the booking is written, from her settings and the price of the thing
-- booked. A trigger rather than an argument to book(), because the client does
-- not get a say in it and nothing she sends should be able to change it.
-- Deposits are a Pro feature. The strategy contradicts itself about this - §2
-- lists them under Pro, §6 implies Pro+ - and §5 settles it: Pro+ exists to
-- anchor the page so £10 reads as restrained, and the Free-to-Pro upgrade
-- trigger it names is "her first no-show". A deposit is the answer to a
-- no-show, so it is the thing Pro is for.
--
-- Enforced here rather than in her settings, so a studio who lapses to free
-- stops asking her clients for money she has stopped paying us to collect.
create or replace function take_deposit()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_want int; v_price int;
begin
  select case when is_pro(t.plan) then t.deposit_pence else 0 end
    into v_want from tenant t where t.id = new.tenant_id;
  select s.price_pence into v_price from service s where s.id = new.service_id;
  -- Never more than the treatment costs, which also means a free patch test
  -- asks for nothing. Being charged a £10 deposit on a £0 appointment is the
  -- kind of thing that gets a screenshot.
  new.deposit_pence := least(coalesce(v_want, 0), coalesce(v_price, 0));
  return new;
end $$;

-- booking_deposit sorts between booking_client and booking_patch_test, and
-- depends on neither: it reads the tenant and the service, not the client.
create trigger booking_deposit before insert on booking
  for each row execute function take_deposit();

-- She is the only one who knows whether it arrived.
create or replace function set_deposit_paid(p_booking uuid, p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_when timestamptz;
begin
  select b.id into v_id
    from booking b join tenant t on t.id = b.tenant_id
   where b.id = p_booking and t.owner = auth.uid();
  if v_id is null then
    raise exception 'That booking is not yours.' using errcode = 'P0001';
  end if;
  v_when := case when p_on then now() else null end;
  update booking set deposit_paid_at = v_when where id = v_id;
  return jsonb_build_object('booking', v_id, 'paid', p_on, 'at', v_when);
end $$;

-- ------------------------------------------------------- what the pages read
-- The public page gets the amount and nothing else. Her account details are
-- deliberately absent from this function: it is served to anyone who types the
-- address.
create or replace function get_studio(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'timezone', t.timezone, 'plan', t.plan,
    'notice_hours', t.notice_hours, 'cancel_hours', t.cancel_hours,
    'brand_hex', t.brand_hex, 'logo_path', t.logo_path,
    'patch_valid_months', t.patch_valid_months,
    'venue_kind', t.venue_kind, 'address', t.address, 'address_note', t.address_note,
    -- Nothing is announced that take_deposit() would not then ask for.
    'deposit_pence', case when is_pro(t.plan) then t.deposit_pence else 0 end,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'photo_path', s.photo_path,
               'price_pence', s.price_pence, 'duration_min', s.duration_min,
               'patch_test_hours', s.patch_test_hours,
               'records_patch_test', s.records_patch_test)
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

-- Her client, holding the reference and the token for one booking, gets the
-- account details. This is the one place they appear to anybody but her, and it
-- is reached only by somebody who has actually booked.
create or replace function get_booking(p_ref text, p_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ref', b.ref, 'starts_at', b.starts_at, 'ends_at', b.ends_at,
    'status', b.status, 'client_name', b.client_name,
    'service', s.name, 'price_pence', s.price_pence,
    'studio', t.display_name, 'slug', t.slug, 'timezone', t.timezone,
    'cancel_hours', t.cancel_hours,
    'can_cancel', (b.status = 'confirmed'
                   and b.starts_at > now() + make_interval(hours => t.cancel_hours)),
    'venue_kind', t.venue_kind, 'address', t.address, 'address_note', t.address_note,
    'client_address', b.client_address,
    'deposit', case when b.deposit_pence > 0 then jsonb_build_object(
        'pence', b.deposit_pence,
        'paid_at', b.deposit_paid_at,
        'how', t.deposit_how,
        'name', t.deposit_name, 'sort', t.deposit_sort, 'account', t.deposit_account,
        'paypal', t.deposit_paypal, 'link', t.deposit_link, 'note', t.deposit_note)
      else null end
  )
  from booking b
  join service s on s.id = b.service_id
  join tenant  t on t.id = b.tenant_id
  where b.ref = p_ref and b.cancel_token = p_token;
$$;

-- Her own read: the settings, and whether each booking has been paid.
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
    'patch_valid_months', t.patch_valid_months,
    'venue_kind', t.venue_kind, 'address', t.address, 'address_note', t.address_note,
    'deposit_pence', t.deposit_pence, 'deposit_how', t.deposit_how,
    'deposit_name', t.deposit_name, 'deposit_sort', t.deposit_sort,
    'deposit_account', t.deposit_account, 'deposit_paypal', t.deposit_paypal,
    'deposit_link', t.deposit_link, 'deposit_note', t.deposit_note,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'price_pence', s.price_pence,
               'duration_min', s.duration_min, 'active', s.active, 'sort', s.sort,
               'photo_path', s.photo_path, 'rebook_weeks', s.rebook_weeks,
               'patch_test_hours', s.patch_test_hours,
               'records_patch_test', s.records_patch_test)
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
               'client_id', b.client_id, 'client_address', b.client_address,
               'deposit_pence', b.deposit_pence, 'deposit_paid_at', b.deposit_paid_at,
               'status', b.status, 'service', sv.name, 'price_pence', sv.price_pence)
             order by b.starts_at)
        from booking b join service sv on sv.id = b.service_id
       where b.tenant_id = t.id and b.starts_at > now() - interval '30 days'), '[]'::jsonb)
  )
  from tenant t where t.owner = auth.uid();
$$;

-- ------------------------------------------------------------------- email --
-- The confirmation is where the deposit is actually asked for, so it has to
-- carry the account details and the reference to put with the payment.
create or replace function deposit_lines(p_tenant uuid, p_pence int, p_ref text)
returns text language plpgsql stable security definer set search_path = public as $$
declare t tenant; v text;
begin
  if coalesce(p_pence, 0) = 0 then return ''; end if;
  select * into t from tenant where id = p_tenant;

  v := E'\n--\nA deposit of £' ||
       trim(to_char(p_pence / 100.0, 'FM999990.00')) || ' holds this appointment.' || E'\n';

  if t.deposit_how = 'bank' then
    v := v || E'\nBank transfer:\n' ||
         '  ' || t.deposit_name || E'\n' ||
         '  Sort code ' || t.deposit_sort || E'\n' ||
         '  Account ' || t.deposit_account || E'\n' ||
         '  Reference ' || p_ref || E'\n';
  elsif t.deposit_how = 'paypal' then
    v := v || E'\nPayPal: ' || t.deposit_paypal || E'\n' ||
         'Please put ' || p_ref || E' in the note.\n';
  elsif t.deposit_how = 'link' then
    v := v || E'\nPay here: ' || t.deposit_link || E'\n' ||
         'Please quote ' || p_ref || E'.\n';
  end if;

  if nullif(trim(t.deposit_note), '') is not null then
    v := v || E'\n' || t.deposit_note || E'\n';
  end if;
  -- Said plainly, because nothing here can see her bank.
  v := v || E'\nShe will confirm once it reaches her.\n';
  return v;
end $$;

-- queue_mail_for, with the deposit block added to the client's confirmation and
-- a line on hers telling her what to watch for. 015's definition otherwise.
create or replace function queue_mail_for(p_booking uuid, p_cancelled boolean)
returns int language plpgsql security definer set search_path = public as $$
declare
  b booking; s service; t tenant;
  v_when text; v_site text; v_manage text; v_owner_email text; n int := 0;
  v_client_at text := ''; v_studio_at text := ''; v_dep text := '';
begin
  select * into b from booking where id = p_booking;
  if b.id is null then return 0; end if;
  select * into s from service where id = b.service_id;
  select * into t from tenant  where id = b.tenant_id;

  v_site := coalesce(setting('site_url'), 'https://booked-in.co.uk');
  v_when := to_char(b.starts_at at time zone t.timezone, 'FMDay FMDD FMMonth') ||
            ' at ' || to_char(b.starts_at at time zone t.timezone, 'HH24:MI');
  v_manage := v_site || '/book/manage.html?r=' || b.ref || '&t=' || b.cancel_token::text;

  select u.email into v_owner_email from auth.users u where u.id = t.owner;

  if nullif(trim(b.client_address), '') is not null then
    v_client_at := E'\n' || t.display_name || ' is coming to you at ' ||
                   b.client_address || E'.\n';
    v_studio_at := E'\n' || b.client_address || E'\n';
    if nullif(trim(t.address_note), '') is not null then
      v_client_at := v_client_at || t.address_note || E'\n';
    end if;
  elsif nullif(trim(t.address), '') is not null then
    v_client_at := E'\nWhere:\n' || t.address || E'\n';
    if nullif(trim(t.address_note), '') is not null then
      v_client_at := v_client_at || t.address_note || E'\n';
    end if;
  end if;

  if not p_cancelled then
    v_dep := deposit_lines(t.id, b.deposit_pence, b.ref);

    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    values (b.id, 'client_booked', b.client_email, b.client_name,
      'Your appointment with ' || t.display_name || ' is booked',
      'Hi ' || split_part(b.client_name, ' ', 1) || E',\n\n' ||
      'You are booked in with ' || t.display_name || E'.\n\n' ||
      s.name || E'\n' || v_when || E'\n' ||
      '£' || trim(to_char(s.price_pence / 100.0, 'FM999990.00')) || E'\n' ||
      'Reference ' || b.ref || E'\n' ||
      v_client_at || v_dep || E'\n' ||
      'Need to change it? ' || v_manage || E'\n\n' ||
      'See you then.');
    n := n + 1;

    if v_owner_email is not null then
      insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
      values (b.id, 'studio_booked', v_owner_email, t.display_name,
        'New booking: ' || b.client_name || ', ' || v_when,
        b.client_name || ' has booked ' || s.name || E'.\n\n' ||
        v_when || E'\n' ||
        '£' || trim(to_char(s.price_pence / 100.0, 'FM999990.00')) || E'\n' ||
        b.client_email || coalesce(E'\n' || b.client_phone, '') || E'\n' ||
        v_studio_at ||
        'Reference ' || b.ref || E'\n' ||
        case when b.deposit_pence > 0 then
          E'\nShe has been asked for a £' ||
          trim(to_char(b.deposit_pence / 100.0, 'FM999990.00')) ||
          E' deposit. Mark it off in your diary when it arrives.\n' else '' end ||
        E'\nYour diary: ' || v_site || '/app/');
      n := n + 1;
    end if;
  else
    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    values (b.id, 'client_cancelled', b.client_email, b.client_name,
      'Your appointment with ' || t.display_name || ' is cancelled',
      'Hi ' || split_part(b.client_name, ' ', 1) || E',\n\n' ||
      'Your ' || s.name || ' on ' || v_when || ' is cancelled.' ||
      case when b.cancelled_by = 'studio'
        then ' ' || t.display_name || ' cancelled it, so do get in touch to rearrange.'
        else '' end || E'\n\n' ||
      -- A deposit we never held is a deposit we cannot refund, and saying
      -- nothing would leave her client wondering.
      case when b.deposit_pence > 0 and b.deposit_paid_at is not null then
        'Your deposit was paid directly to ' || t.display_name ||
        E', so any refund is between you and her.\n\n' else '' end ||
      'Book another any time: ' || v_site || '/book/?s=' || t.slug);
    n := n + 1;

    if v_owner_email is not null then
      insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
      values (b.id, 'studio_cancelled', v_owner_email, t.display_name,
        'Cancelled: ' || b.client_name || ', ' || v_when,
        b.client_name || ' is no longer coming for ' || s.name || E'.\n\n' ||
        v_when || E'\n' ||
        case when b.cancelled_by = 'client'
          then 'She cancelled it herself, and the time is back on sale.'
          else 'You cancelled this one.' end || E'\n\n' ||
        'Your diary: ' || v_site || '/app/');
      n := n + 1;
    end if;
  end if;
  return n;
end $$;

-- ------------------------------------------------------------------ grants
revoke execute on function take_deposit()                     from public;
revoke execute on function set_deposit_paid(uuid, boolean)    from public;
revoke execute on function deposit_lines(uuid, int, text)     from public;
revoke execute on function queue_mail_for(uuid, boolean)      from public;
revoke execute on function get_studio(text)                   from public;
revoke execute on function get_booking(text, uuid)            from public;
revoke execute on function my_studio()                        from public;
grant execute on function set_deposit_paid(uuid, boolean) to authenticated;
grant execute on function my_studio()                     to authenticated;
grant execute on function get_studio(text)                to anon, authenticated;
grant execute on function get_booking(text, uuid)         to anon, authenticated;

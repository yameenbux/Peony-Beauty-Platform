-- 020 — paying for it, cancelling it, and fourteen days of Pro+.
--
-- Four things, and the first one is a correction of a word rather than a
-- feature: "deposit" was the only shape money could take. A barber taking
-- £18 for a skin fade does not want a deposit, he wants the £18. The column
-- stays called deposit_pence because it is the amount due up front either
-- way; what is new is pay_kind, which says whether that amount is part of
-- the price or all of it.
--
-- The money still never touches us. Full payment goes to her bank, her
-- PayPal or her own link, exactly as a deposit does, and she is the one who
-- says it arrived. That is the whole principle of the platform and widening
-- it from a deposit to a full price does not bend it.

-- ------------------------------------------------- 1: what is due up front --
-- The default is 'deposit' and not 'none', which matters more than it looks.
-- Before this migration, the amount WAS the switch: she typed £10 into her
-- settings and £10 was asked for. If the new column defaulted to 'none' then
-- the number she types would mean nothing until she also found a radio button
-- she has never seen - a deposit silently not taken, which is worse than no
-- deposit feature at all. So 'deposit' keeps the old rule exactly (an amount
-- of zero asks for nothing), 'full' is the new behaviour, and 'none' is her
-- explicit "stop asking, but keep my number".
alter table tenant add column if not exists pay_mode text not null default 'deposit'
  check (pay_mode in ('none', 'deposit', 'full'));

-- What was actually asked for, snapshotted onto the booking beside the amount,
-- because she may switch from deposits to full payment next month and the
-- email already sent has to stay true.
alter table booking add column if not exists pay_kind text not null default 'none'
  check (pay_kind in ('none', 'deposit', 'full'));

-- Replaces 017's version. Same trigger, same timing, one more decision: the
-- whole price when she asks for the whole price.
create or replace function take_deposit()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_mode text; v_want int; v_price int; v_pro boolean;
begin
  select t.pay_mode, t.deposit_pence, is_pro(t.plan)
    into v_mode, v_want, v_pro
    from tenant t where t.id = new.tenant_id;
  select s.price_pence into v_price from service s where s.id = new.service_id;
  v_price := coalesce(v_price, 0);

  if not coalesce(v_pro, false) or coalesce(v_mode, 'none') = 'none' then
    new.deposit_pence := 0;
    new.pay_kind := 'none';
    return new;
  end if;

  if v_mode = 'full' then
    new.deposit_pence := v_price;
    -- A £0 treatment asks for nothing, and asking for nothing is not a
    -- payment: it is somebody turning up to a free patch test.
    new.pay_kind := case when v_price > 0 then 'full' else 'none' end;
    return new;
  end if;

  -- Never more than the treatment costs, which also means a free patch test
  -- asks for nothing. Being charged a £10 deposit on a £0 appointment is the
  -- kind of thing that gets a screenshot.
  new.deposit_pence := least(coalesce(v_want, 0), v_price);
  -- A "deposit" equal to the whole price is a full payment, whatever the
  -- setting is called, and the email should say so.
  new.pay_kind := case
    when new.deposit_pence <= 0      then 'none'
    when new.deposit_pence >= v_price then 'full'
    else 'deposit' end;
  return new;
end $$;

-- --------------------------------------- 2: how long she will hold a slot --
-- Her cancellation window, seeded from her trade rather than from one number
-- for everybody. The shape of the work decides it: what it costs her to lose
-- the slot, and how likely she is to refill it.
--
-- These are HOURS, and deliberately shorter than a first guess suggests. A
-- window longer than the time people book ahead means the client literally
-- cannot cancel - she rings instead, or she does not turn up, and a no-show
-- is the thing the window exists to prevent.
create or replace function trade_cancel_hours(p_trade text)
returns int language sql immutable set search_path = public as $$
  select case p_trade
    -- Twenty minutes, walk-in trade, refilled the same morning. Three days
    -- of notice for a skin fade would only ever be ignored.
    when 'barber'  then 4
    -- An hour or two, and a waiting list that can take it.
    when 'nails'   then 24
    when 'lashes'  then 24
    when 'brows'   then 24
    when 'waxing'  then 24
    when 'massage' then 24
    when 'tanning' then 24
    -- Half a day of her time, and colour mixed or ordered for one head.
    when 'hair'    then 48
    when 'skin'    then 48
    -- The two where a cancellation is genuinely expensive: three hours and
    -- £250, or a wedding morning she turned other work away for.
    when 'pmu'     then 168
    when 'makeup'  then 168
    else 24
  end;
$$;

-- --------------------------------------------- 3: fourteen days of Pro+ --
-- Every new studio starts on Pro+ rather than on Free, so that what she
-- loses on day fifteen is a thing she has used rather than a list she has
-- read. Recorded as a real plan with a real end date, which means the hourly
-- sweep in expire_plans() already puts her on Free when it runs out: no new
-- machinery, and nothing to go wrong separately from billing.
alter table tenant add column if not exists trial_until timestamptz;

-- Why it ended, for the sentence the dashboard shows. A lapsed trial and a
-- lapsed card are not the same news.
-- stable, not immutable: it reads now(), and an immutable function that does
-- that invites the planner to fold one row's answer onto every other row.
create or replace function plan_state(p_plan text, p_until timestamptz,
                                      p_trial timestamptz, p_sub text)
returns text language sql stable set search_path = public as $$
  select case
    when p_sub is not null                                    then 'paying'
    when p_trial is not null and p_until is not null
         and p_until > now()                                  then 'trialing'
    when p_trial is not null and p_plan = 'free'              then 'trial_over'
    when p_plan = 'free'                                      then 'free'
    else 'paying'
  end;
$$;

-- ---------------------------------------------------- create_studio, again --
-- Three new things at signup: the trial, the cancellation window her trade
-- implies, and nothing else. Patched in place so the parts this migration has
-- no opinion about cannot drift.
do $start$
declare src text; out_src text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_studio';

  out_src := replace(src,
    'insert into tenant (owner, slug, display_name, trade, timezone)' || chr(10) ||
    '  values (v_uid, p_slug, trim(p_name), p_trade, p_tz)',
    'insert into tenant (owner, slug, display_name, trade, timezone,' || chr(10) ||
    '                      cancel_hours, plan, plan_until, trial_until)' || chr(10) ||
    '  values (v_uid, p_slug, trim(p_name), p_trade, p_tz,' || chr(10) ||
    '          trade_cancel_hours(p_trade), ''pro_plus'',' || chr(10) ||
    '          now() + interval ''14 days'', now() + interval ''14 days'')');

  if out_src = src then
    raise exception '020: the tenant insert in create_studio is not where it was.';
  end if;
  execute out_src;
end $start$;

-- ------------------------------------------------------ 4: the three emails --
-- "Booking confirmed — paid" cannot be sent at the moment of booking, because
-- at that moment nothing has been paid: the money goes to her bank, and only
-- she can see it arrive. Sending it anyway would be the one dishonest email in
-- the product.
--
-- So the confirmation says what is DUE, in her client's words rather than in
-- ours, and a second email goes when she marks it received. Three states, and
-- all three are true when they are sent:
--
--   at booking      ... pay in person        (nothing is due)
--                   ... £10 deposit to pay
--                   ... £18 to pay
--   when she marks  ... deposit received
--                   ... paid in full
create or replace function pay_subject(p_kind text, p_pence int, p_studio text)
returns text language sql immutable set search_path = public as $$
  select 'Booking confirmed with ' || p_studio || ' — ' || case
    when p_kind = 'none'    then 'pay in person'
    when p_kind = 'full'    then '£' || trim(to_char(p_pence / 100.0, 'FM999990.00')) || ' to pay'
    else '£' || trim(to_char(p_pence / 100.0, 'FM999990.00')) || ' deposit to pay'
  end;
$$;

-- deposit_lines, widened: the same block of her payment details, introduced by
-- a sentence that matches what is actually being asked for.
create or replace function deposit_lines(p_tenant uuid, p_pence int, p_ref text,
                                         p_kind text default 'deposit')
returns text language plpgsql stable security definer set search_path = public as $$
declare t tenant; v text; v_amt text;
begin
  if coalesce(p_pence, 0) = 0 or coalesce(p_kind, 'none') = 'none' then return ''; end if;
  select * into t from tenant where id = p_tenant;
  v_amt := '£' || trim(to_char(p_pence / 100.0, 'FM999990.00'));

  v := E'\n--\n' || case
         when p_kind = 'full' then v_amt || ' is due for this appointment.'
         else 'A deposit of ' || v_amt || ' holds this appointment.'
       end || E'\n';

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
  v := v || E'\nShe will confirm once it reaches her.\n';
  return v;
end $$;

-- The confirmation, with a subject that says which of the three this is.
-- Patched in place: queue_mail_for carries the whole booking email and five
-- migrations have shaped it.
do $mail$
declare src text; out_src text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'queue_mail_for';

  out_src := replace(src,
    'v_dep := deposit_lines(t.id, b.deposit_pence, b.ref);',
    'v_dep := deposit_lines(t.id, b.deposit_pence, b.ref, b.pay_kind);');
  if out_src = src then
    raise exception '020: the deposit block in queue_mail_for is not where it was.';
  end if;
  src := out_src;

  out_src := replace(src,
    '''Your appointment with '' || t.display_name || '' is booked'',',
    'pay_subject(b.pay_kind, b.deposit_pence, t.display_name),');
  if out_src = src then
    raise exception '020: the client subject in queue_mail_for is not where it was.';
  end if;
  execute out_src;
end $mail$;

-- And the receipt, when she says it arrived. This is the email the client is
-- actually waiting for, and before now it did not exist: she marked it paid
-- and nobody told the person who paid.
create or replace function set_deposit_paid(p_booking uuid, p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b booking; t tenant; s service; v_when timestamptz; v_amt text;
begin
  select bk.* into b from booking bk join tenant tt on tt.id = bk.tenant_id
   where bk.id = p_booking and tt.owner = auth.uid();
  if b.id is null then
    raise exception 'That booking is not yours.' using errcode = 'P0001';
  end if;
  v_when := case when p_on then now() else null end;
  update booking set deposit_paid_at = v_when where id = b.id;

  -- A receipt goes out once per booking, and the test for that is whether one
  -- has already gone out - not whether the column was null a moment ago. She
  -- can tick, untick and tick again while finding the right row; the person
  -- who paid should hear about it exactly once either way.
  if p_on and coalesce(b.deposit_pence, 0) > 0
     and not exists (select 1 from mail_outbox m
                      where m.booking_id = b.id and m.kind = 'client_paid') then
    select * into t from tenant  where id = b.tenant_id;
    select * into s from service where id = b.service_id;
    v_amt := '£' || trim(to_char(b.deposit_pence / 100.0, 'FM999990.00'));
    insert into mail_outbox (booking_id, kind, to_email, to_name, subject, body)
    values (b.id, 'client_paid', b.client_email, b.client_name,
      case when b.pay_kind = 'full'
           then 'Paid in full — your appointment with ' || t.display_name || ' is set'
           else 'Deposit received — your appointment with ' || t.display_name || ' is held'
      end,
      'Hi ' || split_part(b.client_name, ' ', 1) || E',\n\n' ||
      case when b.pay_kind = 'full'
           then v_amt || ' received, with thanks. Nothing else to pay.'
           else v_amt || ' received, with thanks. The rest is due on the day.'
      end || E'\n\n' ||
      s.name || E'\n' ||
      to_char(b.starts_at at time zone t.timezone, 'FMDay FMDD FMMonth') || ' at ' ||
      to_char(b.starts_at at time zone t.timezone, 'HH24:MI') || E'\n' ||
      'Reference ' || b.ref || E'\n\n' ||
      'See you then.');
  end if;

  return jsonb_build_object('booking', b.id, 'paid', p_on, 'at', v_when);
end $$;

-- The kind has to be allowed through the outbox's own check.
do $kinds$
declare src text; out_src text;
begin
  select pg_get_constraintdef(oid) into src from pg_constraint
   where conname = 'mail_outbox_kind_check';
  if src is null then
    raise exception '020: mail_outbox has no kind check to widen.';
  end if;
  if position('client_paid' in src) = 0 then
    out_src := replace(src, '''client_waitlist''', '''client_waitlist'',''client_paid''');
    if out_src = src then
      raise exception '020: could not widen the mail kinds; the list has moved.';
    end if;
    execute 'alter table mail_outbox drop constraint mail_outbox_kind_check';
    execute 'alter table mail_outbox add constraint mail_outbox_kind_check ' || out_src;
  end if;
end $kinds$;

-- ---------------------------------------------------- what the pages read --
-- The public page needs to know whether it is asking for a deposit, the whole
-- price, or nothing, so it can say so before she fills the form in.
do $reads$
declare f text; src text; out_src text;
begin
  foreach f in array array['my_studio', 'get_studio'] loop
    select pg_get_functiondef(p.oid) into src
      from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
     where n2.nspname = 'public' and p.proname = f;
    out_src := replace(src,
      '''deposit_pence'', case when is_pro(t.plan) then t.deposit_pence else 0 end,',
      '''deposit_pence'', case when is_pro(t.plan) then t.deposit_pence else 0 end,' || chr(10) ||
      '    ''pay_mode'', case when is_pro(t.plan) then t.pay_mode else ''none'' end,');
    if out_src = src then
      -- my_studio spells it without the gate; try that shape too
      out_src := replace(src, '''deposit_pence'', t.deposit_pence,',
        '''deposit_pence'', t.deposit_pence, ''pay_mode'', t.pay_mode,' || chr(10) ||
        '    ''trial_until'', t.trial_until,' || chr(10) ||
        '    ''plan_state'', plan_state(t.plan, t.plan_until, t.trial_until, t.stripe_subscription_id),');
    end if;
    if out_src = src then
      raise exception '020: the deposit key in % is not where it was.', f;
    end if;
    execute out_src;
  end loop;
end $reads$;

-- ---------------------------------------------------------------- grants --
revoke execute on function trade_cancel_hours(text)                  from public;
revoke execute on function plan_state(text, timestamptz, timestamptz, text) from public;
revoke execute on function pay_subject(text, int, text)              from public;
revoke execute on function deposit_lines(uuid, int, text, text)      from public;
grant  execute on function trade_cancel_hours(text) to anon, authenticated;
grant  execute on function plan_state(text, timestamptz, timestamptz, text) to authenticated;

-- The client's own read needs the kind too, so the manage page can say
-- "paid in full" rather than "deposit paid" about the same number.
do $gb$
declare src text; out_src text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_booking';
  -- Anchored on one line, not two. A two-line anchor also depends on the
  -- newline and the exact indent surviving every hop between this file and
  -- pg_proc - including a 4,000-line paste through a browser SQL editor,
  -- which is where it first broke. Every other patch in 019 and 020 anchors
  -- on a single line; this one was the odd one out.
  out_src := replace(src,
    '''pence'', b.deposit_pence,',
    '''pence'', b.deposit_pence, ''kind'', b.pay_kind,');
  if out_src = src then
    raise exception '020: the deposit object in get_booking is not where it was.';
  end if;
  execute out_src;
end $gb$;

-- 017's three-argument deposit_lines is now unreachable: the four-argument one
-- took over every call site. Leaving it would leave a second copy of her bank
-- details behind a function nobody maintains.
drop function if exists deposit_lines(uuid, int, text);

-- Studios that signed up before this migration kept 003's flat 24 hours. Move
-- only the ones still sitting on that default, so a window she chose herself
-- survives - the same rule 019 used for her hours.
update tenant t set cancel_hours = trade_cancel_hours(t.trade)
 where t.cancel_hours = 24 and trade_cancel_hours(t.trade) <> 24;

-- ------------------------------------- the hole this migration opened --
-- 017 made one state impossible: money asked for with nowhere to send it.
-- It enforced that by exempting deposit_pence = 0, which was the same thing
-- as "asks for nothing" right up until pay_mode arrived. A studio set to
-- 'full' with deposit_pence still 0 now asks for the whole price, and under
-- 017's wording it could do that with no bank details at all - her client
-- told £18 is due and not told where to put it. That is precisely the state
-- the constraint exists to prevent, so the exemption has to learn about the
-- mode.
--
-- 'deposit' with no amount is left exempt on purpose: it asks for nothing,
-- and making her fill in her sort code before she has typed an amount is
-- friction in defence of nothing.
do $route$
declare src text; out_src text;
begin
  select pg_get_constraintdef(oid) into src from pg_constraint
   where conname = 'tenant_deposit_route_check';
  if src is null then
    raise exception '020: tenant_deposit_route_check has gone.';
  end if;
  out_src := replace(src, '(deposit_pence = 0)',
                          '(deposit_pence = 0 AND pay_mode <> ''full''::text)');
  if out_src = src then
    raise exception '020: the exemption in tenant_deposit_route_check has moved.';
  end if;
  execute 'alter table tenant drop constraint tenant_deposit_route_check';
  execute 'alter table tenant add constraint tenant_deposit_route_check ' || out_src;
end $route$;

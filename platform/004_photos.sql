-- Peony — a photograph against each treatment
--
-- "Your photos, your work" is most of the pitch. It is also the thing that
-- makes a client book the right set: she books what she can see, so she turns
-- up wanting the thing you quoted her for.

alter table service add column photo_path text;

-- Where the file lives in storage. One folder per studio so a storage policy
-- can decide ownership from the path alone.
--   <tenant_id>/<service_id>.jpg
create or replace function photo_prefix()
returns text language sql stable security definer set search_path = public as $$
  select t.id::text from tenant t where t.owner = auth.uid();
$$;

-- get_studio and my_studio must hand the path out or the pages cannot show it
create or replace function get_studio(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'timezone', t.timezone, 'plan', t.plan,
    'notice_hours', t.notice_hours,
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

create or replace function my_studio()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'name', t.display_name, 'tagline', t.tagline,
    'trade', t.trade, 'plan', t.plan, 'timezone', t.timezone,
    'notice_hours', t.notice_hours, 'slot_step_min', t.slot_step_min,
    'cancel_hours', t.cancel_hours,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'name', s.name, 'price_pence', s.price_pence,
               'duration_min', s.duration_min, 'active', s.active, 'sort', s.sort,
               'photo_path', s.photo_path)
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
               'status', b.status, 'cancelled_by', b.cancelled_by,
               'service', sv.name, 'price_pence', sv.price_pence)
             order by b.starts_at)
        from booking b join service sv on sv.id = b.service_id
       where b.tenant_id = t.id and b.starts_at > now() - interval '30 days'), '[]'::jsonb)
  )
  from tenant t where t.owner = auth.uid();
$$;

grant execute on function photo_prefix() to authenticated;

-- ---------------------------------------------------------------- storage --
-- Supabase only. Guarded so this same file still applies to a bare Postgres,
-- which is what the test harness runs against.
do $$
begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    raise notice 'no storage schema: skipping bucket and policies (not Supabase)';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('treatments', 'treatments', true)
  on conflict (id) do nothing;

  -- Anyone may look: these are the photographs on a public booking page.
  if not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='treatment photos are public') then
    execute $p$
      create policy "treatment photos are public" on storage.objects
        for select using (bucket_id = 'treatments')
    $p$;
  end if;

  -- Only the studio whose id is the first folder may write there. This is why
  -- the path starts with the tenant id rather than anything she chooses.
  if not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='a studio writes only its own folder') then
    execute $p$
      create policy "a studio writes only its own folder" on storage.objects
        for all to authenticated
        using (bucket_id = 'treatments'
               and (storage.foldername(name))[1] in
                   (select t.id::text from public.tenant t where t.owner = auth.uid()))
        with check (bucket_id = 'treatments'
               and (storage.foldername(name))[1] in
                   (select t.id::text from public.tenant t where t.owner = auth.uid()))
    $p$;
  end if;
end $$;

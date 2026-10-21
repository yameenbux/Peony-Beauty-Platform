#!/bin/bash
# The hole 029 closes: anon could DELETE every booking on the platform.
#
# `slot_taken` is a view over `booking` giving the booking page the three
# columns it needs - tenant_id, starts_at, ends_at - and none of the ones that
# say who. It is `security_invoker = false` on purpose, because anon cannot
# read `booking` at all, so the view has to run as its owner for the read to
# work.
#
# That is correct. What is not is the grant. A plain select of three columns
# from one table is AUTO-UPDATABLE, and Supabase's default ACL hands a new view
# to anon the same way it hands over a new table - so the same grant that made
# the read work made DELETE work too, executing as the owner, which bypasses
# the RLS on `booking` that is the only thing protecting it.
#
# 001 says `grant select on slot_taken to anon`, which reads like the whole
# story. It is a no-op on top of a grant that was already there.
#
# So, like test_tenant_read.sh and test_lockdown.sh, this file installs that
# default ACL before applying anything. On a bare Postgres a new view is
# granted nothing, and this test would pass on a missing GRANT rather than on
# the fix - the same way the bug hid from every suite we had.
#
# The first block asserts the hole is OPEN. If it ever starts failing, this
# test has stopped testing anything and must be read before it is trusted.
#
#   ./test_slot_taken.sh      # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-slottaken-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55489 PGUSER=test PGDATABASE=bookedin
U1=11111111-1111-1111-1111-111111111111
U2=99999999-9999-9999-9999-999999999999

rm -rf "$DIR"; mkdir -p "$DIR/sock"
initdb -D "$DIR/data" -U test --auth=trust -E UTF8 > "$DIR/initdb.log" 2>&1 || exit 1
pg_ctl -D "$DIR/data" -o "-p $PGPORT -k $DIR/sock -c listen_addresses=''" \
       -l "$DIR/pg.log" -w start > /dev/null || exit 1
trap 'pg_ctl -D "$DIR/data" -m immediate stop >/dev/null 2>&1' EXIT
createdb bookedin
psql -q -v ON_ERROR_STOP=1 -c "create schema auth" \
  -c "create table auth.users (id uuid primary key, email text)" \
  -c "create function auth.uid() returns uuid language sql stable as
      \$\$ select nullif(current_setting('test.uid', true), '')::uuid \$\$" \
  -c "create role anon" -c "create role authenticated" -c "create role service_role" \
  -c "grant usage on schema public to anon, authenticated" || exit 1

# The half of the bug that is the environment rather than the code.
psql -q -v ON_ERROR_STOP=1 -c "alter default privileges in schema public
       grant all on tables to anon, authenticated, service_role" \
  -c "alter default privileges in schema public
       grant execute on functions to anon, authenticated, service_role" || exit 1

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
anon()  { psql -qtA -c "set role anon; $1" 2>&1 | tr -d '\n'; }
want()  { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has()   { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

APPLY() {
  for f in "$@"; do
    psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
      || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
  done
}
APPLY 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
      008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
      014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
      020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease \
      025_paylink 026_trigger_privilege 027_patch_test_seed 028_trade_palette
echo "ok   001-028 apply"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')" >/dev/null
as $U1 "select create_studio('studio-mila','Studio Mila','nails')" > /dev/null
as $U2 "select create_studio('nails-by-jo','Nails by Jo','nails')" > /dev/null
# nails needs no patch test, so a booking here is one call rather than two.
as $U1 "update tenant set notice_hours=0 where slug='studio-mila'" > /dev/null
as $U2 "update tenant set notice_hours=0 where slug='nails-by-jo'" > /dev/null
S1=$(as $U1 "select id from service where tenant_id=(select id from tenant where slug='studio-mila') limit 1")
S2=$(as $U2 "select id from service where tenant_id=(select id from tenant where slug='nails-by-jo') limit 1")
T1=$(as $U1 "select min(f) from free_slots('studio-mila','$S1'::uuid,
              current_date, current_date + 14) f")
T2=$(as $U2 "select min(f) from free_slots('nails-by-jo','$S2'::uuid,
              current_date, current_date + 14) f")
as $U1 "select book('studio-mila','$S1'::uuid,'$T1'::timestamptz,'Her Client','c1@x.com')" >/dev/null
as $U2 "select book('nails-by-jo','$S2'::uuid,'$T2'::timestamptz,'Other Client','c2@x.com')" >/dev/null
want "two studios, one booking each" "2" \
     "$(psql -qtA -c "select count(*) from booking where status='confirmed'" | tr -d '\n')"

echo
echo "-- before 029: the read is meant to work, and it does --"
want "anon can see that a time is taken" "2" "$(anon "select count(*) from slot_taken")"
want "and gets no name with it" "tenant_id, starts_at, ends_at" \
     "$(psql -qtA -c "select string_agg(column_name, ', ' order by ordinal_position)
          from information_schema.columns
         where table_schema='public' and table_name='slot_taken'" | tr -d '\n')"

echo
echo "-- before 029: AND SO DOES THE DELETE. This block must pass. --"
want "anon holds DELETE on the view" "t" \
     "$(psql -qtA -c "select has_table_privilege('anon','public.slot_taken','DELETE')" | tr -d '\n')"
# The whole platform's diary, with the key that ships in the browser.
anon "delete from slot_taken" > /dev/null
GONE=$(psql -qtA -c "select count(*) from booking where status='confirmed'" | tr -d '\n')
want "one unfiltered DELETE emptied every studio's diary" "0" "$GONE"
[ "$GONE" = "0" ] && echo "     ^ that is the bug, reproduced, on an unpatched schema"

echo
echo "-- 029 --"
# Put the bookings back so the after-state is tested on real rows.
as $U1 "select book('studio-mila','$S1'::uuid,'$T1'::timestamptz,'Her Client','c1@x.com')" >/dev/null
as $U2 "select book('nails-by-jo','$S2'::uuid,'$T2'::timestamptz,'Other Client','c2@x.com')" >/dev/null
APPLY 029_slot_taken_readonly
echo "ok   029 applies"

want "anon no longer holds DELETE" "f" \
     "$(psql -qtA -c "select has_table_privilege('anon','public.slot_taken','DELETE')" | tr -d '\n')"
has "a DELETE is now refused outright" "permission denied" "$(anon "delete from slot_taken")"
has "so is an UPDATE" "permission denied" \
    "$(anon "update slot_taken set starts_at = now()")"
has "so is an INSERT" "permission denied" \
    "$(anon "insert into slot_taken (tenant_id, starts_at, ends_at)
             values (gen_random_uuid(), now(), now())")"
want "and both diaries are still there" "2" \
     "$(psql -qtA -c "select count(*) from booking where status='confirmed'" | tr -d '\n')"

echo
echo "-- and the read it exists for still works --"
want "anon can still see which times are gone" "2" "$(anon "select count(*) from slot_taken")"
want "a studio can still see them too" "2" "$(as $U1 "select count(*) from slot_taken")"
want "free_slots still skips a taken time" "f" \
     "$(as $U1 "select exists (select 1 from free_slots('studio-mila','$S1'::uuid,
                  current_date, current_date + 14) f where f = '$T1'::timestamptz)")"

echo
echo "-- the standing assertion, so it cannot come back --"
# This is the point of 029 over a one-line revoke: 023 and 024 swept tables and
# functions and never looked at a view, which is exactly how this survived them.
psql -q -c "grant delete on slot_taken to anon" > /dev/null
want "lockdown() repairs a re-granted write" "31" "$(psql -qtA -c "select lockdown()" | tr -d '\n')"
want "and the grant is gone again" "f" \
     "$(psql -qtA -c "select has_table_privilege('anon','public.slot_taken','DELETE')" | tr -d '\n')"

# A view that is writable and NOT in writable_views has to stop lockdown dead,
# because the next one will not be slot_taken.
psql -q -c "create view booking_peek as select * from booking" > /dev/null 2>&1
psql -q -c "grant select, delete on booking_peek to anon" > /dev/null 2>&1
want "a new writable view is swept too" "31" "$(psql -qtA -c "select lockdown()" | tr -d '\n')"
want "and it is read-only afterwards" "f" \
     "$(psql -qtA -c "select has_table_privilege('anon','public.booking_peek','DELETE')" | tr -d '\n')"

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

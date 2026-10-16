#!/bin/bash
# pgcrypto, where Supabase actually keeps it.
#
# Every other suite installs pgcrypto into public, because that is what
# "create extension pgcrypto" does on a bare Postgres - and that is the one
# arrangement in which the bug cannot happen. Supabase ships pgcrypto already
# installed into the extensions schema, so 001's create is a no-op, and a
# function pinned to "search_path = public" cannot see gen_random_bytes.
#
# Both ways of making a booking build their reference with it. This file puts
# pgcrypto where Supabase puts it and then books, from both sides.
set -u
DIR=${TMPDIR:-/tmp}/bookedin-extpath-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55466 PGUSER=test PGDATABASE=bookedin
U1=11111111-1111-1111-1111-111111111111

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
  -c "create role anon" -c "create role authenticated" -c "create role service_role" || exit 1

# THE POINT OF THIS FILE: pgcrypto where Supabase keeps it, not where a bare
# Postgres would put it.
psql -q -v ON_ERROR_STOP=1 \
  -c "create schema extensions" \
  -c "create extension pgcrypto with schema extensions" || exit 1

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
         014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
         020_pay 021_lockdown 022_pgcrypto_path; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done
chk "pgcrypto is NOT in public, as on Supabase" "extensions" \
    "$(plain "select n.nspname from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto'")"

psql -q -c "insert into auth.users values ('$U1','jay@example.com')" > /dev/null
as $U1 "select create_studio('fade-room','The Fade Room','barber')" > /dev/null
T1=$(plain "select id from tenant where slug='fade-room'")
FADE=$(plain "select id from service where tenant_id='$T1' and name='Skin fade'")
SLOT=$(plain "select min(at) from free_slots('fade-room','$FADE'::uuid, current_date, current_date+14) as f(at)")

echo
echo "-- her client books, which is the path that was dead --"
REF=$(plain "select ref from book('fade-room','$FADE','$SLOT'::timestamptz,'Dan Okafor','dan@example.com')")
chk "a reference is generated"        "8"  "${#REF}"
chk "and the booking is really there" "1"  "$(plain "select count(*) from booking where ref='$REF'")"

echo
echo "-- and she books one in herself, the other dead path --"
SLOT2=$(plain "select min(at) from free_slots('fade-room','$FADE'::uuid, current_date, current_date+14) as f(at)")
REF2=$(as $U1 "select ref from studio_book('$FADE','$SLOT2'::timestamptz,'Walk In','walkin@example.com')")
chk "her own booking gets a reference" "8" "${#REF2}"

echo
echo "-- the ip salt, which is generated at migration time --"
chk "a salt was stored" "64" \
    "$(plain "select length(value) from platform_setting where key='ip_salt'")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

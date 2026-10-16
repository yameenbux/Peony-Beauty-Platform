#!/bin/bash
# The hole 009 could not close, and the environment that hid it.
#
# A bare Postgres grants a new function nothing. Supabase installs a default
# ACL on the public schema that hands every new function to anon and
# authenticated as it is created - so 009's revoke, which ran at migration 9
# and named PUBLIC, missed both roles and everything built after it.
#
# This file installs that same default ACL before applying anything, so the
# suite finally runs in the shape the real database is in.
set -u
DIR=${TMPDIR:-/tmp}/bookedin-lockdown-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55473 PGUSER=test PGDATABASE=bookedin

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
  || exit 1

# THE POINT OF THIS FILE: Supabase's default ACL, reproduced.
psql -q -v ON_ERROR_STOP=1 -c "alter default privileges in schema public
  grant execute on functions to anon, authenticated, service_role" || exit 1

fail=0
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }

for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
         014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector 020_pay; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done

echo "-- 1. the hole, before 021 closes it --"
# These four are the ones that matter. If this block ever reads 'f', the
# default ACL has changed and this test is no longer testing anything.
for fn in set_plan deposit_lines client_record next_mail; do
  chk "  anon can reach $fn (the bug)" "t" \
      "$(plain "select has_function_privilege('anon', p.oid, 'EXECUTE')
                from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='$fn' limit 1")"
done

echo
echo "-- 2. apply 021 --"
psql -q -v ON_ERROR_STOP=1 -f "$HERE/021_lockdown.sql" > "$DIR/021.log" 2>&1 \
  || { echo "FAILED applying 021"; tail -8 "$DIR/021.log"; exit 1; }
echo "ok   021 applies, and its own anon sweep passed"

echo
echo "-- 3. the hole is shut --"
for fn in set_plan deposit_lines client_record next_mail queue_mail_for expire_plans \
          take_deposit queue_reminders upsert_client setting; do
  chk "  anon cannot reach $fn" "f" \
      "$(plain "select has_function_privilege('anon', p.oid, 'EXECUTE')
                from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='$fn' limit 1")"
done
chk "nor can a signed-in studio reach set_plan" "f" \
    "$(plain "select has_function_privilege('authenticated', p.oid, 'EXECUTE')
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='set_plan' limit 1")"

echo
echo "-- 4. and the pages still work --"
for fn in get_studio free_slots get_booking cancel_booking slug_available; do
  chk "  her client can still reach $fn" "t" \
      "$(plain "select has_function_privilege('anon', p.oid, 'EXECUTE')
                from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='$fn' limit 1")"
done
for fn in my_studio create_studio studio_cancel set_deposit_paid client_record; do
  chk "  she can still reach $fn" "t" \
      "$(plain "select has_function_privilege('authenticated', p.oid, 'EXECUTE')
                from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='$fn' limit 1")"
done
chk "the booking function anon reaches is the eight-argument one" "1" \
    "$(plain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='book'
                and has_function_privilege('anon', p.oid, 'EXECUTE')
                and pronargs = 8")"

echo
echo "-- 5. a function added later, and the sweep that catches it --"
# Postgres hands EXECUTE on a new function to PUBLIC, and every role is in
# PUBLIC. No default-privilege setting prevents it (four orderings tried, all
# anon=t) and an event trigger needs superuser, which Supabase's postgres role
# is not. So the protection is lockdown(), called at the end of any migration
# that adds a function - and what has to hold is that it repairs the exposure.
psql -q -c "create function _later() returns int language sql as \$\$ select 1 \$\$" >/dev/null
chk "a new function IS exposed, as Postgres does by default" "t" \
    "$(plain "select has_function_privilege('anon', '_later()'::regprocedure, 'EXECUTE')")"
psql -q -c "select lockdown()" > /dev/null
chk "and lockdown() shuts it again" "f" \
    "$(plain "select has_function_privilege('anon', '_later()'::regprocedure, 'EXECUTE')")"

# Granted by hand, directly to anon: the sweep must take it back rather than
# leave it, because this is what a careless later migration looks like.
psql -q -c "grant execute on function _later() to anon" >/dev/null
chk "a hand-granted function is exposed" "t" \
    "$(plain "select has_function_privilege('anon', '_later()'::regprocedure, 'EXECUTE')")"
psql -q -c "select lockdown()" > /dev/null
chk "and the sweep takes it back" "f" \
    "$(plain "select has_function_privilege('anon', '_later()'::regprocedure, 'EXECUTE')")"
chk "while the real entry points survive the sweep" "t" \
    "$(plain "select has_function_privilege('anon', 'get_studio(text)'::regprocedure, 'EXECUTE')")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

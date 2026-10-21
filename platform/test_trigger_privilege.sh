#!/bin/bash
# "permission denied for function guess_patch_hours", which is what a studio
# saw the first time she edited her treatments on the live site.
#
# 021's sweep is right to revoke guess_patch_hours: it is a lookup helper and
# nothing in a browser should call it. What it could not see is that
# suggest_patch_hours - a SECURITY INVOKER trigger on `service` - calls it in
# its body, so the update runs as `authenticated` and needs HER to hold
# EXECUTE on a function she must not hold.
#
# It hid because create_studio() is SECURITY DEFINER: the seeding insert and
# every trigger it fires run as the owner, so a brand new studio looks fine.
# It breaks on the first edit, in production.
#
#   ./test_trigger_privilege.sh      # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-trigpriv-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55493 PGUSER=test PGDATABASE=bookedin
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
  -c "create role anon" -c "create role authenticated" -c "create role service_role" \
  -c "grant usage on schema public to anon, authenticated" || exit 1
psql -q -v ON_ERROR_STOP=1 -c "alter default privileges in schema public
       grant all on tables to anon, authenticated, service_role" \
  -c "alter default privileges in schema public
       grant execute on functions to anon, authenticated, service_role" || exit 1

for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
         014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
         020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease \
         025_paylink; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done
echo "ok   001-025 apply"

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
she()   { psql -qtA -c "set test.uid='$U1'; set role authenticated; $1" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()  { case "$3" in *"$2"*) echo "FAIL $1 -> still '$2': $3"; fail=1;; *) echo "ok   $1";; esac; }

psql -q -c "insert into auth.users values ('$U1','ellie@example.com')" >/dev/null
as $U1 "select create_studio('aaminahs-lashes','Aaminah''s Lashes','lashes')" > /dev/null
chk "the wizard seeds her treatments (create_studio is definer, so this works)" "5" \
    "$(plain "select count(*) from service")"

echo
echo "-- 1. the bug, before 026 closes it --"
# Both triggers are INSERT only - 014 and 012 say so, so that clearing the
# field keeps it cleared - and the helper only runs when the column is still
# null. So a rename never reaches it, and ADDING a treatment always does.
# That is exactly what the dashboard does: "Save treatments" upserts, and an
# upsert inserts.
has "  adding a treatment is refused" "permission denied for function guess_patch_hours" \
    "$(she "insert into service (tenant_id, name, price_pence, duration_min)
            select id, 'Mega volume', 6500, 150 from tenant")"
she "update service set name = 'Classic set' where name = 'Classic full set'" >/dev/null
chk "  renaming one is fine, because the trigger is insert-only" "1" \
    "$(plain "select count(*) from service where name = 'Classic set'")"

echo
echo "-- 2. apply 026 --"
psql -q -v ON_ERROR_STOP=1 -f "$HERE/026_trigger_privilege.sql" > "$DIR/026.log" 2>&1 \
  || { echo "FAILED applying 026"; tail -8 "$DIR/026.log"; exit 1; }
echo "ok   026 applies, and lockdown()'s assertions passed"
psql -q -v ON_ERROR_STOP=1 -f "$HERE/026_trigger_privilege.sql" > "$DIR/026.again.log" 2>&1 \
  && echo "ok     and applies a second time too" \
  || { echo "FAIL   026 is not re-runnable"; tail -5 "$DIR/026.again.log"; fail=1; }

echo
echo "-- 3. she can edit her own treatments --"
no  "adding a treatment no longer complains" "permission denied" \
    "$(she "insert into service (tenant_id, name, price_pence, duration_min)
            select id, 'Mega volume', 6500, 150 from tenant")"
chk "  and it is actually saved" "1" \
    "$(plain "select count(*) from service where name = 'Mega volume'")"
chk "  and the trigger still did its job: a lash set needs a patch test" "48" \
    "$(plain "select patch_test_hours from service where name = 'Mega volume'")"
chk "  rebook weeks were guessed too (the other invoker trigger)" "t" \
    "$(plain "select rebook_weeks is not null from service where name = 'Mega volume'")"

echo
echo "-- 4. and the helper is STILL not hers to call --"
# The fix was the trigger, not the grant. Granting guess_patch_hours to
# authenticated would also have worked, and would have put a private helper on
# the public API to serve what is internal bookkeeping.
for fn in guess_patch_hours guess_rebook_weeks; do
  chk "  authenticated cannot call $fn" "f" \
      "$(plain "select has_function_privilege('authenticated', p.oid, 'EXECUTE')
                from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='$fn' limit 1")"
  chk "  nor can anon" "f" \
      "$(plain "select has_function_privilege('anon', p.oid, 'EXECUTE')
                from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='$fn' limit 1")"
done

echo
echo "-- 5. the standing assertion --"
psql -q -c "alter function suggest_patch_hours() security invoker" >/dev/null
has "lockdown() refuses while a trigger runs as the caller" "run as the caller" \
    "$(plain "select lockdown()")"
psql -q -c "alter function suggest_patch_hours() security definer" >/dev/null
chk "  and passes once it is put back" "31" "$(plain "select lockdown()")"
# A brand new invoker trigger is the general case, caught without anybody
# having thought of it in advance.
psql -q -c "create function _later_trg() returns trigger language plpgsql as
            \$\$ begin return new; end \$\$" \
     -c "create trigger _later_t before insert on service
         for each row execute function _later_trg()" >/dev/null
has "a NEW invoker trigger is caught too" "_later_trg" "$(plain "select lockdown()")"
psql -q -c "drop trigger _later_t on service" -c "drop function _later_trg()" >/dev/null
chk "  and the sweep is clean again" "31" "$(plain "select lockdown()")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

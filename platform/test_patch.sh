#!/bin/bash
# The patch test, which is the only thing in here that is not a convenience.
#
# If a client reacts and the studio cannot produce a dated record, the insurance
# that was meant to cover it may not. So the question these tests answer is not
# "does the feature work" but "can a stranger on her page book something that
# quietly voids her cover". The answer has to be no, on every path.
#
#   ./test_patch.sh          # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-patch-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55444 PGUSER=test PGDATABASE=bookedin
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
  -c "create role anon" -c "create role authenticated" || exit 1
for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand 014_patch; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 \
    || { echo "FAIL $f does not apply"; exit 1; }
done
echo "ok   the patch test migration applies"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')"
psql -q -c "grant usage on schema public to anon, authenticated" \
     -c "grant select, insert, update, delete on all tables in schema public to authenticated" \
     -c "grant select on all tables in schema public to anon" \
     -c "create role app_user" -c "grant authenticated to app_user" \
     -c "create role web_user" -c "grant anon to web_user" > /dev/null

fail=0
as()     { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain()  { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
asrole() { psql -qtA -c "set role $1; $2" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()  { case "$3" in *"$2"*) echo "FAIL $1 -> $3"; fail=1;; *) echo "ok   $1";; esac; }

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
as $U2 "select create_studio('nails-by-jo','Nails by Jo','nails')" > /dev/null
T=$(plain "select id from tenant where slug='studio-mila'")

echo
echo "-- it arrives already knowing which trades need one --"
chk "a lash set is set to 48 hours without her touching anything" "48" \
    "$(plain "select patch_test_hours from service where tenant_id='$T' and name ilike '%full set%' limit 1")"
chk "and a nail technician is asked for nothing" "0" \
    "$(plain "select count(*) from service s join tenant t on t.id=s.tenant_id
              where t.slug='nails-by-jo' and s.patch_test_hours is not null")"
chk "six months is the default life of one" "6" \
    "$(plain "select patch_valid_months from tenant where id='$T'")"

psql -q -c "update tenant set notice_hours=0 where id='$T'" \
     -c "delete from service where tenant_id='$T'" -c "delete from opening where tenant_id='$T'" \
     -c "insert into service (id,tenant_id,name,price_pence,duration_min,patch_test_hours)
         values ('44444444-4444-4444-4444-444444444444','$T','Russian full set',5500,30,48)" \
     -c "insert into service (id,tenant_id,name,price_pence,duration_min,records_patch_test)
         values ('55555555-5555-5555-5555-555555555555','$T','Patch test',0,10,true)" \
     -c "insert into service (id,tenant_id,name,price_pence,duration_min)
         values ('66666666-6666-6666-6666-666666666666','$T','Brow wax',2000,30)" \
     -c "insert into opening (tenant_id,weekday,starts,ends)
         select '$T', g, '00:00','23:59' from generate_series(0,6) g" > /dev/null
# Open round the clock and every treatment half an hour, so a test about patch
# testing never fails because an offset of N hours happened to land at tea time.
#
# 23:59, not 23:00. Starts are truncated to the hour, so the latest one an
# offset can produce is 23:00 - and a half-hour treatment then runs to 23:30,
# past a window that closes at 23:00. That made this file fail or pass
# depending on the hour of day it was run, which is worse than no test: today
# 10:00 UTC plus sixty hours is 23:00 in London, and it failed.
LASH=44444444-4444-4444-4444-444444444444
TEST=55555555-5555-5555-5555-555555555555
WAX=66666666-6666-6666-6666-666666666666
at() { echo "(date_trunc('hour', now()) + interval '$1 hours')"; }
bk() { plain "select ref from book('studio-mila','$1',$(at $2),'$3','$4')"; }

echo
echo "-- a stranger cannot book the thing that needs one --"
has "a lash set is refused with no test on record" "needs a patch test at least 48 hours" \
    "$(bk $LASH 200 'Ruby Hall' 'ruby@example.com')"
has "and the refusal says what to do instead" "Book a patch test first" \
    "$(bk $LASH 200 'Ruby Hall' 'ruby@example.com')"
chk "nothing was written" "0" "$(plain "select count(*) from booking")"
chk "and no client was created for a booking that never happened" "0" \
    "$(plain "select count(*) from client")"
# At a lash studio the trigger flags a brow wax too, which is correct - it is
# tint and wax on somebody's face. She must be able to say otherwise, and the
# trigger is INSERT-only precisely so that turning it off stays off.
has "even a brow wax is flagged at a lash studio" "needs a patch test" \
    "$(bk $WAX 201 'Ruby Hall' 'ruby@example.com')"
psql -q -c "update service set patch_test_hours=null where id='$WAX'" > /dev/null
R=$(bk $WAX 201 'Ruby Hall' 'ruby@example.com')
chk "and once she turns it off, it books" "8" "$(echo -n "$R" | wc -c)"
psql -q -c "delete from booking" -c "delete from patch_test" > /dev/null
chk "turning it off stays off" "" \
    "$(plain "select patch_test_hours from service where id='$WAX'")"

echo
echo "-- booking the patch test is the record --"
R=$(bk $TEST 100 'Ruby Hall' 'ruby@example.com')
chk "she can book the patch test itself"  "8" "$(echo -n "$R" | wc -c)"
chk "and that writes the record"          "1" "$(plain "select count(*) from patch_test")"
chk "dated to the appointment, not to now" "t" \
    "$(plain "select p.tested_at = b.starts_at from patch_test p join booking b on b.id=p.booking_id")"
R=$(bk $LASH 200 'Ruby Hall' 'ruby@example.com')
chk "and now the set books: 100 hours later is more than 48" "8" "$(echo -n "$R" | wc -c)"

echo
echo "-- the window is a window at both ends --"
psql -q -c "delete from booking" -c "delete from patch_test" > /dev/null
psql -q -c "insert into patch_test (tenant_id,client_id,tested_at)
            select '$T', id, now() - interval '2 hours' from client
             where email='ruby@example.com'" > /dev/null
has "a test two hours ago is too recent for a 48-hour rule" "needs a patch test" \
    "$(bk $LASH 24 'Ruby Hall' 'ruby@example.com')"
R=$(bk $LASH 60 'Ruby Hall' 'ruby@example.com')
chk "but it covers an appointment 60 hours out" "8" "$(echo -n "$R" | wc -c)"
psql -q -c "delete from booking" \
     -c "update patch_test set tested_at = now() - interval '8 months'" > /dev/null
has "a test from eight months ago has lapsed" "needs a patch test" \
    "$(bk $LASH 200 'Ruby Hall' 'ruby@example.com')"
psql -q -c "update tenant set patch_valid_months=12 where id='$T'" > /dev/null
R=$(bk $LASH 200 'Ruby Hall' 'ruby@example.com')
chk "unless she tells us her insurer allows twelve" "8" "$(echo -n "$R" | wc -c)"
psql -q -c "update tenant set patch_valid_months=6 where id='$T'" -c "delete from booking" > /dev/null

echo
echo "-- one studio's test is not another's --"
psql -q -c "delete from patch_test" > /dev/null
JT=$(plain "select id from tenant where slug='nails-by-jo'")
psql -q -c "update service set patch_test_hours=48, duration_min=30 where tenant_id='$JT'" \
     -c "update tenant set notice_hours=0 where id='$JT'" \
     -c "insert into opening (tenant_id,weekday,starts,ends)
         select '$JT', g, '00:00','23:59' from generate_series(0,6) g" > /dev/null
JS=$(plain "select id from service where tenant_id='$JT' limit 1")
psql -q -c "insert into patch_test (tenant_id,client_id,tested_at)
            select '$T', id, now() - interval '3 days' from client
             where email='ruby@example.com' and tenant_id='$T'" > /dev/null
R=$(bk $LASH 200 'Ruby Hall' 'ruby@example.com')
chk "her test covers the studio she had it at" "8" "$(echo -n "$R" | wc -c)"
has "and not the one down the road" "needs a patch test" \
    "$(plain "select ref from book('nails-by-jo','$JS',$(at 200),'Ruby Hall','ruby@example.com')")"

echo
echo "-- what her page can ask, and what it is told --"
# This harness stops at 014, where patch_status is still granted to anon, so
# these three still pass as written. 025 took it off the public list: no page
# ever called it, and a positive answer told an anonymous caller both that an
# address is a client of that studio and when she was last patch tested. The
# function and these assertions stay; only the grant went. test_paylink.sh
# covers that.
C=$(plain "select id from client where email='ruby@example.com' and tenant_id='$T'")
has "the page can check an address before she picks a time" "tested_at" \
    "$(asrole web_user "select patch_status('studio-mila','ruby@example.com')::text")"
chk "somebody with no test gets a null, not an error" "" \
    "$(asrole web_user "select patch_status('studio-mila','nobody@example.com')->>'tested_at'")"
no  "and it never says who else has been tested" "@example.com" \
    "$(asrole web_user "select patch_status('studio-mila','nobody@example.com')::text")"

echo
echo "-- hers to record and hers to see --"
has "she can record one she did by hand" "valid_until" \
    "$(as $U1 "select add_patch_test('$C'::uuid, now() - interval '1 day', 'Done at her kitchen table')::text")"
chk "and it shows in her list" "1" \
    "$(as $U1 "select count(*) from jsonb_object_keys(my_patch_tests())")"
has "Jo cannot record one against Ellie's client" "not yours" \
    "$(as $U2 "select add_patch_test('$C'::uuid)::text")"
chk "nor read Ellie's records" "0" \
    "$(asrole app_user "select count(*) from patch_test")"

echo
echo "-- what a browser may call --"
has "the refusal itself is not reachable" "permission denied" \
    "$(asrole app_user "select require_patch_test()")"
has "nor the recorder" "permission denied" \
    "$(asrole app_user "select record_patch_test()")"

echo
if [ $fail -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

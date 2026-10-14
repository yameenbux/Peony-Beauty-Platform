#!/bin/bash
# Pro+, and the one bug this tier could ship.
#
# Adding a third plan puts a fork in every gate that used to read plan = 'pro'.
# Miss one and a studio who PAYS MORE silently loses reminders, or rebooking,
# or keeps everything after her card fails. Most of this file is that: upgrade
# her and check nothing she already had went away.
#
# Then the insurance pack, which is the thing Pro+ is actually for.
#
#   ./test_proplus.sh        # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-proplus-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55447 PGUSER=test PGDATABASE=bookedin
U1=11111111-1111-1111-1111-111111111111
U2=22222222-2222-2222-2222-222222222222

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
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
         014_patch 015_venue 016_proplus; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 \
    || { echo "FAIL $f does not apply"; exit 1; }
done
echo "ok   the Pro+ migration applies"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')"
psql -q -c "grant usage on schema public to anon, authenticated" \
     -c "grant select, insert, update, delete on all tables in schema public to authenticated" \
     -c "grant select on all tables in schema public to anon" \
     -c "create role web_user" -c "grant anon to web_user" > /dev/null

fail=0
as()     { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain()  { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()  { case "$3" in *"$2"*) echo "FAIL $1 -> $3"; fail=1;; *) echo "ok   $1";; esac; }

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
T=$(plain "select id from tenant where slug='studio-mila'")
SVC=$(plain "select id from service where tenant_id='$T' limit 1")
psql -q -c "update tenant set notice_hours=0, remind_hours=48 where id='$T'" \
     -c "update service set duration_min=15, patch_test_hours=null where tenant_id='$T'" \
     -c "delete from opening where tenant_id='$T'" \
     -c "insert into opening (tenant_id,weekday,starts,ends)
         select '$T', g, '00:00','23:59' from generate_series(0,6) g" > /dev/null
at() { echo "(date_trunc('hour', now()) + interval '$1 hours')"; }

echo
echo "-- three plans, and only three --"
chk "a new studio starts free" "free" "$(plain "select plan from tenant where id='$T'")"
has "pro_plus is a plan the database accepts" "pro_plus" \
    "$(plain "select set_plan(null,'pro_plus',null,null,'$T'::uuid)")"
has "and a made-up one still is not" "unknown plan" \
    "$(plain "select set_plan(null,'platinum',null,null,'$T'::uuid)")"
chk "is_pro() says free is not" "f" "$(plain "select is_pro('free')")"
chk "is_pro() says pro is" "t" "$(plain "select is_pro('pro')")"
chk "is_pro() says pro_plus is" "t" "$(plain "select is_pro('pro_plus')")"

echo
echo "-- paying MORE must not take anything away --"
# The whole reason this file exists. Every gate that read plan = 'pro' is a
# place where an upgrade could silently cost her a feature.
chk "no gate anywhere still compares a plan to 'pro'" "0" \
    "$(plain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.prosrc like '%plan = ''pro''%'")"

psql -q -c "delete from mail_outbox" > /dev/null
R=$(plain "select ref from book('studio-mila','$SVC',$(at 24),'Ruby Hall','ruby@example.com')")
psql -q -c "delete from mail_outbox" > /dev/null
chk "a Pro+ studio still gets her reminders queued" "1" \
    "$(plain "select queue_reminders()")"
has "and the reminder is the real one, not a stub" "booked in with Studio Mila" \
    "$(plain "select body from mail_outbox where kind='client_reminder'")"

# The same again for rebooking, which is the other plan-gated sender.
psql -q -c "update tenant set rebook_on = true where id='$T'" \
     -c "update service set rebook_weeks = 3 where tenant_id='$T'" \
     -c "delete from mail_outbox" -c "delete from rebook_nudge" > /dev/null
# a visit four weeks ago, nothing booked ahead
psql -q -c "delete from booking" > /dev/null
psql -q -c "insert into booking (tenant_id, service_id, starts_at, ends_at,
              client_name, client_email, ref, status)
            values ('$T','$SVC', now() - interval '28 days',
              now() - interval '28 days' + interval '15 min',
              'Leah Byrne','leah@example.com','OLD12345','confirmed')" > /dev/null
chk "and her rebooking nudges still go out" "1" \
    "$(plain "select queue_rebook_nudges()")"
has "with the client's name in them" "Leah" \
    "$(plain "select body from mail_outbox where kind='client_rebook'")"

echo
echo "-- a card that fails drops her from whichever tier she was on --"
psql -q -c "select set_plan(null,'pro_plus', now() - interval '1 day', null,'$T'::uuid)" > /dev/null
chk "the sweep catches a lapsed Pro+, not just a lapsed Pro" "1" "$(plain "select expire_plans()")"
chk "and she lands on free" "free" "$(plain "select plan from tenant where id='$T'")"

echo
echo "-- the insurance pack --"
psql -q -c "select set_plan(null,'pro_plus',null,null,'$T'::uuid)" > /dev/null
psql -q -c "delete from booking" > /dev/null
R=$(plain "select ref from book('studio-mila','$SVC',$(at 30),'Ruby Hall','ruby@example.com')")
C=$(plain "select id from client where tenant_id='$T' and email='ruby@example.com'")
psql -q -c "insert into patch_test (tenant_id, client_id, tested_at, note)
            values ('$T','$C', now() - interval '20 days', 'No reaction at 48h.')" > /dev/null

PACK=$(as $U1 "select client_record('$C'::uuid)")
has "it names the client" "Ruby Hall" "$PACK"
has "and the studio producing it" "Studio Mila" "$PACK"
has "it carries the dated patch test" "tested_at" "$PACK"
has "and the note she wrote with it" "No reaction at 48h" "$PACK"
has "it works out when that test runs out" "valid_until" "$PACK"
has "it lists her appointments" "$R" "$PACK"
has "and is stamped with when it was produced" "produced_at" "$PACK"

echo
echo "-- and it is Pro+ only, decided by the database --"
psql -q -c "select set_plan(null,'pro',null,null,'$T'::uuid)" > /dev/null
has "Pro cannot pull a pack" "part of Pro+" "$(as $U1 "select client_record('$C'::uuid)")"
psql -q -c "select set_plan(null,'free',null,null,'$T'::uuid)" > /dev/null
has "and nor can Free" "part of Pro+" "$(as $U1 "select client_record('$C'::uuid)")"
psql -q -c "select set_plan(null,'pro_plus',null,null,'$T'::uuid)" > /dev/null

# The one that matters more than the tier check: somebody else's client.
as $U2 "select create_studio('other-studio','Other','nails')" > /dev/null
psql -q -c "select set_plan(null,'pro_plus',null,null,
            (select id from tenant where slug='other-studio'))" > /dev/null
has "another Pro+ studio cannot read her client's record" "not yours" \
    "$(as $U2 "select client_record('$C'::uuid)")"
has "and a signed-out visitor gets nothing at all" "denied" \
    "$(psql -qtA -c "set role web_user; select client_record('$C'::uuid)" 2>&1 | tr -d '\n')"

echo
echo "-- the billing guard still holds --"
# To a DIFFERENT value: the guard only has anything to guard when the column
# actually changes, so writing the plan she already has proves nothing.
chk "she is on pro_plus to start with" "pro_plus" "$(plain "select plan from tenant where id='$T'")"
has "she cannot write herself a plan directly" "set by billing" \
    "$(as $U1 "update tenant set plan='pro' where id='$T'")"
chk "and it did not change" "pro_plus" "$(plain "select plan from tenant where id='$T'")"

echo
if [ $fail -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

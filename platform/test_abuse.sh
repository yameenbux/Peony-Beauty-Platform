#!/bin/bash
# Proves a stranger cannot fill somebody's diary.
#
# Every limit in 010_abuse.sql is exercised against a real Postgres, including
# the one property that made the design worth the trouble: because the counts
# come from the booking table rather than from a log of attempts, a call that
# fails leaves no trace and costs the caller nothing. A log would have been
# erased by the same rollback that undid the booking.
#
#   ./test_abuse.sh          # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-abuse-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55441 PGUSER=test PGDATABASE=bookedin
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
         008_billing 009_lockdown 010_abuse; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 \
    || { echo "FAIL $f does not apply"; exit 1; }
done
echo "ok   the abuse migration applies on top of the others"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')"
# As in test_billing.sh: app_user is a MEMBER of authenticated, never granted
# anything directly, so the grants in 009 and 010 are what is actually tested.
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
as $U2 "select create_studio('other-studio','Other Studio','nails')" > /dev/null
T1=$(plain "select id from tenant where slug='studio-mila'")

# A short treatment and a long open day, so there are plenty of distinct slots
# to book into and no test is ever refused merely for running out of room.
psql -q -c "update tenant set notice_hours=0" \
     -c "delete from service" -c "delete from opening" \
     -c "insert into service (id,tenant_id,name,price_pence,duration_min)
         select '44444444-4444-4444-4444-444444444444', id,'Infill',2000,15
           from tenant where slug='studio-mila'" \
     -c "insert into service (id,tenant_id,name,price_pence,duration_min)
         select '55555555-5555-5555-5555-555555555555', id,'Gel',2000,15
           from tenant where slug='other-studio'" \
     -c "insert into opening (tenant_id,weekday,starts,ends)
         select id, g, '09:00','18:00' from tenant, generate_series(0,6) g" > /dev/null
A=44444444-4444-4444-4444-444444444444
B=55555555-5555-5555-5555-555555555555

# Slot n: a quarter hour on a day comfortably in the future, counted from a
# fixed base so no two calls in this file ever collide. Thirty slots to a day
# and then on to the next one, because 09:00-18:00 does not hold every slot
# these tests need and a test must never fail merely for running out of room.
slot() { echo "(date_trunc('day', now() + interval '30 days') + ($1 / 30) * interval '1 day' \
                + interval '9 hours' + (($1 % 30) * interval '15 minutes'))"; }
bk()  { plain "select ref from book('$1','$2',$(slot $3),'$4','$5')"; }
bkt() { plain "select ref from book('$1','$2',$(slot $3),'$4','$5',null,'$6')"; }

echo
echo "-- the honeypot --"
has "a filled trap field is refused" "could not take that booking" \
    "$(bkt studio-mila $A 1 'Bot' 'bot@example.com' 'http://spam.example')"
chk "and left no booking behind" "0" "$(plain "select count(*) from booking")"
R=$(bkt studio-mila $A 1 'Mia Clark' 'mia@example.com' '')
chk "an empty trap books normally" "8" "$(echo -n "$R" | wc -c)"

echo
echo "-- the email has to look like an email --"
for bad in "asdf" "no@domain" "two@@at.com" "trailing@dot." "sp ace@mail.com"; do
  has "refused: $bad" "does not look right" \
      "$(bk studio-mila $A 2 'Real Person' "$bad")"
done
chk "nothing was written" "1" "$(plain "select count(*) from booking")"
for good in "a.b+tag@sub.domain.co.uk" "first_last-99@mail-server.example.museum"; do
  R=$(bk studio-mila $A 3 'Real Person' "$good")
  chk "accepted: $good" "8" "$(echo -n "$R" | wc -c)"
  psql -q -c "delete from booking where lower(client_email)=lower('$good')" > /dev/null
done
# An apostrophe is legal in a local part and is the character most likely to be
# mishandled on the way to the database, so it is checked on its own, quoted
# the way a driver would quote it rather than through this file's shell.
chk "accepted: an apostrophe in the address" "8" "$(psql -qtA -c \
   "select ref from book('studio-mila','$A',$(slot 3),'Real Person',\$\$O'Neil@example.com\$\$)" \
   2>&1 | tr -d '\n' | wc -c | tr -d ' ')"
psql -q -c "delete from booking where client_email like '%neil%'" > /dev/null
has "a one-letter name is refused" "name the appointment is for" \
    "$(bk studio-mila $A 4 'X' 'x@example.com')"

echo
echo "-- how many appointments one person may hold at one studio --"
psql -q -c "delete from booking" > /dev/null
for i in 10 11 12; do
  R=$(bk studio-mila $A $i 'Sara Khan' 'sara@example.com')
  chk "booking $((i-9)) of 3 is taken" "8" "$(echo -n "$R" | wc -c)"
done
has "the fourth is refused" "already have 3 appointments" \
    "$(bk studio-mila $A 13 'Sara Khan' 'sara@example.com')"
has "even spelled differently" "already have 3 appointments" \
    "$(bk studio-mila $A 13 'Sara Khan' '  SARA@Example.COM ')"
chk "so she holds exactly 3" "3" \
    "$(plain "select count(*) from booking where client_email='sara@example.com'")"
psql -q -c "update booking set status='cancelled'
            where client_email='sara@example.com' and starts_at=(select min(starts_at)
            from booking where client_email='sara@example.com')" > /dev/null
R=$(bk studio-mila $A 13 'Sara Khan' 'sara@example.com')
chk "cancelling one frees a place" "8" "$(echo -n "$R" | wc -c)"

echo
echo "-- how many one address may make anywhere, in an hour --"
psql -q -c "delete from booking" > /dev/null
for i in 20 21 22; do bk studio-mila $A $i 'Lee Ann' 'lee@example.com' > /dev/null; done
for i in 23 24;    do bk other-studio $B $i 'Lee Ann' 'lee@example.com' > /dev/null; done
chk "five are through" "5" "$(plain "select count(*) from booking")"
has "the sixth is refused, at either studio" "lot of bookings from one email" \
    "$(bk other-studio $B 25 'Lee Ann' 'lee@example.com')"
chk "an hour later it is allowed again" "8" \
    "$(psql -qtA -c "update booking set created_at = now() - interval '61 minutes';
        select ref from book('other-studio','$B',$(slot 25),'Lee Ann','lee@example.com')" \
       2>&1 | tr -d '\n' | tail -c 8 | wc -c | tr -d ' ')"

echo
echo "-- how many may land in one diary, in an hour --"
psql -q -c "delete from booking" > /dev/null
for i in $(seq 30 49); do
  bk studio-mila $A $i "Client $i" "c$i@example.com" > /dev/null
done
chk "twenty are through" "20" "$(plain "select count(*) from booking")"
has "the twenty-first is refused" "unusually busy" \
    "$(bk studio-mila $A 50 'Client 50' 'c50@example.com')"
has "and the studio next door is unaffected" "" \
    "$(bk other-studio $B 50 'Client 50' 'c50@example.com')"

echo
echo "-- a refused call costs the caller nothing --"
psql -q -c "delete from booking" > /dev/null
for n in 1 2 3 4 5 6 7 8; do
  bkt studio-mila $A 60 'Ghost' 'ghost@example.com' 'http://spam.example' > /dev/null 2>&1
  bk  studio-mila $A 60 'Ghost' 'not-an-email'                            > /dev/null 2>&1
done
chk "sixteen refusals left no rows" "0" "$(plain "select count(*) from booking")"
R=$(bk studio-mila $A 60 'Ghost' 'ghost@example.com')
chk "so the next real attempt still works" "8" "$(echo -n "$R" | wc -c)"

echo
echo "-- the caller's address --"
chk "no request headers, no hash: the cap simply does not apply" "" \
    "$(plain "select booking_ip_key()")"
chk "and the booking still goes through" "1" \
    "$(plain "select count(*) from booking where ip_key is null")"
chk "a header is hashed, never stored raw" "t" \
    "$(plain "select booking_ip_key() is not null and booking_ip_key() <> '203.0.113.9'
              from (select set_config('request.headers',
                    '{\"x-forwarded-for\":\"203.0.113.9, 70.41.3.18\"}', true)) _")"
chk "the same address always hashes the same" "t" \
    "$(plain "select (select booking_ip_key() from (select set_config('request.headers',
                      '{\"x-forwarded-for\":\"203.0.113.9\"}', true)) a)
            = (select booking_ip_key() from (select set_config('request.headers',
                      '{\"x-forwarded-for\":\"203.0.113.9\"}', true)) b)")"
chk "a malformed header is ignored, not an error" "" \
    "$(plain "select booking_ip_key() from (select set_config('request.headers',
              'not json at all', true)) _")"
chk "old hashes are forgotten" "1" \
    "$(psql -qtA -c "update booking set ip_key='deadbeef', created_at = now() - interval '8 days';
                     select prune_ip_keys()" 2>&1 | tr -d '\n')"

echo
echo "-- what a browser may call --"
chk "there is exactly one book(), not an old one left beside the new" "1" \
    "$(plain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='book'")"
chk "and a six-argument call still reaches it, so no caller broke" "8" \
    "$(plain "select ref from book('studio-mila','$A',$(slot 71),'Old Caller','old@example.com','07700 900000')" | tail -c 8 | wc -c | tr -d ' ')"
has "the limit checker is not reachable from the app role" "permission denied" \
    "$(asrole app_user "select check_booking_limits('$T1'::uuid,'a@b.co',null)")"
has "nor is the address hasher" "permission denied" \
    "$(asrole app_user "select booking_ip_key()")"
has "nor the pruner" "permission denied" \
    "$(asrole app_user "select prune_ip_keys()")"
no  "book() itself is reachable signed out" "permission denied" \
    "$(asrole web_user "select book('studio-mila','$A'::uuid,$(slot 70),'Web User','web@example.com')")"
has "the limits table is not readable from the app role" "" \
    "$(asrole app_user "select per_ip_hour from booking_limit")"

echo
if [ $fail -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

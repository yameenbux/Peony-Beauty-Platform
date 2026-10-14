#!/bin/bash
# Where the appointment happens.
#
# Everything before this quietly assumed she drives to the client. Half the
# trade works from a room at home or a chair in a salon, and for them the
# question is not "when are you free" but "where are you and where do I park".
# These check that both shapes work and that neither asks for the other's
# information.
#
#   ./test_venue.sh          # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-venue-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55445 PGUSER=test PGDATABASE=bookedin
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
  -c "create role anon" -c "create role authenticated" || exit 1
for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
         014_patch 015_venue; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 \
    || { echo "FAIL $f does not apply"; exit 1; }
done
echo "ok   the venue migration applies"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com')"
psql -q -c "grant usage on schema public to anon, authenticated" \
     -c "grant select, insert, update, delete on all tables in schema public to authenticated" \
     -c "grant select on all tables in schema public to anon" \
     -c "create role web_user" -c "grant anon to web_user" > /dev/null

fail=0
as()     { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain()  { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
T=$(plain "select id from tenant where slug='studio-mila'")
psql -q -c "update tenant set notice_hours=0, patch_valid_months=6 where id='$T'" \
     -c "update service set patch_test_hours=null where tenant_id='$T'" \
     -c "delete from opening where tenant_id='$T'" \
     -c "insert into opening (tenant_id,weekday,starts,ends)
         select '$T', g, '00:00','23:59' from generate_series(0,6) g" > /dev/null
# Open every hour and fifteen minutes a treatment, so a test about where an
# appointment happens never fails because an offset of N hours landed at 23:00.
SVC=$(plain "select id from service where tenant_id='$T' limit 1")
psql -q -c "update service set duration_min=15 where tenant_id='$T'" > /dev/null
at() { echo "(date_trunc('hour', now()) + interval '$1 hours')"; }
bk()  { plain "select ref from book('studio-mila','$SVC',$(at $1),'$2','$3')"; }
bka() { plain "select ref from book('studio-mila','$SVC',$(at $1),'$2','$3',null,null,'$4')"; }

echo
echo "-- a premises is the default --"
chk "a new studio is somewhere, not everywhere" "salon" \
    "$(plain "select venue_kind from tenant where id='$T'")"
R=$(bk 10 'Ruby Hall' 'ruby@example.com')
chk "and a client books without being asked where she lives" "8" "$(echo -n "$R" | wc -c)"
chk "so nothing was stored about her address" "" \
    "$(plain "select coalesce(client_address,'') from booking where ref='$R'")"

echo
echo "-- she tells her clients where to come --"
psql -q -c "update tenant set address='Flat 2, 14 Mill Road, Nuneaton CV11 4QX',
            address_note='The white door beside the chippy. Park on the road, free after 6.'
            where id='$T'" > /dev/null
has "her page carries the address" "Mill Road" \
    "$(psql -qtA -c "set role web_user; select get_studio('studio-mila')->>'address'")"
has "and the part no address field holds" "beside the chippy" \
    "$(psql -qtA -c "set role web_user; select get_studio('studio-mila')->>'address_note'")"
chk "and says which shape of business it is" "salon" \
    "$(psql -qtA -c "set role web_user; select get_studio('studio-mila')->>'venue_kind'")"

echo
echo "-- when she travels, a town is not an address --"
psql -q -c "update tenant set venue_kind='mobile' where id='$T'" -c "delete from booking" > /dev/null
has "booking with no address at all is refused" "full address she should come to" \
    "$(bk 20 'Sian Price' 'sian@example.com')"
has "and so is \"Coventry\", which is a town, not a door" "including the number and postcode" \
    "$(bka 20 'Sian Price' 'sian@example.com' 'Coventry')"
chk "nothing was written" "0" "$(plain "select count(*) from booking")"
R=$(bka 20 'Sian Price' 'sian@example.com' '8 Oak Avenue, Coventry CV5 6RR')
chk "a real one books" "8" "$(echo -n "$R" | wc -c)"
has "and is kept against the booking" "Oak Avenue" \
    "$(plain "select client_address from booking where ref='$R'")"
has "and remembered on the client, so she never retypes it" "Oak Avenue" \
    "$(plain "select address from client where email='sian@example.com'")"

echo
echo "-- booking again --"
R=$(bka 21 'Sian Price' 'sian@example.com' '8 Oak Avenue, Coventry CV5 6RR')
chk "the same address does not make a second client" "2" "$(plain "select count(*) from client")"
R=$(bka 22 'Sian Price' 'sian@example.com' '12 New Street, Coventry CV1 2AA')
has "and moving house updates her" "New Street" \
    "$(plain "select address from client where email='sian@example.com'")"
has "while the old booking keeps where it actually was" "Oak Avenue" \
    "$(plain "select client_address from booking where client_email='sian@example.com'
              order by created_at limit 1")"

echo
echo "-- when she does both, the client says --"
psql -q -c "update tenant set venue_kind='both' where id='$T'" > /dev/null
R=$(bk 30 'Nina Okafor' 'nina@example.com')
chk "coming to her needs no address" "8" "$(echo -n "$R" | wc -c)"
R=$(bka 31 'Nina Okafor' 'nina@example.com' '3 Elm Close, Nuneaton CV10 7AA')
chk "and giving one is allowed" "8" "$(echo -n "$R" | wc -c)"
has "and kept" "Elm Close" "$(plain "select client_address from booking where ref='$R'")"

echo
echo "-- she can see where a regular lives, and nobody else can --"
has "her client list carries the address it kept" "Elm Close" \
    "$(as $U1 "select my_clients()")"
chk "and another studio's owner sees none of it" "[]" \
    "$(as 22222222-2222-2222-2222-222222222222 "select my_clients()")"

echo
echo "-- the emails say where, which is the whole point of asking --"
psql -q -c "delete from booking" -c "delete from mail_outbox" \
     -c "update tenant set venue_kind='salon', remind_hours=48 where id='$T'" > /dev/null
# Through set_plan, because the guard in 009 refuses a direct write to plan -
# which is the guard working, and the reminder only goes out on Pro.
psql -q -c "select set_plan(null,'pro',null,null,'$T'::uuid)" > /dev/null
R=$(bk 35 'Amy Shaw' 'amy@example.com')
has "a client coming to her is told the address" "14 Mill Road" \
    "$(plain "select body from mail_outbox where kind='client_booked'")"
has "and the part no address field holds" "beside the chippy" \
    "$(plain "select body from mail_outbox where kind='client_booked'")"
chk "and her own copy does not repeat her own address at her" "0" \
    "$(plain "select count(*) from mail_outbox
              where kind='studio_booked' and body like '%Mill Road%'")"

psql -q -c "delete from booking" -c "delete from mail_outbox" \
     -c "update tenant set venue_kind='mobile' where id='$T'" > /dev/null
R=$(bka 36 'Priya Shah' 'priya@example.com' '3 Elm Close, Nuneaton CV10 7AA')
has "when she travels, her own copy carries the client's address" "3 Elm Close" \
    "$(plain "select body from mail_outbox where kind='studio_booked'")"
chk "and her own address is in neither mail" "0" \
    "$(plain "select count(*) from mail_outbox where body like '%Mill Road%'")"
has "and the client is told who is coming where" "coming to you at 3 Elm Close" \
    "$(plain "select body from mail_outbox where kind='client_booked'")"

# The reminder is the one read standing up the night before.
psql -q -c "delete from mail_outbox" > /dev/null
psql -q -c "select queue_reminders()" > /dev/null
has "the reminder says it again" "3 Elm Close" \
    "$(plain "select body from mail_outbox where kind='client_reminder'")"

echo
echo "-- nothing 010 put in front of book() was lost in the rewrite --"
psql -q -c "update tenant set venue_kind='salon' where id='$T'" -c "delete from booking" > /dev/null
has "the honeypot still refuses" "could not take that booking" \
    "$(plain "select ref from book('studio-mila','$SVC',$(at 40),'Bot','bot@example.com',null,'http://spam')")"
has "a bad address is still a bad address" "does not look right" \
    "$(bk 40 'Real Person' 'asdf')"
has "a one-letter name is still refused" "name the appointment is for" \
    "$(bk 40 'X' 'x@example.com')"
for i in 41 42 43; do bk $i 'Lee Ann' 'lee@example.com' > /dev/null; done
has "and the three-at-once cap still holds" "already have 3 appointments" \
    "$(bk 44 'Lee Ann' 'lee@example.com')"
chk "there is still exactly one book()" "1" \
    "$(plain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='book'")"
chk "and a six-argument call still reaches it" "8" \
    "$(plain "select ref from book('studio-mila','$SVC',$(at 50),'Old Caller','old@example.com','07700 900000')" | tail -c 8 | wc -c | tr -d ' ')"

echo
if [ $fail -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

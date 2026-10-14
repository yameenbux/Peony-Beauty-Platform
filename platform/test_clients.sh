#!/bin/bash
# The client, and the one thing about it worth defending: a client belongs to
# one studio. The same email booking with two studios is two rows, and neither
# can see the other. Every test below that looks like it is about isolation is
# really about that promise.
#
#   ./test_clients.sh          # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-clients-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55442 PGUSER=test PGDATABASE=bookedin
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

# Applied in two halves on purpose. Bookings are taken BEFORE 011 exists, so
# the backfill has real rows to find - which is the state every live database
# will be in on the morning this migration runs.
for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 \
    || { echo "FAIL $f does not apply"; exit 1; }
done

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')"
psql -q -c "grant usage on schema public to anon, authenticated" \
     -c "grant select, insert, update, delete on all tables in schema public to authenticated" \
     -c "grant select on all tables in schema public to anon" \
     -c "create role app_user" -c "grant authenticated to app_user" > /dev/null

fail=0
as()     { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain()  { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
asrole() { psql -qtA -c "set test.uid='$1'; set role app_user; $2" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
as $U2 "select create_studio('other-studio','Other Studio','nails')" > /dev/null
psql -q -c "update tenant set notice_hours=0" -c "delete from service" -c "delete from opening" \
     -c "insert into service (id,tenant_id,name,price_pence,duration_min)
         select '44444444-4444-4444-4444-444444444444', id,'Infill',2000,15
           from tenant where slug='studio-mila'" \
     -c "insert into service (id,tenant_id,name,price_pence,duration_min)
         select '55555555-5555-5555-5555-555555555555', id,'Gel',3000,15
           from tenant where slug='other-studio'" \
     -c "insert into opening (tenant_id,weekday,starts,ends)
         select id, g, '09:00','18:00' from tenant, generate_series(0,6) g" > /dev/null
A=44444444-4444-4444-4444-444444444444
B=55555555-5555-5555-5555-555555555555
slot() { echo "(date_trunc('day', now() + interval '$2 days') + interval '9 hours' + ($1 * interval '15 minutes'))"; }
bk()  { plain "select ref from book('$1','$2',$(slot $3 ${6:-30}),'$4','$5')"; }
bkp() { plain "select ref from book('$1','$2',$(slot $3 ${7:-30}),'$4','$5','$6')"; }

# --- bookings taken before the client table exists ---
bk studio-mila $A 1 'Ruby Hall' 'ruby@example.com'            > /dev/null
bkp studio-mila $A 2 'Ruby Hall' 'ruby@example.com' '07700 900111' > /dev/null
bk studio-mila $A 3 'Sian Price' 'sian@example.com'           > /dev/null
bk other-studio $B 1 'Ruby H'    'RUBY@example.com'           > /dev/null
chk "four bookings exist before the migration" "4" "$(plain "select count(*) from booking")"

psql -q -v ON_ERROR_STOP=1 -f "$HERE/011_clients.sql" > /dev/null 2>&1 \
  || { echo "FAIL 011 does not apply"; exit 1; }
echo "ok   the client migration applies to a database that already has bookings"
psql -q -c "grant select, insert, update, delete on all tables in schema public to authenticated" \
     -c "grant select on all tables in schema public to anon" > /dev/null

echo
echo "-- the backfill --"
chk "three clients, not four: Ruby booked twice at one studio" "3" \
    "$(plain "select count(*) from client")"
chk "every old booking is linked" "0" \
    "$(plain "select count(*) from booking where client_id is null")"
chk "the address is stored lowercased, however it was typed" "1" \
    "$(plain "select count(*) from client where email='ruby@example.com'
              and tenant_id=(select id from tenant where slug='other-studio')")"
chk "a phone given on the second booking is kept" "07700 900111" \
    "$(plain "select phone from client where email='ruby@example.com'
              and tenant_id=(select id from tenant where slug='studio-mila')")"
chk "she is dated from her first booking, not from the migration" "t" \
    "$(plain "select c.created_at <= min(b.created_at) + interval '1 second'
                from client c join booking b on b.client_id=c.id
               where c.email='ruby@example.com' group by c.id limit 1")"

echo
echo "-- one studio, one client list --"
chk "Ruby is two rows, one per studio" "2" \
    "$(plain "select count(*) from client where email='ruby@example.com'")"
chk "and they are different rows" "f" \
    "$(plain "select (array_agg(id))[1] = (array_agg(id))[2] from client where email='ruby@example.com'")"
chk "Ellie sees two clients" "2" "$(as $U1 "select jsonb_array_length(my_clients())")"
chk "Jo sees one"            "1" "$(as $U2 "select jsonb_array_length(my_clients())")"
chk "and Jo cannot see Sian at all" "0" \
    "$(as $U2 "select count(*) from jsonb_array_elements(my_clients()) e
               where e->>'email'='sian@example.com'")"
chk "as the app role, Jo reads only her own rows" "1" \
    "$(asrole $U2 "select count(*) from client")"
has "and cannot write into Ellie's list" "new row violates row-level security" \
    "$(asrole $U2 "insert into client (tenant_id,email,name)
        select id,'sneak@example.com','Sneak' from tenant where slug='studio-mila'")"

echo
echo "-- what she actually wants to know --"
RUBY=$(as $U1 "select e->>'id' from jsonb_array_elements(my_clients()) e where e->>'email'='ruby@example.com'")
# the two Ruby bookings above are in the future, so nothing has been "visited" yet
chk "an upcoming booking is not counted as a visit" "0" \
    "$(as $U1 "select e->>'visits' from jsonb_array_elements(my_clients()) e where e->>'email'='ruby@example.com'")"
chk "but it shows as her next one" "t" \
    "$(as $U1 "select (e->>'next_visit') is not null from jsonb_array_elements(my_clients()) e
               where e->>'email'='ruby@example.com'")"
# Moved into the past an hour apart, not onto the same timestamp: the overlap
# constraint is real and would refuse to stack two bookings on one slot. This
# also takes them out of her "upcoming" count, which is what lets her book
# again below without meeting the three-at-once cap from 010.
psql -q -c "update booking b
               set starts_at = now() - interval '20 days' + (x.n * interval '1 hour'),
                   ends_at   = now() - interval '20 days' + (x.n * interval '1 hour') + interval '15 minutes'
              from (select id, row_number() over (order by starts_at) n
                      from booking
                     where client_email='ruby@example.com'
                       and tenant_id=(select id from tenant where slug='studio-mila')) x
             where b.id = x.id" > /dev/null
chk "once they are past, both count" "2" \
    "$(as $U1 "select e->>'visits' from jsonb_array_elements(my_clients()) e where e->>'email'='ruby@example.com'")"
chk "and so does what she spent" "4000" \
    "$(as $U1 "select e->>'spent_pence' from jsonb_array_elements(my_clients()) e where e->>'email'='ruby@example.com'")"
psql -q -c "update booking set status='cancelled' where client_email='sian@example.com'" > /dev/null
chk "a cancelled booking is not a visit" "0" \
    "$(as $U1 "select e->>'visits' from jsonb_array_elements(my_clients()) e where e->>'email'='sian@example.com'")"
chk "but it is counted as a cancellation" "1" \
    "$(as $U1 "select e->>'cancelled' from jsonb_array_elements(my_clients()) e where e->>'email'='sian@example.com'")"

echo
echo "-- booking on, now that the table exists --"
bk studio-mila $A 9 'Ruby Hall' '  RUBY@Example.COM  ' > /dev/null
chk "the same person, spelled differently, is not a new client" "2" \
    "$(as $U1 "select jsonb_array_length(my_clients())")"
bk studio-mila $A 10 'Nina Okafor' 'nina@example.com' > /dev/null
chk "a new address is a new client" "3" "$(as $U1 "select jsonb_array_length(my_clients())")"
chk "and the booking is linked straight away" "0" \
    "$(plain "select count(*) from booking where client_id is null")"
bk studio-mila $A 11 'Ruby Hall-Price' 'ruby@example.com' > /dev/null
chk "a changed name updates the client" "Ruby Hall-Price" \
    "$(plain "select name from client where email='ruby@example.com'
              and tenant_id=(select id from tenant where slug='studio-mila')")"
chk "and booking without a phone does not erase the one she gave" "07700 900111" \
    "$(plain "select phone from client where email='ruby@example.com'
              and tenant_id=(select id from tenant where slug='studio-mila')")"

echo
echo "-- her notes --"
chk "she can write a note" "" "$(as $U1 "select set_client_notes('$RUBY','Patch tested 02/10. Prefers 11mm.')")"
chk "and read it back" "Patch tested 02/10. Prefers 11mm." \
    "$(as $U1 "select e->>'notes' from jsonb_array_elements(my_clients()) e where e->>'id'='$RUBY'")"
has "Jo cannot write on Ellie's client" "not yours" \
    "$(as $U2 "select set_client_notes('$RUBY','mine now')")"
chk "and the note is untouched" "Patch tested 02/10. Prefers 11mm." \
    "$(as $U1 "select e->>'notes' from jsonb_array_elements(my_clients()) e where e->>'id'='$RUBY'")"

echo
echo "-- what a browser may call --"
has "upsert_client is not reachable from the app role" "permission denied" \
    "$(asrole $U1 "select upsert_client((select id from tenant where slug='studio-mila'),'x@y.co','X')")"
has "nor is the trigger function" "permission denied" \
    "$(asrole $U1 "select link_booking_client()")"
chk "my_clients is" "3" "$(asrole $U1 "select jsonb_array_length(my_clients())")"
chk "a signed-out visitor sees nobody" "0" \
    "$(plain "set role anon; select count(*) from client")"

echo
if [ $fail -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

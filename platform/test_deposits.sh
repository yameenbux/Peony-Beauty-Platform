#!/bin/bash
# Deposits, which we never touch.
#
# The money goes from her client to HER. We ask for it at the right moment, say
# exactly how to pay it, and keep the score. That makes most of this file about
# two things:
#
#   1. Her account details must not leak. The AMOUNT is public, because a
#      deposit nobody is told about is an ambush. The SORT CODE is not: it goes
#      only to somebody holding the reference and token for a real booking.
#   2. A deposit switched on with nowhere to send the money must be impossible,
#      because her client would be asked for £10 and told nothing.
#
#   ./test_deposits.sh       # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-deposit-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55448 PGUSER=test PGDATABASE=bookedin
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
         014_patch 015_venue 016_proplus 017_deposits; do
  # Say WHY. "does not apply" with the reason swallowed is a minute of
  # guessing every time a migration is edited.
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/apply.log" 2>&1 \
    || { echo "FAIL $f does not apply"; grep -i "error" "$DIR/apply.log" | head -3; exit 1; }
done
echo "ok   the deposits migration applies"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')"
psql -q -c "grant usage on schema public to anon, authenticated" \
     -c "grant select, insert, update, delete on all tables in schema public to authenticated" \
     -c "grant select on all tables in schema public to anon" \
     -c "create role web_user" -c "grant anon to web_user" > /dev/null

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
web()   { psql -qtA -c "set role web_user; $1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()  { case "$3" in *"$2"*) echo "FAIL $1 -> leaked: $3"; fail=1;; *) echo "ok   $1";; esac; }

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
T=$(plain "select id from tenant where slug='studio-mila'")
SVC=$(plain "select id from service where tenant_id='$T' limit 1")
psql -q -c "update tenant set notice_hours=0 where id='$T'" \
     -c "update service set duration_min=15, patch_test_hours=null, price_pence=5000
         where tenant_id='$T'" \
     -c "delete from opening where tenant_id='$T'" \
     -c "insert into opening (tenant_id,weekday,starts,ends)
         select '$T', g, '00:00','23:59' from generate_series(0,6) g" > /dev/null
at() { echo "(date_trunc('hour', now()) + interval '$1 hours')"; }
bk() { plain "select ref from book('studio-mila','$SVC',$(at $1),'$2','$3')"; }

# Deposits are a Pro feature, so this studio is Pro for the rest of the file.
psql -q -c "select set_plan(null,'pro',null,null,'$T'::uuid)" > /dev/null

echo
echo "-- off by default, and nothing changes --"
chk "a new studio asks for no deposit" "0" "$(plain "select deposit_pence from tenant where id='$T'")"
R=$(bk 10 'Ruby Hall' 'ruby@example.com')
chk "so a booking carries none" "0" "$(plain "select deposit_pence from booking where ref='$R'")"

echo
echo "-- a deposit with nowhere to send it cannot be saved --"
has "an amount with no method is refused" "deposit_route_check" \
    "$(plain "update tenant set deposit_pence=1000 where id='$T'")"
has "bank with no sort code is refused" "deposit_route_check" \
    "$(plain "update tenant set deposit_pence=1000, deposit_how='bank',
              deposit_name='E Mila' where id='$T'")"
has "paypal with no handle is refused" "deposit_route_check" \
    "$(plain "update tenant set deposit_pence=1000, deposit_how='paypal' where id='$T'")"
chk "and the studio is untouched by any of it" "0" \
    "$(plain "select deposit_pence from tenant where id='$T'")"

echo
echo "-- set up properly --"
psql -q -c "update tenant set deposit_pence=1000, deposit_how='bank',
            deposit_name='E Mila', deposit_sort='04-00-04', deposit_account='12345678',
            deposit_note='Within 24 hours please, or the time goes back up.'
            where id='$T'" > /dev/null
chk "the amount sticks" "1000" "$(plain "select deposit_pence from tenant where id='$T'")"

psql -q -c "delete from booking" > /dev/null
R=$(bk 11 'Sian Price' 'sian@example.com')
chk "a new booking is asked for it" "1000" "$(plain "select deposit_pence from booking where ref='$R'")"
chk "and starts unpaid" "" "$(plain "select coalesce(deposit_paid_at::text,'') from booking where ref='$R'")"

# A deposit must never exceed what the treatment costs.
psql -q -c "insert into service (tenant_id,name,price_pence,duration_min,sort)
            values ('$T','Patch test',0,15,9)" > /dev/null
FREE=$(plain "select id from service where tenant_id='$T' and price_pence=0")
R0=$(plain "select ref from book('studio-mila','$FREE',$(at 12),'Nina O','nina@example.com')")
chk "a free treatment asks for nothing" "0" "$(plain "select deposit_pence from booking where ref='$R0'")"
psql -q -c "update service set price_pence=600 where id='$FREE'" > /dev/null
R6=$(plain "select ref from book('studio-mila','$FREE',$(at 13),'Amy S','amy@example.com')")
chk "and a £6 treatment is never asked for £10" "600" \
    "$(plain "select deposit_pence from booking where ref='$R6'")"

echo
echo "-- changing her mind does not rewrite history --"
psql -q -c "update tenant set deposit_pence=2500 where id='$T'" > /dev/null
chk "last week's booking still says what it said" "1000" \
    "$(plain "select deposit_pence from booking where ref='$R'")"
psql -q -c "update tenant set deposit_pence=1000 where id='$T'" > /dev/null

echo
echo "-- the amount is public, the account is not --"
PUB=$(web "select get_studio('studio-mila')")
has "her page says there is a £10 deposit" "\"deposit_pence\": 1000" "$PUB"
no  "but never her account number" "12345678" "$PUB"
no  "nor her sort code" "04-00-04" "$PUB"
no  "nor the name on the account" "E Mila" "$PUB"

TOK=$(plain "select cancel_token from booking where ref='$R'")
MINE=$(web "select get_booking('$R','$TOK'::uuid)")
has "her client, holding the reference and token, is told how to pay" "12345678" "$MINE"
has "with the sort code" "04-00-04" "$MINE"
has "and the name to send it to" "E Mila" "$MINE"
has "and what she asked to add" "Within 24 hours" "$MINE"

# The token is the whole gate, so a wrong one must get nothing at all.
chk "a wrong token gets nothing" "" \
    "$(web "select coalesce(get_booking('$R','99999999-9999-9999-9999-999999999999'::uuid)::text,'')")"

echo
echo "-- the confirmation carries it --"
psql -q -c "delete from mail_outbox" > /dev/null
R2=$(bk 14 'Leah Byrne' 'leah@example.com')
BODY=$(plain "select body from mail_outbox where kind='client_booked'")
has "the client is told the amount" "deposit of £10.00" "$BODY"
has "and the account" "Sort code 04-00-04" "$BODY"
has "and what reference to put with it" "Reference $R2" "$BODY"
has "and that nothing here can see her bank" "confirm once it reaches her" "$BODY"
has "her own copy tells her to watch for it" "Mark it off in your diary" \
    "$(plain "select body from mail_outbox where kind='studio_booked'")"
no  "and does not repeat her own account details at her" "12345678" \
    "$(plain "select body from mail_outbox where kind='studio_booked'")"

echo
echo "-- she is the one who says it arrived --"
B=$(plain "select id from booking where ref='$R2'")
has "and only she can" "not yours" "$(as $U2 "select set_deposit_paid('$B'::uuid, true)")"
has "she marks it paid" "\"paid\": true" "$(as $U1 "select set_deposit_paid('$B'::uuid, true)")"
chk "and it is recorded" "1" \
    "$(plain "select count(*) from booking where ref='$R2' and deposit_paid_at is not null")"
has "her diary shows it" "deposit_paid_at" "$(as $U1 "select my_studio()")"
has "and she can take it back if it bounces" "\"paid\": false" \
    "$(as $U1 "select set_deposit_paid('$B'::uuid, false)")"
chk "which clears the date" "" \
    "$(plain "select coalesce(deposit_paid_at::text,'') from booking where ref='$R2'")"

echo
echo "-- a cancelled deposit is between the two of them --"
# As her, or the ownership check refuses it - which it should.
as $U1 "select set_deposit_paid('$B'::uuid, true)" > /dev/null
psql -q -c "delete from mail_outbox" > /dev/null
# The status change queues the mail by itself; calling queue_mail_for as well
# would write the same letter twice and prove nothing about the trigger.
psql -q -c "update booking set status='cancelled', cancelled_by='client' where id='$B'" > /dev/null
has "her client is told we never held it" "paid directly to Studio Mila" \
    "$(plain "select body from mail_outbox where kind='client_cancelled'")"

echo
echo "-- turning it off --"
psql -q -c "update tenant set deposit_pence=0, deposit_how='none' where id='$T'" > /dev/null
psql -q -c "delete from booking" -c "delete from mail_outbox" > /dev/null
R3=$(bk 20 'Jo Blake' 'jo@example.com')
chk "a new booking asks for nothing" "0" "$(plain "select deposit_pence from booking where ref='$R3'")"
no  "and the confirmation says nothing about deposits" "deposit" \
    "$(plain "select body from mail_outbox where kind='client_booked'")"

echo
echo "-- and a studio who stops paying stops asking --"
psql -q -c "update tenant set deposit_pence=1000, deposit_how='bank',
            deposit_name='E Mila', deposit_sort='04-00-04', deposit_account='12345678'
            where id='$T'" > /dev/null
psql -q -c "select set_plan(null,'free',null,null,'$T'::uuid)" > /dev/null
chk "her page stops announcing a deposit" "0" \
    "$(web "select get_studio('studio-mila')->>'deposit_pence'")"
psql -q -c "delete from booking" > /dev/null
R4=$(bk 21 'Mia King' 'mia@example.com')
chk "and a booking is not asked for one" "0" \
    "$(plain "select deposit_pence from booking where ref='$R4'")"
chk "her settings are kept, so coming back costs nothing" "1000" \
    "$(plain "select deposit_pence from tenant where id='$T'")"
psql -q -c "select set_plan(null,'pro_plus',null,null,'$T'::uuid)" > /dev/null
chk "and Pro+ asks for it again" "1000" \
    "$(web "select get_studio('studio-mila')->>'deposit_pence'")"

echo
echo "-- nothing 010 or 015 put in front of book() was lost --"
psql -q -c "update tenant set venue_kind='salon' where id='$T'" > /dev/null
has "the honeypot still refuses" "could not take that booking" \
    "$(plain "select ref from book('studio-mila','$SVC',$(at 40),'Bot','bot@example.com',null,'http://spam')")"
has "a bad address is still a bad address" "does not look right" "$(bk 41 'Real Person' 'asdf')"
chk "there is still exactly one book()" "1" \
    "$(plain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='book'")"

echo
if [ $fail -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

#!/bin/bash
# The confirmations both pages promise. The important test is the last one:
# a booking that loses the race must not send anybody a confirmation.
set -u
DIR=${TMPDIR:-/tmp}/bookedin-email-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55436 PGUSER=test PGDATABASE=bookedin
U=11111111-1111-1111-1111-111111111111

rm -rf "$DIR"; mkdir -p "$DIR/sock"
initdb -D "$DIR/data" -U test --auth=trust -E UTF8 > "$DIR/initdb.log" 2>&1 || exit 1
pg_ctl -D "$DIR/data" -o "-p $PGPORT -k $DIR/sock -c listen_addresses=''" \
       -l "$DIR/pg.log" -w start > /dev/null || exit 1
trap 'pg_ctl -D "$DIR/data" -m immediate stop >/dev/null 2>&1' EXIT
createdb bookedin
# auth.users carries an email in Supabase; the studio's copy goes to it
psql -q -v ON_ERROR_STOP=1 -c "create schema auth" \
  -c "create table auth.users (id uuid primary key, email text)" \
  -c "create function auth.uid() returns uuid language sql stable as
      \$\$ select nullif(current_setting('test.uid', true), '')::uuid \$\$" \
  -c "create role anon" -c "create role authenticated" || exit 1
for f in 001_schema 002_signup 003_cancel 004_photos 005_email; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }
done
echo "ok   all five migrations apply"
psql -q -c "insert into auth.users values ('$U','ellie@example.com')"

fail=0
as() { psql -qtA -c "set test.uid='$U'; $1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

as "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
as "update tenant set notice_hours=0 where slug='studio-mila'" > /dev/null
SVC=$(as "select id from service where name='Russian full set'")
FAR=$(as "select to_char(date_trunc('week', current_date + 21) + interval '1 day','YYYY-MM-DD')")

B=$(as "select ref||' '||token from book('studio-mila','$SVC'::uuid,'$FAR 10:00+01','Ruby Hall','ruby@example.com','07700 900123')")
REF=$(echo "$B" | cut -d' ' -f1); TOK=$(echo "$B" | cut -d' ' -f2)

chk "a booking queues two emails" "2" "$(as "select count(*) from mail_outbox")"
chk "one to the client"  "ruby@example.com"  "$(as "select to_email from mail_outbox where kind='client_booked'")"
chk "one to the studio"  "ellie@example.com" "$(as "select to_email from mail_outbox where kind='studio_booked'")"

C=$(as "select body from mail_outbox where kind='client_booked'")
has "the client's copy greets her by first name" "Hi Ruby,"       "$C"
has "it names the treatment"                     "Russian full set" "$C"
has "it carries the price"                       "£55"            "$C"
has "it carries the reference"                   "$REF"           "$C"
has "it carries a manage link with the token"    "manage.html?r=$REF&t=$TOK" "$C"
S=$(as "select body from mail_outbox where kind='studio_booked'")
has "her copy names the client"                  "Ruby Hall"      "$S"
has "her copy carries the client's email"        "ruby@example.com" "$S"
has "her copy carries the phone when given"      "07700 900123"   "$S"
has "her copy links to her diary"                "/app/"          "$S"
SUB=$(as "select subject from mail_outbox where kind='client_booked'")
has "the subject names the studio"               "Studio Mila"    "$SUB"

# the client's address must never leak into the studio's copy of somebody else's
chk "nothing is queued for anyone else" "0" \
    "$(as "select count(*) from mail_outbox where to_email not in ('ruby@example.com','ellie@example.com')")"

echo
echo "-- cancelling --"
as "select cancel_booking('$REF','$TOK'::uuid)" > /dev/null
chk "cancelling queues two more" "4" "$(as "select count(*) from mail_outbox")"
CC=$(as "select body from mail_outbox where kind='client_cancelled'")
has "the client is told it is cancelled"  "is cancelled"           "$CC"
has "and invited to book again"           "/book/?s=studio-mila"   "$CC"
SC=$(as "select body from mail_outbox where kind='studio_cancelled'")
has "she is told the client cancelled it" "She cancelled it herself" "$SC"

B2=$(as "select ref||' '||token from book('studio-mila','$SVC'::uuid,'$FAR 14:00+01','Mia K','mia@example.com')")
R2=$(echo "$B2" | cut -d' ' -f1)
ID2=$(as "select id from booking where ref='$R2'")
as "select studio_cancel('$ID2'::uuid)" > /dev/null
SC2=$(as "select body from mail_outbox where kind='studio_cancelled' and booking_id='$ID2'")
has "her own cancellation reads differently" "You cancelled this one" "$SC2"
CC2=$(as "select body from mail_outbox where kind='client_cancelled' and booking_id='$ID2'")
has "and the client is asked to rearrange"   "do get in touch to rearrange" "$CC2"
chk "cancelling twice does not send twice" "1" \
    "$(as "select count(*) from mail_outbox where kind='client_cancelled' and booking_id='$ID2'")"

echo
echo "-- draining --"
# This harness stops at 005, so next_mail() here is still 005's version, which
# counted the attempt when it handed the batch out. 024 replaced that with a
# lease - a pick-up costs a claim, not an attempt - because five pick-ups used
# to retire a message whether or not anybody had tried to send it. The new
# semantics are covered by test_mail_lease.sh, which applies the whole chain.
chk "nothing is marked sent yet" "8" "$(as "select count(*) from mail_outbox where sent_at is null")"
N=$(as "select count(*) from next_mail(3)")
chk "the drainer takes a batch" "3" "$N"
chk "and counts the attempt"    "3" "$(as "select count(*) from mail_outbox where attempts=1")"
ONE=$(as "select id from mail_outbox where attempts=1 limit 1")
as "select mail_sent('$ONE'::uuid)" > /dev/null
chk "a sent mail is stamped" "1" "$(as "select count(*) from mail_outbox where sent_at is not null")"
as "select mail_sent('$ONE'::uuid, 'smtp said no')" > /dev/null
chk "a failure clears the stamp so it is retried" "0" \
    "$(as "select count(*) from mail_outbox where sent_at is not null")"
has "and records why" "smtp said no" "$(as "select last_error from mail_outbox where id='$ONE'")"
as "update mail_outbox set attempts=5" > /dev/null
chk "a mail that failed five times is given up on" "0" "$(as "select count(*) from next_mail(20)")"

echo
echo "-- the one that matters --"
# 30 people going for one slot must produce one booking and one pair of emails,
# not thirty confirmations for a time only one of them got
as "delete from mail_outbox" > /dev/null
as "delete from booking" > /dev/null
rm -f "$DIR"/o.*
for i in $(seq 1 30); do
  ( psql -qtA -c "select ref from book('studio-mila','$SVC'::uuid,'$FAR 10:00+01','C$i','c$i@example.com')" \
    > "$DIR/o.$i" 2>&1 ) &
done
wait
ROWS=$(as "select count(*) from booking where status='confirmed'")
MAIL=$(as "select count(*) from mail_outbox")
if [ "$ROWS" = 1 ] && [ "$MAIL" = 2 ]; then
  echo "ok   30 racing bookings produced 1 booking and exactly 2 emails"
else
  echo "FAIL 30 racing bookings -> $ROWS booking(s), $MAIL email(s)"; fail=1
fi

[ $fail = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

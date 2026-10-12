#!/bin/bash
# The day-before reminder: the first thing Pro buys that Free does not.
set -u
DIR=${TMPDIR:-/tmp}/peony-remind-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55438 PGUSER=test PGDATABASE=peony
U=11111111-1111-1111-1111-111111111111

rm -rf "$DIR"; mkdir -p "$DIR/sock"
initdb -D "$DIR/data" -U test --auth=trust -E UTF8 > "$DIR/initdb.log" 2>&1 || exit 1
pg_ctl -D "$DIR/data" -o "-p $PGPORT -k $DIR/sock -c listen_addresses=''" \
       -l "$DIR/pg.log" -w start > /dev/null || exit 1
trap 'pg_ctl -D "$DIR/data" -m immediate stop >/dev/null 2>&1' EXIT
createdb peony
psql -q -v ON_ERROR_STOP=1 -c "create schema auth" \
  -c "create table auth.users (id uuid primary key, email text)" \
  -c "create function auth.uid() returns uuid language sql stable as
      \$\$ select nullif(current_setting('test.uid', true), '')::uuid \$\$" \
  -c "create role anon" -c "create role authenticated" || exit 1
for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }
done
echo "ok   the reminder migration applies"
psql -q -c "insert into auth.users values ('$U','ellie@example.com')"

fail=0
as() { psql -qtA -c "set test.uid='$U'; $1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
rem() { as "select count(*) from mail_outbox where kind='client_reminder'"; }

as "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
as "update tenant set notice_hours=0 where slug='studio-mila'" > /dev/null
TEN=$(as "select id from tenant where slug='studio-mila'")
SVC=$(as "select id from service where name='Russian full set'")

# bookings are written straight in so their timing is exact; book() would be
# bound by her opening hours, which is not what this file is testing
mk() { # starts_at (a SQL expression, unquoted), name, email -> ref
  as "insert into booking (tenant_id,service_id,starts_at,ends_at,client_name,client_email,ref)
      values ('$TEN','$SVC',$1,($1) + interval '90 min','$2','$3',
              upper(substr(md5(random()::text),1,8))) returning ref"
}

SOON=$(mk "now() + interval '8 hours'"  "Ruby Hall" "ruby@example.com")
LATER=$(mk "now() + interval '5 days'"  "Far Fiona" "fiona@example.com")
PAST=$(mk "now() - interval '2 hours'"  "Past Pam"  "pam@example.com")

chk "a free studio sends no reminders" "0" "$(as "select queue_reminders()")"
chk "and none are queued"              "0" "$(rem)"

as "update tenant set plan='pro' where id='$TEN'" > /dev/null
chk "on Pro, the booking inside the window is reminded" "1" "$(as "select queue_reminders()")"
chk "exactly one reminder is queued"                    "1" "$(rem)"
R=$(as "select to_email from mail_outbox where kind='client_reminder'")
chk "it goes to the client, not the studio" "ruby@example.com" "$R"
B=$(as "select body from mail_outbox where kind='client_reminder'")
has "it greets her by first name"   "Hi Ruby,"       "$B"
has "it names the treatment"        "Russian full set" "$B"
has "it offers a way to cancel"     "manage.html?r=$SOON" "$B"
has "the subject says tomorrow"     "Tomorrow"       "$(as "select subject from mail_outbox where kind='client_reminder'")"

chk "running again sends nothing more" "0" "$(as "select queue_reminders()")"
chk "and does not duplicate"           "1" "$(rem)"
chk "a booking five days out is left alone" "0" \
    "$(as "select count(*) from mail_outbox m join booking b on b.id=m.booking_id
            where m.kind='client_reminder' and b.ref='$LATER'")"
chk "a booking already in the past is left alone" "0" \
    "$(as "select count(*) from mail_outbox m join booking b on b.id=m.booking_id
            where m.kind='client_reminder' and b.ref='$PAST'")"

echo
echo "-- a cancelled booking is never reminded about --"
NEW=$(mk "now() + interval '6 hours'" "Cancel Cara" "cara@example.com")
as "update booking set status='cancelled', cancelled_by='client' where ref='$NEW'" > /dev/null
chk "cancelling stamps it so no reminder follows" "0" "$(as "select queue_reminders()")"
chk "still only the one reminder" "1" "$(rem)"

echo
echo "-- she can widen the window --"
as "update tenant set remind_hours=168 where id='$TEN'" > /dev/null
chk "a wider window catches the booking five days out" "1" "$(as "select queue_reminders()")"
chk "now two reminders exist" "2" "$(rem)"

echo
echo "-- going back to free stops them --"
FRESH=$(mk "now() + interval '4 hours'" "Free Flo" "flo@example.com")
as "update tenant set plan='free' where id='$TEN'" > /dev/null
chk "a free studio sends nothing again" "0" "$(as "select queue_reminders()")"
chk "the count is unchanged" "2" "$(rem)"

[ $fail = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

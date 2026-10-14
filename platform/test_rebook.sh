#!/bin/bash
# The nudge that fills next month, and every rule that stops it becoming spam.
#
# The ones worth reading are at the bottom: that nothing sends until she turns
# it on, that one visit produces exactly one message however many times the job
# runs, and that an opt-out is final.
#
#   ./test_rebook.sh          # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-rebook-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55443 PGUSER=test PGDATABASE=bookedin
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
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 \
    || { echo "FAIL $f does not apply"; exit 1; }
done
echo "ok   the rebook migration applies"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com')"
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

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
T=$(plain "select id from tenant where slug='studio-mila'")

echo
echo "-- the intervals are filled in from the trade --"
chk "an infill repeats every 3 weeks without her touching anything" "3" \
    "$(plain "select rebook_weeks from service where tenant_id='$T' and name ilike '%infill%' limit 1")"
chk "and nothing is left unset that should have been" "0" \
    "$(plain "select count(*) from service where tenant_id='$T' and rebook_weeks is null
              and name not ilike '%trial%' and name not ilike '%patch%'")"
chk "but it is off until she says so" "f" "$(plain "select rebook_on from tenant where id='$T'")"

# A visit four weeks ago, with an interval of three: comfortably due.
psql -q -c "delete from service where tenant_id='$T'" \
     -c "insert into service (id,tenant_id,name,price_pence,duration_min,rebook_weeks)
         values ('44444444-4444-4444-4444-444444444444','$T','Russian infills',4000,90,3)" \
     -c "insert into client (id,tenant_id,email,name)
         values ('77777777-7777-7777-7777-777777777777','$T','ruby@example.com','Ruby Hall')" > /dev/null
A=44444444-4444-4444-4444-444444444444
C=77777777-7777-7777-7777-777777777777
visit() {  # visit <days ago> [ref]
  psql -qtA -c "insert into booking (tenant_id,service_id,starts_at,ends_at,client_name,
                  client_email,ref,client_id)
                values ('$T','$A', now() - interval '$1 days',
                        now() - interval '$1 days' + interval '90 minutes',
                        'Ruby Hall','ruby@example.com','${2:-R0000001}','$C')
                returning id" 2>&1 | tr -d '\n'
}
run() { plain "select queue_rebook_nudges()"; }
nudges() { plain "select count(*) from mail_outbox where kind='client_rebook'"; }

echo
echo "-- nothing happens until she turns it on --"
V=$(visit 28 RUBY0001)
chk "she is due, and still nothing is sent"   "0" "$(run)"
# Through set_plan, because the guard in 009 refuses a direct write to the
# plan column - which is exactly what it is there for.
psql -q -c "select set_plan(null,'pro',null,null,'$T'::uuid)" > /dev/null
chk "Pro alone is not enough"                 "0" "$(run)"
psql -q -c "update tenant set rebook_on=true where id='$T'" > /dev/null
chk "with the switch on, she is nudged"       "1" "$(run)"
chk "and it is one email"                     "1" "$(nudges)"

echo
echo "-- and only ever once --"
chk "running it again sends nothing"  "0" "$(run)"
chk "nor a third time"                "0" "$(run)"
chk "still one email"                 "1" "$(nudges)"
chk "one row records why"             "1" "$(plain "select count(*) from rebook_nudge")"

echo
echo "-- what the message says --"
B=$(plain "select body from mail_outbox where kind='client_rebook' limit 1")
has "it opens with her first name"      "Hi Ruby,"            "$B"
has "names the treatment"               "russian infills"     "$B"
has "names the studio"                  "Studio Mila"         "$B"
has "says how long it has been"         "4 weeks since"       "$B"
has "links straight to her page"        "/studio-mila"        "$B"
has "and carries a way out"             "turn these off here" "$B"
S=$(plain "select subject from mail_outbox where kind='client_rebook' limit 1")
chk "the subject is a question, not a sell" "Time for your russian infills?" "$S"

echo
echo "-- who is skipped, and why --"
psql -q -c "delete from mail_outbox" -c "delete from rebook_nudge" -c "delete from booking" > /dev/null

visit 10 TOOSOON1 > /dev/null
chk "ten days in, with a three-week interval, is too soon" "0" "$(run)"
psql -q -c "delete from booking" > /dev/null

visit 120 TOOLONG1 > /dev/null
chk "four months on it is not a nudge, it is a guilt trip" "0" "$(run)"
psql -q -c "delete from booking" > /dev/null

V=$(visit 28 HASNEXT1)
psql -q -c "insert into booking (tenant_id,service_id,starts_at,ends_at,client_name,
              client_email,ref,client_id)
            values ('$T','$A', now() + interval '3 days',
                    now() + interval '3 days' + interval '90 minutes',
                    'Ruby Hall','ruby@example.com','BOOKEDAL','$C')" > /dev/null
chk "somebody with an appointment already booked is left alone" "0" "$(run)"
psql -q -c "delete from booking" > /dev/null

V=$(visit 28 CANCELLD)
psql -q -c "update booking set status='cancelled' where ref='CANCELLD'" > /dev/null
chk "a cancelled visit is not a visit"  "0" "$(run)"
psql -q -c "delete from booking" -c "delete from mail_outbox" > /dev/null

psql -q -c "update service set rebook_weeks=null where id='$A'" > /dev/null
visit 28 NOINTERV > /dev/null
chk "a treatment with no interval never nudges" "0" "$(run)"
psql -q -c "update service set rebook_weeks=3 where id='$A'" -c "delete from booking" > /dev/null

echo
echo "-- she went three times; she gets one message, not three --"
visit 70 OLDEST01 > /dev/null
visit 50 MIDDLE01 > /dev/null
visit 28 LATEST01 > /dev/null
chk "one nudge for three visits"        "1" "$(run)"
chk "and it is about the latest one"    "LATEST01" \
    "$(plain "select b.ref from mail_outbox m join booking b on b.id=m.booking_id
              where m.kind='client_rebook'")"
psql -q -c "delete from mail_outbox" -c "delete from rebook_nudge" -c "delete from booking" > /dev/null

echo
echo "-- the off switch --"
visit 28 OPTOUT01 > /dev/null
TOK=$(plain "select unsub_token from client where id='$C'")
has "following the link says which studio it was for" "Studio Mila" \
    "$(asrole web_user "select set_rebook_opt_out('$TOK'::uuid)::text")"
chk "she is marked out"       "t" "$(plain "select rebook_opt_out from client where id='$C'")"
chk "and is not nudged"       "0" "$(run)"
chk "no email was written"    "0" "$(nudges)"
has "a made-up token is refused" "not valid" \
    "$(asrole web_user "select set_rebook_opt_out(gen_random_uuid())::text")"
has "she can turn them back on" "false" \
    "$(asrole web_user "select (set_rebook_opt_out('$TOK'::uuid,false)->>'opted_out')")"
chk "and is nudged again"     "1" "$(run)"

echo
echo "-- what a browser may call --"
has "the job itself is not reachable from the app role" "permission denied" \
    "$(asrole app_user "select queue_rebook_nudges()")"
has "nor from a signed-out visitor" "permission denied" \
    "$(asrole web_user "select queue_rebook_nudges()")"
chk "the record of what was sent is not readable either" "0" \
    "$(asrole app_user "select count(*) from rebook_nudge")"

echo
if [ $fail -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

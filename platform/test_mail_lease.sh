#!/bin/bash
# The bug 024 fixes: a pick-up used to cost a delivery attempt.
#
# next_mail() counted the attempt when it handed the batch out, and
# `attempts < 5` is the only thing standing between a message and being
# abandoned. So five pick-ups retired a message whether or not anybody had
# tried to send it - and send-mail was deployed --no-verify-jwt with a handler
# that took no request argument, so those five pick-ups could come from anyone
# who knew the URL. The same thing happens with no attacker at all: Resend
# rate-limits, the minute-by-minute cron keeps picking the batch up, and five
# minutes later the confirmations are gone with nothing retrying or alerting.
#
# The test that matters is "six claims must not retire anything". Everything
# else here is making sure the lease that replaced the counter did not break
# the two properties 005 already had: two drainers never take the same message,
# and a message that genuinely cannot be sent is eventually given up on.
#
#   ./test_mail_lease.sh       # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-maillease-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55483 PGUSER=test PGDATABASE=bookedin
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
         020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done
echo "ok   001-024 apply"

fail=0
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
anon()  { psql -qtA -c "set role anon; $1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

# The queue directly, rather than through bookings: this is a test about the
# drainer, and twelve rows is clearer than six bookings.
queue() {
  psql -q -c "delete from mail_outbox" >/dev/null
  psql -q -c "insert into mail_outbox (kind, to_email, subject, body)
              select 'client_booked', 'c'||i||'@example.com', 'subject', 'body'
                from generate_series(1, $1) i" >/dev/null
}
expire() { psql -q -c "update mail_outbox set claimed_at = now() - interval '10 minutes'" >/dev/null; }

echo
echo "-- 1. a claim costs a claim, not an attempt --"
queue 3
chk "the drainer takes a batch"      "2" "$(plain "select count(*) from next_mail(2)")"
chk "  and counts the claim"         "2" "$(plain "select count(*) from mail_outbox where claims = 1")"
chk "  but spends no attempt"        "0" "$(plain "select count(*) from mail_outbox where attempts > 0")"
chk "a claimed row is off the queue while the lease holds" "1" \
    "$(plain "select count(*) from next_mail(20)")"

echo
echo "-- 2. THE ONE THAT MATTERS: six claims must not retire anything --"
# Six, because five was the number that used to do it. Each round expires the
# lease first, which is what a minute-by-minute cron and an attacker with the
# URL both amount to.
queue 2
for i in 1 2 3 4 5 6; do expire; psql -q -c "select next_mail(20)" >/dev/null; done
chk "after six pick-ups nothing has been attempted" "0" \
    "$(plain "select coalesce(max(attempts), -1) from mail_outbox")"
chk "  all six were counted as claims"              "6" \
    "$(plain "select coalesce(min(claims), -1) from mail_outbox")"
expire
chk "  and the mail is still deliverable"           "2" \
    "$(plain "select count(*) from next_mail(20)")"
chk "  with nothing given up on"                    "0" "$(plain "select count(*) from mail_stuck()")"

echo
echo "-- 3. a run that dies before reporting is retried, not lost --"
queue 1
psql -q -c "select next_mail(1)" >/dev/null          # claimed, then the function dies
chk "it is held for the length of the lease" "0" "$(plain "select count(*) from next_mail(1)")"
expire
chk "and picked up again once the lease expires" "1" "$(plain "select count(*) from next_mail(1)")"
chk "  still with no attempt spent" "0" \
    "$(plain "select coalesce(max(attempts), -1) from mail_outbox")"

echo
echo "-- 4. a reported failure does count, and does eventually give up --"
queue 1
ID=$(plain "select id from mail_outbox")
for i in 1 2 3 4 5; do
  expire
  psql -q -c "select next_mail(1)" >/dev/null
  psql -q -c "select mail_sent('$ID'::uuid, 'resend said no')" >/dev/null
done
chk "five reported failures are counted" "5" "$(plain "select attempts from mail_outbox")"
expire
chk "and the message is given up on"     "0" "$(plain "select count(*) from next_mail(20)")"
has "it records why"       "resend said no" "$(plain "select last_error from mail_outbox")"
chk "and it is no longer invisible"      "1" "$(plain "select count(*) from mail_stuck()")"
has "  mail_stuck names the reason"  "resend said no" "$(plain "select last_error from mail_stuck()")"

echo
echo "-- 5. a failure leaves the lease on, so a retry is not immediate --"
queue 1
ID=$(plain "select id from mail_outbox")
psql -q -c "select next_mail(1)" >/dev/null
psql -q -c "select mail_sent('$ID'::uuid, 'rate limited')" >/dev/null
chk "the retry waits for the lease rather than hammering the provider" "0" \
    "$(plain "select count(*) from next_mail(20)")"
chk "  and the stamp was cleared so it IS a retry" "1" \
    "$(plain "select count(*) from mail_outbox where sent_at is null")"

echo
echo "-- 6. success is final --"
queue 1
ID=$(plain "select id from mail_outbox")
psql -q -c "select next_mail(1)" >/dev/null
psql -q -c "select mail_sent('$ID'::uuid)" >/dev/null
chk "a sent mail is stamped"        "1" "$(plain "select count(*) from mail_outbox where sent_at is not null")"
expire
chk "and is never picked up again"  "0" "$(plain "select count(*) from next_mail(20)")"
chk "  nor reported as stuck"       "0" "$(plain "select count(*) from mail_stuck()")"

echo
echo "-- 7. the safety cap on a drainer that never reports at all --"
queue 1
psql -q -c "update mail_outbox set claims = 50" >/dev/null
expire
chk "fifty claims with nothing reported stops the loop" "0" \
    "$(plain "select count(*) from next_mail(20)")"
chk "  and says so"                                     "1" \
    "$(plain "select count(*) from mail_stuck()")"

echo
echo "-- 8. two drainers still never take the same message --"
# skip locked is the property that made the one-a-minute schedule safe, and the
# lease must not have replaced it. Four concurrent drainers, twelve messages.
queue 12
rm -f "$DIR"/claim.*
for i in 1 2 3 4; do
  ( psql -qtA -c "select id from next_mail(3)" > "$DIR/claim.$i" 2>&1 ) &
done
wait
TOTAL=$(cat "$DIR"/claim.* | grep -c '-' || true)
UNIQ=$(cat "$DIR"/claim.* | grep '-' | sort -u | wc -l)
chk "twelve messages went out across four drainers" "12" "$TOTAL"
chk "  and no message went to two of them"          "$TOTAL" "$UNIQ"

echo
echo "-- 9. none of this is reachable from a browser --"
for fn in next_mail mail_sent mail_stuck; do
  chk "anon cannot reach $fn" "f" \
      "$(plain "select has_function_privilege('anon', p.oid, 'EXECUTE')
                from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='$fn' limit 1")"
  chk "  nor can a signed-in studio" "f" \
      "$(plain "select has_function_privilege('authenticated', p.oid, 'EXECUTE')
                from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='$fn' limit 1")"
done
has "and the outbox itself refuses anon" "permission denied" \
    "$(anon "select count(*) from mail_outbox")"
# Belt and braces, in the order they were added. The first draft of this test
# asserted "permission denied" and got 0 instead: RLS with no policy was
# default-denying the rows while Supabase's default ACL still handed anon the
# SELECT privilege. That is the same arrangement that leaked the bank details
# on `tenant` - a dangerous grant made safe only by a policy being right - so
# 024 takes the grant away as well, and this asserts both halves.
chk "anon holds no privilege on the outbox" "f" \
    "$(plain "select has_table_privilege('anon','public.mail_outbox','SELECT')")"
chk "  nor does a signed-in studio" "f" \
    "$(plain "select has_table_privilege('authenticated','public.mail_outbox','SELECT')")"
chk "  and RLS would deny the rows anyway: no policy exists" "0" \
    "$(plain "select count(*) from pg_policies
              where schemaname='public' and tablename='mail_outbox'")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

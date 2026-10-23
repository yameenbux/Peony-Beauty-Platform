#!/bin/bash
# The three things 030 fixes, each asserted broken first.
#
#   ./test_launch.sh      # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-launch-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55491 PGUSER=test PGDATABASE=bookedin
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
  -c "create role anon" -c "create role authenticated" -c "create role service_role" \
  -c "grant usage on schema public to anon, authenticated" || exit 1
psql -q -v ON_ERROR_STOP=1 -c "alter default privileges in schema public
       grant all on tables to anon, authenticated, service_role" \
  -c "alter default privileges in schema public
       grant execute on functions to anon, authenticated, service_role" || exit 1

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
asrole(){ psql -qtA -c "set test.uid='$1'; set role authenticated; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
want()  { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has()   { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()    { case "$3" in *"$2"*) echo "FAIL $1 -> still '$2': $3"; fail=1;; *) echo "ok   $1";; esac; }

APPLY() { for f in "$@"; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }; done; }
APPLY 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
      008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
      014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
      020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease \
      025_paylink 026_trigger_privilege 027_patch_test_seed 028_trade_palette \
      029_slot_taken_readonly
echo "ok   001-029 apply"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')" >/dev/null
as $U1 "select create_studio('studio-mila','Studio Mila','nails')" > /dev/null
T=$(plain "select id from tenant where slug='studio-mila'")
# A plan only ever moves through set_plan: guard_billing_columns refuses a
# direct write to the column, which an earlier draft of this file was quietly
# swallowing - so every studio stayed on the pro_plus trial and the gate
# assertions below passed her for the wrong reason.
setplan() { psql -q -c "select set_plan(null,'$1',null,null,'$T'::uuid)" > /dev/null; }
setplan free
want "she is on free" "free" "$(plain "select plan from tenant where slug='studio-mila'")"

echo
echo "-- before 030: Pro+ earnings are not actually Pro+. This must pass. --"
OUT=$(asrole $U1 "select my_earnings()::text")
has "a FREE studio can read the Pro+ earnings panel" "since_days" "$OUT"
echo "     ^ that is the paywall hole, on an unpatched schema"

echo
echo "-- before 030: sent mail is kept for ever --"
psql -q -c "insert into mail_outbox (kind,to_email,to_name,subject,body,created_at,sent_at)
            values ('client_booked','ruby@example.com','Ruby Hall','Booked','12 Mill Lane, Nuneaton',
                    now() - interval '400 days', now() - interval '400 days')" >/dev/null
psql -q -c "insert into mail_outbox (kind,to_email,to_name,subject,body,created_at)
            values ('client_booked','still@example.com','Still Waiting','Queued','body', now())" >/dev/null
want "a year-old sent message is still here" "1" \
     "$(plain "select count(*) from mail_outbox where to_email='ruby@example.com'")"
has "with her home address in it" "Mill Lane" \
    "$(plain "select body from mail_outbox where to_email='ruby@example.com'")"

echo
echo "-- 030 --"
APPLY 030_launch_hardening
echo "ok   030 applies"

echo
echo "-- the earnings panel is Pro+ now, decided in the database --"
has "a Free studio is refused" "part of Pro+" "$(asrole $U1 "select my_earnings()::text")"
setplan pro
has "and so is Pro, because this is the tier above it" "part of Pro+" \
    "$(asrole $U1 "select my_earnings()::text")"
setplan pro_plus
has "a Pro+ studio still gets her numbers" "since_days" "$(asrole $U1 "select my_earnings()::text")"
has "somebody with no page at all is told to make one" "Make your page first" \
    "$(asrole $U2 "select my_earnings()::text")"

echo
echo "-- the outbox forgets what it no longer needs --"
want "prune_mail removes the year-old message" "1" "$(plain "select prune_mail()")"
want "and it is gone" "0" \
     "$(plain "select count(*) from mail_outbox where to_email='ruby@example.com'")"
want "the unsent one is untouched" "1" \
     "$(plain "select count(*) from mail_outbox where to_email='still@example.com'")"
want "running it again removes nothing" "0" "$(plain "select prune_mail()")"
# A message sent yesterday is still answerable with "did that go?"
psql -q -c "insert into mail_outbox (kind,to_email,subject,body,created_at,sent_at)
            values ('client_booked','fresh@example.com','Booked','body',
                    now() - interval '1 day', now() - interval '1 day')" >/dev/null
want "yesterday's sent mail is kept" "0" "$(plain "select prune_mail()")"
want "it is still there" "1" \
     "$(plain "select count(*) from mail_outbox where to_email='fresh@example.com'")"

echo
echo "-- the IP keys finally get pruned --"
# A real booking, made the way a client makes one, then backdated: inserting
# a row by hand skips the columns book() fills and proves nothing about it.
SVC=$(plain "select id from service where tenant_id='$T'::uuid limit 1")
psql -q -c "update tenant set notice_hours=0 where id='$T'::uuid" >/dev/null 2>&1
SLOT=$(plain "select min(f) from free_slots('studio-mila','$SVC'::uuid,
              current_date, current_date + 14) f")
plain "select book('studio-mila','$SVC'::uuid,'$SLOT'::timestamptz,'Ruby Hall','ruby@example.com')" >/dev/null
psql -q -c "update booking set ip_key = 'deadbeef',
                                created_at = now() - interval '30 days'" >/dev/null
want "an old booking still carries its IP key" "1" \
     "$(plain "select count(*) from booking where ip_key is not null and created_at < now() - interval '7 days'")"
want "prune_ip_keys clears it" "1" "$(plain "select prune_ip_keys()")"
want "and nothing old still has one" "0" \
     "$(plain "select count(*) from booking where ip_key is not null and created_at < now() - interval '7 days'")"

echo
echo "-- the standing sweep still holds --"
want "lockdown is unchanged at 31" "31" "$(plain "select lockdown()")"
want "prune_mail is not reachable by a studio" "f" \
     "$(plain "select has_function_privilege('authenticated','public.prune_mail(int)','EXECUTE')")"
want "nor by a visitor" "f" \
     "$(plain "select has_function_privilege('anon','public.prune_mail(int)','EXECUTE')")"

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

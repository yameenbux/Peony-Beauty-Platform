#!/bin/bash
# Plan state. The point of these tests is that a studio cannot put itself on
# Pro: only the webhook, running as service_role, may write these columns.
set -u
DIR=${TMPDIR:-/tmp}/bookedin-billing-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55439 PGUSER=test PGDATABASE=bookedin
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
for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders 008_billing 009_lockdown; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > /dev/null 2>&1 || { echo "FAIL $f"; exit 1; }
done
echo "ok   the billing migration applies"
psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','other@example.com')"
# app_user stands in for a signed-in visitor. It is a MEMBER of authenticated
# rather than being granted everything directly, because that is how Supabase
# works — and a blanket "grant execute on all functions" here would quietly
# undo the lockdown this file is meant to test.
psql -q -c "grant usage on schema public to anon, authenticated" \
     -c "grant select, insert, update, delete on all tables in schema public to authenticated" \
     -c "grant select on all tables in schema public to anon" \
     -c "create role app_user" \
     -c "grant authenticated to app_user" > /dev/null

fail=0
as()     { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
asrole() { psql -qtA -c "set test.uid='$1'; set role app_user; $2" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
as $U2 "select create_studio('other-studio','Other Studio','nails')" > /dev/null
T1=$(as $U1 "select id from tenant where slug='studio-mila'")

chk "a new studio starts on Free" "free" "$(as $U1 "select my_billing()->>'plan'")"
chk "and is not subscribed"       "false" "$(as $U1 "select my_billing()->>'subscribed'")"

echo
echo "-- she cannot put herself on Pro --"
has "set_plan is not reachable from the app role" "permission denied" \
    "$(asrole $U1 "select set_plan('cus_x','pro',null,'sub_x','$T1'::uuid)")"
has "and writing the column directly is refused" "set by billing" \
    "$(asrole $U1 "update tenant set plan='pro' where id='$T1'")"
has "so is quietly granting herself a subscription" "set by billing" \
    "$(asrole $U1 "update tenant set stripe_subscription_id='sub_forged' where id='$T1'")"
chk "but she can still edit her own studio" "" \
    "$(asrole $U1 "update tenant set tagline='Mobile lashes' where id='$T1'")"
chk "so she is still on Free" "free" "$(as $U1 "select my_billing()->>'plan'")"

echo
echo "-- the webhook puts her on Pro --"
has "the first event matches her by the tenant in the metadata" '"plan": "pro"' \
    "$(as $U1 "select set_plan('cus_123','pro', now() + interval '31 days','sub_123','$T1'::uuid)::text")"
chk "she is on Pro"            "pro"    "$(as $U1 "select my_billing()->>'plan'")"
chk "and shows as subscribed"  "true"   "$(as $U1 "select my_billing()->>'subscribed'")"
chk "her customer is recorded" "cus_123" "$(as $U1 "select my_billing()->>'customer'")"

has "a later event matches on the customer alone" '"plan": "pro"' \
    "$(as $U1 "select set_plan('cus_123','pro', now() + interval '62 days')::text")"
has "an unknown customer is refused" "no studio for customer" \
    "$(as $U1 "select set_plan('cus_nobody','pro')::text")"
has "an unknown plan is refused" "unknown plan" \
    "$(as $U1 "select set_plan('cus_123','platinum')::text")"

echo
echo "-- nothing privileged is reachable from the app role --"
for fn in "next_mail(5)" "queue_reminders()" "expire_plans()" "queue_mail_for(gen_random_uuid(),false)"; do
  has "  $fn is denied" "permission denied" "$(asrole $U1 "select $fn")"
done
has "  setting() is denied" "permission denied" "$(asrole $U1 "select setting('site_url')")"
chk "  and the outbox itself reads empty" "0" "$(asrole $U1 "select count(*) from mail_outbox")"
has "  a secret key cannot be read back even as owner" "" \
    "$(as $U1 "select coalesce((select value from platform_setting where key='service_role_key'),'')")"

echo
echo "-- one studio's plan is its own --"
chk "the other studio is untouched" "free" "$(as $U2 "select my_billing()->>'plan'")"
chk "my_billing shows a stranger nothing" "" "$(asrole $U2 "select my_billing()->>'customer'")"

echo
echo "-- cancelling at period end --"
as $U1 "select set_plan('cus_123','pro', now() - interval '1 hour')" > /dev/null
chk "she is still on Pro until it actually lapses, by the column" "pro" \
    "$(as $U1 "select plan from tenant where id='$T1'")"
chk "the sweep finds the one that lapsed" "1" "$(as $U1 "select expire_plans()")"
chk "and she is back on Free"             "free" "$(as $U1 "select my_billing()->>'plan'")"
chk "a second sweep finds nothing"        "0" "$(as $U1 "select expire_plans()")"

as $U1 "select set_plan('cus_123','pro', now() + interval '30 days')" > /dev/null
chk "a studio paid up is not swept" "0" "$(as $U1 "select expire_plans()")"
chk "and stays on Pro"              "pro" "$(as $U1 "select my_billing()->>'plan'")"

echo
echo "-- what checkout needs --"
C=$(as $U1 "select my_tenant_for_checkout()::text")
has "it knows the studio"   "Studio Mila"       "$C"
has "and her email"         "ellie@example.com" "$C"
has "and her customer id"   "cus_123"           "$C"

[ $fail = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

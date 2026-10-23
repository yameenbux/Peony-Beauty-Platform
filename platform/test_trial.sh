#!/bin/bash
# The trial notice: she hears before it ends, once, and only if it matters.
#
# Before 031 nothing at all happened between create_studio handing her a
# fourteen-day Pro+ trial and expire_plans() dropping her to free. The first
# she knew was a client turning up without having paid a deposit she thought
# was still being collected.
#
#   ./test_trial.sh      # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-trial-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55493 PGUSER=test PGDATABASE=bookedin
U1=11111111-1111-1111-1111-111111111111
U2=22222222-2222-2222-2222-222222222222
U3=33333333-3333-3333-3333-333333333333

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

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
want()  { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
# plan, plan_until and trial_until are guarded: guard_billing_columns refuses a
# direct write unless bookedin.billing_write is on for the transaction, which is
# how expire_plans() and set_plan() do it. Without this the updates below are
# silently refused and every assertion passes or fails for the wrong reason.
billing() { psql -q -c "select set_config('bookedin.billing_write','on',true); $1" >/dev/null 2>&1; }
has()   { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()    { case "$3" in *"$2"*) echo "FAIL $1 -> found '$2'"; fail=1;; *) echo "ok   $1";; esac; }

APPLY() { for f in "$@"; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }; done; }
APPLY 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
      008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
      014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
      020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease \
      025_paylink 026_trigger_privilege 027_patch_test_seed 028_trade_palette \
      029_slot_taken_readonly 030_launch_hardening
echo "ok   001-030 apply"

psql -q -c "insert into auth.users values
            ('$U1','ellie@example.com'),('$U2','jo@example.com'),('$U3','sam@example.com')" >/dev/null
as $U1 "select create_studio('studio-mila','Studio Mila','lashes')"  >/dev/null
as $U2 "select create_studio('nails-by-jo','Nails by Jo','nails')"   >/dev/null
as $U3 "select create_studio('sams-barbers','Sams Barbers','barber')" >/dev/null
T1=$(plain "select id from tenant where slug='studio-mila'")
T2=$(plain "select id from tenant where slug='nails-by-jo'")
T3=$(plain "select id from tenant where slug='sams-barbers'")

want "signup puts her on a Pro+ trial" "pro_plus" \
     "$(plain "select plan from tenant where slug='studio-mila'")"
want "and the trial is a real plan_state" "trialing" \
     "$(plain "select plan_state(plan,plan_until,trial_until,stripe_subscription_id)
                 from tenant where slug='studio-mila'")"

echo
echo "-- before 031: she is told nothing, and then it just stops --"
want "nothing is queued for her, ever" "0" \
     "$(plain "select count(*) from mail_outbox where to_email='ellie@example.com'")"
billing "update tenant set plan_until = now() - interval '1 minute',
                              trial_until = now() - interval '1 minute'
             where id='$T1'::uuid"
want "expire_plans drops her without a word" "1" "$(plain "select expire_plans()")"
want "she is on free now" "free" "$(plain "select plan from tenant where slug='studio-mila'")"
want "and still nothing was ever sent" "0" \
     "$(plain "select count(*) from mail_outbox where to_email='ellie@example.com'")"
echo "     ^ that is the gap, on an unpatched schema"

echo
echo "-- 031 --"
APPLY 031_trial_notice
echo "ok   031 applies"

# Jo's trial ends in two days; Sam's in ten.
billing "update tenant set plan_until  = now() + interval '2 days',
                              trial_until = now() + interval '2 days'
             where id='$T2'::uuid"
billing "update tenant set plan_until  = now() + interval '10 days',
                              trial_until = now() + interval '10 days'
             where id='$T3'::uuid"

want "one studio is close enough to hear about it" "1" "$(plain "select queue_trial_notices()")"
want "and it went to her, not to a client" "1" \
     "$(plain "select count(*) from mail_outbox where to_email='jo@example.com'
                 and kind='studio_trial_ending'")"
want "the one ten days out is left alone" "0" \
     "$(plain "select count(*) from mail_outbox where to_email='sam@example.com'")"
want "running it again sends nothing" "0" "$(plain "select queue_trial_notices()")"
want "so she gets exactly one" "1" \
     "$(plain "select count(*) from mail_outbox where to_email='jo@example.com'")"

echo
echo "-- what it actually says --"
B=$(plain "select body from mail_outbox where to_email='jo@example.com'")
has "it opens with her studio's name"        "Hi Nails by Jo"        "$B"
has "it says her page is not going anywhere" "Nothing disappears"    "$B"
has "it says patch tests stay enforced"      "Patch tests stay enforced" "$B"
has "it lists deposits among what stops"     "Deposits paid straight to you" "$B"
has "and the insurance pack"                 "insurance pack"        "$B"
has "it links her to her plan"               "/app/"                 "$B"
has "it tells her doing nothing is allowed"  "do not need to do anything" "$B"
no  "it does not threaten her page"          "will be deleted"       "$B"
has "the subject carries the date"           "trial ends on"         \
    "$(plain "select subject from mail_outbox where to_email='jo@example.com'")"

echo
echo "-- it only goes to somebody it is true for --"
# A studio who has already paid is not on a trial, whatever the dates say.
billing "update tenant set stripe_subscription_id='sub_live',
                              plan_until = now() + interval '1 day'
             where id='$T3'::uuid"
want "a paying studio is never told her trial is ending" "0" "$(plain "select queue_trial_notices()")"
want "nothing reached her" "0" \
     "$(plain "select count(*) from mail_outbox where to_email='sam@example.com'")"
# And a studio already dropped to free has nothing left to warn about.
want "nor is the one whose trial already ran out" "0" \
     "$(plain "select count(*) from mail_outbox where to_email='ellie@example.com'")"

echo
echo "-- a second trial earns a second notice --"
billing "update tenant set plan='pro_plus',
                              plan_until  = now() + interval '2 days',
                              trial_until = now() + interval '2 days',
                              stripe_subscription_id = null
             where id='$T1'::uuid"
want "she is told about the new one" "1" "$(plain "select queue_trial_notices()")"
want "keyed on the trial, not just the studio" "1" \
     "$(plain "select count(*) from trial_notice where tenant_id='$T1'::uuid")"

echo
echo "-- and it is not anybody's to call --"
want "lockdown is unchanged at 31" "31" "$(plain "select lockdown()")"
want "a studio cannot queue trial mail" "f" \
     "$(plain "select has_function_privilege('authenticated','public.queue_trial_notices(int)','EXECUTE')")"
want "nor can a visitor" "f" \
     "$(plain "select has_function_privilege('anon','public.queue_trial_notices(int)','EXECUTE')")"
want "and the dedupe table is closed to both" "f" \
     "$(plain "select has_table_privilege('anon','public.trial_notice','SELECT')")"

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

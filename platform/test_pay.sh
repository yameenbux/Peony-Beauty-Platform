#!/bin/bash
# Money up front, the window to cancel, and fourteen days of Pro+.
#
# Three things this file is really asserting, because all three are promises
# made to somebody who is not the customer:
#
#   - the amount asked for is never more than the treatment costs, and the
#     word used for it ("deposit" or the whole price) matches the number;
#   - the confirmation email says what is ACTUALLY true at the moment it is
#     sent, which is what is due - not "paid", because nothing has been;
#   - a trial that ends leaves a studio on Free with its bookings intact.
#
#   ./test_pay.sh              # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-pay-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55471 PGUSER=test PGDATABASE=bookedin
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
  -c "create role anon" -c "create role authenticated" || exit 1
for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
         014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector 020_pay; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
# The billing columns are trigger-guarded, so a test that moves a plan has to
# say so the same way the billing functions do.
bill()  { psql -qtA -c "set bookedin.billing_write='on'; $1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()  { case "$3" in *"$2"*) echo "FAIL $1 -> $3"; fail=1;; *) echo "ok   $1";; esac; }
psql -q -c "insert into auth.users values
            ('$U1','jay@example.com'),('$U2','nads@example.com'),('$U3','kim@example.com')" >/dev/null

echo "-- 1. she starts on Pro+, not on Free --"
as $U1 "select create_studio('fade-room','The Fade Room','barber')" > /dev/null
T1=$(plain "select id from tenant where slug='fade-room'")
chk "the plan is really pro_plus"        "pro_plus" "$(plain "select plan from tenant where id='$T1'")"
chk "so the Pro gate opens"              "t"  "$(plain "select is_pro(plan) from tenant where id='$T1'")"
chk "it runs for fourteen days"          "14" "$(plain "select round(extract(epoch from plan_until - now()) / 86400)::int from tenant where id='$T1'")"
chk "and it is marked as a trial"        "t"  "$(plain "select trial_until is not null from tenant where id='$T1'")"
chk "which is what the dashboard reads"  "trialing" \
    "$(plain "select plan_state(plan, plan_until, trial_until, stripe_subscription_id) from tenant where id='$T1'")"

echo
echo "-- 2. and day fifteen needs no new machinery --"
# expire_plans() is the hourly sweep that was already there for lapsed cards.
# A trial is a plan with an end date, so it is swept by the same query.
bill "update tenant set plan_until = now() - interval '1 minute' where id='$T1'" >/dev/null
chk "the existing sweep catches it"      "1"    "$(plain "select expire_plans()")"
chk "she is on Free"                     "free" "$(plain "select plan from tenant where id='$T1'")"
chk "and the news says which Free it is" "trial_over" \
    "$(plain "select plan_state(plan, plan_until, trial_until, stripe_subscription_id) from tenant where id='$T1'")"
# The distinction that matters for the sentence shown: a card that lapsed is
# not a trial that ended, and somebody paying is neither.
bill "update tenant set stripe_subscription_id='sub_123', plan='pro_plus',
      plan_until = now() + interval '30 days' where id='$T1'" >/dev/null
chk "a paying studio is just paying"     "paying" \
    "$(plain "select plan_state(plan, plan_until, trial_until, stripe_subscription_id) from tenant where id='$T1'")"
chk "and a studio that never trialled"   "free" \
    "$(plain "select plan_state('free', null, null, null)")"

echo
echo "-- 3. the cancellation window comes from the trade --"
as $U2 "select create_studio('nails-by-nads','Nails by Nads','nails')" > /dev/null
as $U3 "select create_studio('ivy-hair','Ivy Hair','hair')"            > /dev/null
T2=$(plain "select id from tenant where slug='nails-by-nads'")
T3=$(plain "select id from tenant where slug='ivy-hair'")
chk "a barber holds it for four hours"   "4"   "$(plain "select cancel_hours from tenant where id='$T1'")"
chk "nails for a day"                    "24"  "$(plain "select cancel_hours from tenant where id='$T2'")"
chk "hair for two"                       "48"  "$(plain "select cancel_hours from tenant where id='$T3'")"
chk "and a brow tattoo for a week"       "168" "$(plain "select trade_cancel_hours('pmu')")"
chk "a trade nobody listed gets a day"   "24"  "$(plain "select trade_cancel_hours('something-else')")"
# What the client's own page is told, since the number is useless unless it
# reaches the person deciding whether to cancel.
chk "and her client is told the number"  "4"   "$(plain "select (get_studio('fade-room')->>'cancel_hours')::int")"

echo
echo "-- 4. what is asked for up front --"
# 'Skin fade' is one of the barber defaults create_studio already seeded, at
# exactly the £18 the trade table says. The other two are named so they cannot
# collide with a seeded one.
psql -q -c "insert into service (tenant_id, name, price_pence, duration_min, sort)
            values ('$T1','Test kids cut', 600, 20, 91),
                   ('$T1','Test chat',       0, 15, 92)" >/dev/null
# Somewhere for the money to go, which the database insists on before it will
# let her ask for any.
psql -q -c "update tenant set deposit_how='bank', deposit_name='J Patel',
            deposit_sort='04-00-04', deposit_account='12345678' where id='$T1'" >/dev/null
FADE=$(plain "select id from service where tenant_id='$T1' and name='Skin fade'")
KIDS=$(plain "select id from service where tenant_id='$T1' and name='Test kids cut'")
FREE=$(plain "select id from service where tenant_id='$T1' and name='Test chat'")
chk "the barber default is the £18 one" "1800" \
    "$(plain "select price_pence from service where id='$FADE'")"
pay()  { psql -q -c "update tenant set pay_mode='$1', deposit_pence=$2 where id='$T1'" >/dev/null; }
# Her own opening hours decide when anything can be booked, so the time comes
# from the calendar rather than from arithmetic on now(). Each booking is made
# on a cleared diary, so the first free slot is free every time.
slot() { plain "select min(at) from free_slots('fade-room','$1'::uuid,
                current_date, current_date + 14) as f(at)"; }
bk()   { psql -q -c "delete from booking where tenant_id='$T1'" >/dev/null
         plain "select ref from book('fade-room','$1','$(slot "$1")'::timestamptz,
                'Sam Ali','sam@example.com')"; }
kind() { plain "select pay_kind || ' ' || deposit_pence from booking where ref='$1'"; }

# The rule 017 established, which a new column could so easily have broken:
# the amount in her settings is the request. If she types £10 and has never
# heard of pay_mode, £10 is asked for.
chk "typing an amount is the whole switch"      "deposit 1000" \
    "$(psql -q -c "update tenant set deposit_pence=1000 where id='$T1'" >/dev/null; kind "$(bk $FADE)")"
chk "and clearing it stops the asking"          "none 0" \
    "$(psql -q -c "update tenant set deposit_pence=0 where id='$T1'" >/dev/null; kind "$(bk $FADE)")"
chk "a studio asking for nothing takes nothing" "none 0" \
    "$(pay none 1000; kind "$(bk $FADE)")"
chk "a deposit is a deposit"                    "deposit 1000" \
    "$(pay deposit 1000; kind "$(bk $FADE)")"
# The barber's whole point: he does not want £10 of £18, he wants £18.
chk "full payment is the whole price"           "full 1800" \
    "$(pay full 1000; kind "$(bk $FADE)")"
# The two places the word and the number could disagree, and must not.
chk "a deposit as big as the price is payment"  "full 600" \
    "$(pay deposit 1000; kind "$(bk $KIDS)")"
chk "and is never bigger than the price"        "full 600" \
    "$(pay full 1000; kind "$(bk $KIDS)")"
chk "a free consultation asks for nothing"      "none 0" \
    "$(pay full 1000; kind "$(bk $FREE)")"
chk "even when a deposit is configured"         "none 0" \
    "$(pay deposit 1000; kind "$(bk $FREE)")"
# Taking money up front is a Pro feature, and the gate is the plan itself.
bill "update tenant set plan='free', stripe_subscription_id=null where id='$T1'" >/dev/null
chk "and Free asks for nothing at all"          "none 0" \
    "$(pay full 1000; kind "$(bk $FADE)")"
bill "update tenant set plan='pro_plus', plan_until=now() + interval '30 days' where id='$T1'" >/dev/null

echo
echo "-- 5. three subjects, and all three true when they are sent --"
subj() { plain "select subject from mail_outbox where booking_id =
         (select id from booking where ref='$1') and kind='client_booked'"; }
pay none 0
R=$(bk $FADE)
has "nothing due says so"       "pay in person"       "$(subj $R)"
pay deposit 500
R=$(bk $FADE)
has "a deposit names the deposit" "£5.00 deposit to pay" "$(subj $R)"
pay full 0
R=$(bk $FADE)
has "the whole price names itself" "£18.00 to pay"     "$(subj $R)"
# The one email the product must not send: nobody has paid at this point.
no  "and none of them claims it is paid" "paid"        "$(subj $R)"
has "the body says what holds the slot"  "is due for this appointment" \
    "$(plain "select body from mail_outbox where booking_id =
              (select id from booking where ref='$R') and kind='client_booked'")"
pay deposit 500
R=$(bk $FADE)
has "and a deposit says it holds it"     "holds this appointment" \
    "$(plain "select body from mail_outbox where booking_id =
              (select id from booking where ref='$R') and kind='client_booked'")"

echo
echo "-- 6. the receipt, which did not exist before --"
B=$(plain "select id from booking where ref='$R'")
rc() { plain "select count(*) from mail_outbox where booking_id='$B' and kind='client_paid'"; }
chk "nothing is sent until she marks it" "0" "$(rc)"
as $U1 "select set_deposit_paid('$B', true)" > /dev/null
chk "then the client hears about it"     "1" "$(rc)"
has "and it is the deposit wording"      "Deposit received" \
    "$(plain "select subject from mail_outbox where booking_id='$B' and kind='client_paid'")"
has "with the rest still to come"        "rest is due on the day" \
    "$(plain "select body from mail_outbox where booking_id='$B' and kind='client_paid'")"
# Marking it twice, or correcting a mistake, must not re-email a person who
# has already been told.
as $U1 "select set_deposit_paid('$B', true)"  > /dev/null
chk "marking it again sends nothing"     "1" "$(rc)"
as $U1 "select set_deposit_paid('$B', false)" > /dev/null
as $U1 "select set_deposit_paid('$B', true)"  > /dev/null
chk "nor does unticking and re-ticking"  "1" "$(rc)"
has "and it is somebody else's booking"  "not yours" \
    "$(as $U2 "select set_deposit_paid('$B', true)")"
# Paid in full reads differently, because there is nothing left to pay.
pay full 0
R2=$(bk $FADE)
B2=$(plain "select id from booking where ref='$R2'")
as $U1 "select set_deposit_paid('$B2', true)" > /dev/null
has "full payment is receipted as paid"  "Paid in full" \
    "$(plain "select subject from mail_outbox where booking_id='$B2' and kind='client_paid'")"
has "with nothing else owed"             "Nothing else to pay" \
    "$(plain "select body from mail_outbox where booking_id='$B2' and kind='client_paid'")"

echo
echo "-- 7. what each page is allowed to read --"
TOK=$(plain "select cancel_token from booking where ref='$R2'")
chk "her client's page learns the kind"  "full" \
    "$(plain "select get_booking('$R2','$TOK'::uuid)->'deposit'->>'kind'")"
chk "and the amount"                     "1800" \
    "$(plain "select get_booking('$R2','$TOK'::uuid)->'deposit'->>'pence'")"
chk "her public page knows to ask"       "full" \
    "$(plain "select get_studio('fade-room')->>'pay_mode'")"
chk "her own page knows about the trial" "trialing" \
    "$(as $U1 "select my_studio()->>'plan_state'")"
# A public page must never be told what she pays us or whether she is trialling.
no  "but the public page is told neither" "plan_state" \
    "$(plain "select get_studio('fade-room')::text")"
no  "nor her trial end date"              "trial_until" \
    "$(plain "select get_studio('fade-room')::text")"
# On Free the public page must not advertise a payment she cannot take.
bill "update tenant set plan='free', plan_until=null where id='$T1'" >/dev/null
chk "and Free advertises nothing"        "none" \
    "$(plain "select get_studio('fade-room')->>'pay_mode'")"
bill "update tenant set plan='pro_plus', plan_until=now() + interval '30 days' where id='$T1'" >/dev/null

echo
echo "-- 8. and the thing all of this sits on top of --"
# 019 widened the overlap guarantee to a multirange. Everything above changed
# the booking table again, so the oldest promise in the product gets re-proven
# on the finished stack.
psql -q -c "delete from booking where tenant_id='$T1'" >/dev/null
S=$(slot $FADE)
has "one person gets the chair" "8" \
    "$(plain "select length(ref) from book('fade-room','$FADE','$S'::timestamptz,
              'First In','first@example.com')")"
has "the next is turned away"   "just took that time" \
    "$(plain "select ref from book('fade-room','$FADE','$S'::timestamptz,
              'Too Slow','slow@example.com')")"
chk "so the slot holds one"     "1" \
    "$(plain "select count(*) from booking where tenant_id='$T1' and status='confirmed'")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

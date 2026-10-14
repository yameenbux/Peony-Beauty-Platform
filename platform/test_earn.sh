#!/bin/bash
# The four things Pro+ does for her business.
#
# Each of these sends email on somebody else's behalf or writes bookings into
# her diary, so most of this file is about restraint: told once, never to
# somebody who opted out, never to another studio's clients, and never offering
# a slot that cannot actually be taken.
#
#   ./test_earn.sh           # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-earn-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55449 PGUSER=test PGDATABASE=bookedin
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
         014_patch 015_venue 016_proplus 017_deposits 018_earn; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/apply.log" 2>&1 \
    || { echo "FAIL $f does not apply"; grep -i "error" "$DIR/apply.log" | head -3; exit 1; }
done
echo "ok   the migration applies"

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
no()  { case "$3" in *"$2"*) echo "FAIL $1 -> $3"; fail=1;; *) echo "ok   $1";; esac; }

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
T=$(plain "select id from tenant where slug='studio-mila'")
SVC=$(plain "select id from service where tenant_id='$T' limit 1")
psql -q -c "update tenant set notice_hours=0, patch_valid_months=6 where id='$T'" \
     -c "update service set duration_min=15, patch_test_hours=48 where tenant_id='$T'" \
     -c "delete from opening where tenant_id='$T'" \
     -c "insert into opening (tenant_id,weekday,starts,ends)
         select '$T', g, '00:00','23:59' from generate_series(0,6) g" \
     -c "select set_plan(null,'pro_plus',null,null,'$T'::uuid)" > /dev/null
at() { echo "(date_trunc('hour', now()) + interval '$1 hours')"; }
# A treatment that needs no test, for the sections about booking mechanics.
# studio_book() honours require_patch_test the same as her page does, which is
# right - it is her insurance - but it would otherwise be the thing under test
# in every assertion below.
# Nulled explicitly after the insert: 014 puts a BEFORE INSERT trigger on
# service that seeds the trade's patch-test window, so a new treatment in a
# lashes studio arrives needing one whether you asked for it or not.
psql -q -c "insert into service (tenant_id,name,price_pence,duration_min,sort)
            values ('$T','Brow wax',1500,15,8)" > /dev/null
psql -q -c "update service set patch_test_hours = null
            where tenant_id='$T' and name='Brow wax'" > /dev/null
WAX=$(plain "select id from service where tenant_id='$T' and name='Brow wax'")

echo
echo "-- 1. a client whose patch test has run out --"
# She has been, so there is a client row; her test is seven months old.
psql -q -c "insert into client (tenant_id,name,email) values
            ('$T','Ruby Hall','ruby@example.com'),('$T','Sian Price','sian@example.com')" > /dev/null
RC=$(plain "select id from client where email='ruby@example.com'")
SC=$(plain "select id from client where email='sian@example.com'")
psql -q -c "insert into patch_test (tenant_id,client_id,tested_at)
            values ('$T','$RC', now() - interval '7 months')" \
     -c "insert into patch_test (tenant_id,client_id,tested_at)
            values ('$T','$SC', now() - interval '1 month')" > /dev/null
chk "the one who has lapsed is nudged, the one still covered is not" "1" \
    "$(plain "select queue_patch_nudges()")"
has "and told whose it was" "Studio Mila" \
    "$(plain "select body from mail_outbox where kind='client_patch'")"
has "and given a way to come off the list" "manage.html?u=" \
    "$(plain "select body from mail_outbox where kind='client_patch'")"
chk "told once, not every time the job runs" "0" "$(plain "select queue_patch_nudges()")"

# Re-testing her is a new expiry, so a new nudge is right when THAT lapses.
psql -q -c "delete from mail_outbox" > /dev/null
psql -q -c "update patch_test set tested_at = now() - interval '6 months' - interval '1 day'
            where client_id='$RC'" > /dev/null
chk "a fresh test that has since lapsed earns a fresh nudge" "1" \
    "$(plain "select queue_patch_nudges()")"

psql -q -c "delete from mail_outbox" -c "delete from patch_nudge" > /dev/null
psql -q -c "update client set rebook_opt_out = true where id='$RC'" > /dev/null
chk "somebody who opted out of being chased is not chased about this either" "0" \
    "$(plain "select queue_patch_nudges()")"
psql -q -c "update client set rebook_opt_out = false where id='$RC'" > /dev/null

# A booking in the diary means she is coming anyway.
psql -q -c "insert into booking (tenant_id,service_id,starts_at,ends_at,client_id,
              client_name,client_email,ref,status) values ('$T','$WAX',$(at 30),
              $(at 30) + interval '15 min','$RC','Ruby Hall','ruby@example.com',
              'AHEAD001','confirmed')" > /dev/null
chk "nor is somebody who already has an appointment" "0" \
    "$(plain "select queue_patch_nudges()")"
psql -q -c "delete from booking" > /dev/null

psql -q -c "select set_plan(null,'pro',null,null,'$T'::uuid)" > /dev/null
chk "and Pro does not get this at all" "0" "$(plain "select queue_patch_nudges()")"
psql -q -c "select set_plan(null,'pro_plus',null,null,'$T'::uuid)" > /dev/null

echo
echo "-- 2. a cancellation goes to the people waiting --"
psql -q -c "delete from mail_outbox" -c "delete from patch_nudge" > /dev/null
has "anyone can join from her page" "\"on_list\": true" \
    "$(web "select join_waitlist('studio-mila','$WAX'::uuid,'Leah Byrne','leah@example.com','Any evening')")"
web "select join_waitlist('studio-mila',null,'Nina Okafor','nina@example.com',null)" > /dev/null
chk "two people are waiting" "2" "$(plain "select count(*) from waitlist where tenant_id='$T'")"
has "joining twice does not put her on twice" "\"on_list\": true" \
    "$(web "select join_waitlist('studio-mila','$WAX'::uuid,'Leah Byrne','leah@example.com',null)")"
chk "still two" "2" "$(plain "select count(*) from waitlist where tenant_id='$T'")"
no  "and nobody can read the list from the web" "leah@example.com" \
    "$(web "select coalesce(string_agg(email,','),'') from waitlist")"

R=$(plain "select ref from book('studio-mila','$WAX',$(at 40),'Amy Shaw','amy@example.com')")
B=$(plain "select id from booking where ref='$R'")
psql -q -c "delete from mail_outbox" > /dev/null
psql -q -c "update booking set status='cancelled', cancelled_by='client' where id='$B'" > /dev/null
chk "cancelling tells both of them" "2" \
    "$(plain "select count(*) from mail_outbox where kind='client_waitlist'")"
has "with the time that came free" "has come free" \
    "$(plain "select subject from mail_outbox where kind='client_waitlist' limit 1")"
has "and a way off the list" "manage.html?w=" \
    "$(plain "select body from mail_outbox where kind='client_waitlist' limit 1")"

# Not again this week, whatever else frees up.
R2=$(plain "select ref from book('studio-mila','$WAX',$(at 44),'Jo Blake','jo@example.com')")
B2=$(plain "select id from booking where ref='$R2'")
psql -q -c "delete from mail_outbox" > /dev/null
psql -q -c "update booking set status='cancelled', cancelled_by='client' where id='$B2'" > /dev/null
chk "a second cancellation the same week tells nobody twice" "0" \
    "$(plain "select count(*) from mail_outbox where kind='client_waitlist'")"

# Nothing is offered that cannot be taken.
psql -q -c "update waitlist set notified_at = null" > /dev/null
psql -q -c "delete from mail_outbox" > /dev/null
psql -q -c "insert into booking (tenant_id,service_id,starts_at,ends_at,client_name,
              client_email,ref,status) values ('$T','$WAX', now() - interval '2 days',
              now() - interval '2 days' + interval '15 min','Past Client','past@example.com',
              'PAST1234','confirmed')" > /dev/null
psql -q -c "update booking set status='cancelled' where ref='PAST1234'" > /dev/null
chk "a slot in the past is not an opportunity" "0" \
    "$(plain "select count(*) from mail_outbox where kind='client_waitlist'")"

# Her own view of the list. Through a function, so the plan gate travels with
# the feature: RLS can say "her rows" but not "only while she pays for them".
# Her earlier re-join cleared her note, which is right - a second join says
# what she wants NOW - so put one back before reading the list.
web "select join_waitlist('studio-mila','$WAX'::uuid,'Leah Byrne','leah@example.com','Any evening')" > /dev/null
has "she can read her own list" "Leah Byrne" "$(as $U1 "select my_waitlist()")"
has "with what they asked for" "Any evening" "$(as $U1 "select my_waitlist()")"
has "and the treatment they are waiting on" "Brow wax" "$(as $U1 "select my_waitlist()")"
chk "and nobody else's" "[]" "$(as $U2 "select my_waitlist()")"
no  "nor can the web read it" "Leah Byrne" "$(web "select my_waitlist()")"
psql -q -c "select set_plan(null,'pro',null,null,'$T'::uuid)" > /dev/null
chk "and dropping to Pro closes it, rather than leaving it open" "[]" \
    "$(as $U1 "select my_waitlist()")"
psql -q -c "select set_plan(null,'pro_plus',null,null,'$T'::uuid)" > /dev/null

LT=$(plain "select token from waitlist where email='leah@example.com'")
has "and she can take herself off" "\"left\": true" "$(web "select leave_waitlist('$LT'::uuid)")"
chk "which removes her" "1" "$(plain "select count(*) from waitlist where tenant_id='$T'")"

psql -q -c "select set_plan(null,'pro',null,null,'$T'::uuid)" > /dev/null
has "a Pro studio takes no waiting list" "not taking a waiting list" \
    "$(web "select join_waitlist('studio-mila','$WAX'::uuid,'Mia King','mia@example.com',null)")"
psql -q -c "select set_plan(null,'pro_plus',null,null,'$T'::uuid)" > /dev/null

echo
echo "-- 3. she can book somebody in herself --"
psql -q -c "delete from booking" > /dev/null
has "a phone booking goes straight in" "8" \
    "$(as $U1 "select length(ref) from studio_book('$WAX'::uuid,$(at 50),'Phone Caller','phone@example.com')")"
has "but not into somebody else's diary" "not yours" \
    "$(as $U2 "select ref from studio_book('$WAX'::uuid,$(at 51),'Nope','no@example.com')")"
has "and not over the top of something" "already have something" \
    "$(as $U1 "select ref from studio_book('$WAX'::uuid,$(at 50),'Clash','clash@example.com')")"

echo
echo "-- and the next six in one go --"
psql -q -c "delete from booking" > /dev/null
SER=$(as $U1 "select book_series('$WAX'::uuid,$(at 60),3,6,'Ruby Hall','ruby@example.com')")
chk "six went in" "6" "$(plain "select count(*) from booking where client_email='ruby@example.com'")"
has "and she is told which" "\"booked\"" "$SER"
chk "three weeks apart" "21" \
    "$(plain "select extract(day from (max(starts_at)-min(starts_at)))::int / 5
              from booking where client_email='ruby@example.com'")"

# One already taken: the series must skip it, not fall over.
psql -q -c "delete from booking" > /dev/null
as $U1 "select studio_book('$WAX'::uuid,$(at 60) + interval '6 weeks','Someone Else','else@example.com')" > /dev/null
SER=$(as $U1 "select book_series('$WAX'::uuid,$(at 60),3,4,'Ruby Hall','ruby@example.com')")
chk "a clash in the middle skips one and books the rest" "3" \
    "$(plain "select count(*) from booking where client_email='ruby@example.com'")"
has "and says which one it could not do" "\"skipped\"" "$SER"
has "and why" "already have something" "$SER"

has "more than twelve is refused" "Between 1 and 12" \
    "$(as $U1 "select book_series('$WAX'::uuid,$(at 70),3,20,'X','x@example.com')")"
psql -q -c "select set_plan(null,'pro',null,null,'$T'::uuid)" > /dev/null
has "and a Pro studio does not get a series" "part of Pro+" \
    "$(as $U1 "select book_series('$WAX'::uuid,$(at 70),3,4,'X','x@example.com')")"
has "though she can still book one by hand" "8" \
    "$(as $U1 "select length(ref) from studio_book('$WAX'::uuid,$(at 71),'One Off','one@example.com')")"
psql -q -c "select set_plan(null,'pro_plus',null,null,'$T'::uuid)" > /dev/null

echo
echo "-- 4. what an hour of her time is worth --"
# Only these two active, so the ordering assertion is about the two rates under
# test rather than about whatever the trade seed happened to put in.
psql -q -c "update service set active = false where tenant_id='$T'" \
     -c "update service set name='Russian infills', price_pence=4000, duration_min=90,
         active = true where id='$SVC'" \
     -c "insert into service (tenant_id,name,price_pence,duration_min,sort)
         values ('$T','Brow lamination',3500,60,2)" > /dev/null
E=$(as $U1 "select my_earnings()")
has "it works out the hourly rate" "per_hour_pence" "$E"
has "£35 for an hour is £35 an hour" "3500" "$E"
has "and £40 for ninety minutes is £26.67" "2667" "$E"
# Best-paying first, because the list is an argument rather than a catalogue.
chk "the best-paying treatment is named first" "Brow lamination" \
    "$(as $U1 "select my_earnings()->'treatments'->0->>'name'")"
chk "and another studio's owner sees none of it" "0" \
    "$(as $U2 "select jsonb_array_length(my_earnings()->'treatments')")"

echo
echo "-- nothing earlier was disturbed --"
chk "there is still exactly one book()" "1" \
    "$(plain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='book'")"
has "and a client booking still goes through the caps" "could not take that booking" \
    "$(plain "select ref from book('studio-mila','$SVC',$(at 80),'Bot','bot@example.com',null,'http://spam')")"

echo
if [ $fail -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

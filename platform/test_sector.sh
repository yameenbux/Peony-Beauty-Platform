#!/bin/bash
# Every trade, not just the one the product was built around.
#
# The headline here is hair. The patch-test guess - which is the whole
# marketing position - used to miss hair colour entirely: 'Full head
# highlights' was a seeded default and asked for no test at all. Most of this
# file is about colour, because that is the allergen behind the serious cases
# and it was the one case the product did not cover.
#
# The rest is the hole in the middle of a colour appointment. A booking that
# occupies two spans with a bookable gap between them is a change to the
# overlap guarantee, so these assertions care as much about what STILL cannot
# happen as about what now can.
#
#   ./test_sector.sh           # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-sector-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55451 PGUSER=test PGDATABASE=bookedin
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
         014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
web()   { psql -qtA -c "set role web_user; $1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()  { case "$3" in *"$2"*) echo "FAIL $1 -> $3"; fail=1;; *) echo "ok   $1";; esac; }
at()  { echo "(date_trunc('hour', now()) + interval '$1 hours')"; }
psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')" > /dev/null
psql -q -c "create role web_user" -c "grant anon to web_user" > /dev/null

echo "-- 1. hair colour asks for a test, which it never used to --"
for s in 'Full head highlights' 'Balayage' 'Bleach & tone' 'Colour & cut' \
         'Root tint' 'Permanent colour' 'Babylights' 'Toner refresh' 'T-section foils'; do
  chk "  hair: $s" "48" "$(plain "select guess_patch_hours('hair','$s')")"
done
chk "  but a dry cut does not"   ""   "$(plain "select guess_patch_hours('hair','Cut & blow dry')")"
chk "  nor a blow dry"           ""   "$(plain "select guess_patch_hours('hair','Blow dry')")"
chk "  barber: beard tint does"  "48" "$(plain "select guess_patch_hours('barber','Beard tint')")"
chk "  barber: a skin fade does not" "" "$(plain "select guess_patch_hours('barber','Skin fade')")"

echo
echo "-- and nothing else started asking --"
chk "  a nail gloss is a top coat, not a colour" "" \
    "$(plain "select guess_patch_hours('nails','Gloss manicure')")"
chk "  BIAB still asks for nothing"              "" \
    "$(plain "select guess_patch_hours('nails','BIAB full set')")"
chk "  a massage asks for nothing"               "" \
    "$(plain "select guess_patch_hours('massage','Deep tissue')")"
chk "  a facial asks for nothing"                "" \
    "$(plain "select guess_patch_hours('skin','Signature facial')")"
chk "  a peel does"                            "48" \
    "$(plain "select guess_patch_hours('skin','Chemical peel')")"
chk "  pigment under the skin always does"     "48" \
    "$(plain "select guess_patch_hours('pmu','Powder brows')")"
chk "  lashes are unchanged"                   "48" \
    "$(plain "select guess_patch_hours('lashes','Classic full set')")"
chk "  and a removal is still nothing"           "" \
    "$(plain "select guess_patch_hours('nails','Soak off & removal')")"

echo
echo "-- 2. the studios that already exist get corrected, carefully --"
as $U1 "select create_studio('salon-ivy','Salon Ivy','hair')" > /dev/null
T1=$(plain "select id from tenant where slug='salon-ivy'")
psql -q -c "update tenant set notice_hours=0 where id='$T1'" > /dev/null
# Put the whole list back to what 014 would have left behind, then correct it.
psql -q -c "update service set patch_test_hours = case
              when name ilike '%tint%' or name ilike '%perm%' then 48 else null end
            where tenant_id='$T1'" > /dev/null
# ...except one she set herself, which must survive untouched.
psql -q -c "update service set patch_test_hours = 24
            where tenant_id='$T1' and name='Balayage'" > /dev/null
chk "before: highlights asked for nothing" "" \
    "$(plain "select coalesce(patch_test_hours::text,'') from service
              where tenant_id='$T1' and name='Full head highlights'")"
N=$(plain "select reguess_patch_hours()")
# Root tint already said 48 under the old rules (it matched the lash-tint
# pattern), and Balayage is hers. So exactly two move: highlights and cut &
# colour - the two that silently asked for nothing.
chk "exactly the two that were wrong are corrected" "2" "$N"
chk "  highlights now asks for 48" "48" \
    "$(plain "select patch_test_hours from service where tenant_id='$T1' and name='Full head highlights'")"
chk "  cut & blow dry still asks for nothing" "" \
    "$(plain "select coalesce(patch_test_hours::text,'') from service
              where tenant_id='$T1' and name='Cut & blow dry'")"
chk "  and the 24 she typed herself is left alone" "24" \
    "$(plain "select patch_test_hours from service where tenant_id='$T1' and name='Balayage'")"
chk "running it twice changes nothing more" "0" "$(plain "select reguess_patch_hours()")"

echo
echo "-- 3. every trade starts with a list, and 'other' is no longer a cliff --"
for tr in lashes brows nails hair barber skin massage tanning makeup waxing pmu; do
  N=$(plain "select count(*) from trade_seed where trade='$tr'")
  if [ "$N" -ge 2 ]; then echo "ok   $tr starts with $N treatments"
  else echo "FAIL $tr starts with $N"; fail=1; fi
done
chk "a tenant cannot be given a trade that does not exist" "violates check constraint" \
    "$(plain "update tenant set trade='astrology' where id='$T1'" | grep -o 'violates check constraint')"
as $U2 "select create_studio('bare-canvas','Bare Canvas','pmu')" > /dev/null
T2=$(plain "select id from tenant where slug='bare-canvas'")
chk "a PMU artist gets her own list, not an empty one" "3" \
    "$(plain "select count(*) from service where tenant_id='$T2'")"
chk "and it is already patch tested" "48" \
    "$(plain "select patch_test_hours from service where tenant_id='$T2' and name='Powder brows'")"
has "and her trade says what it is sold on" "Permanent makeup" \
    "$(plain "select trade_profile('pmu')")"
has "hair is sold on the gap, not on rebooking" '"lead": "gaps"' \
    "$(plain "select trade_profile('hair')")"
has "and a nail tech is told plainly that nothing needs a test" "nothing asks for one" \
    "$(plain "select trade_profile('nails')")"

echo
echo "-- 4. the hole in the middle of a colour --"
# Her day, her diary. A root tint is 90 minutes: 20 applying, 35 developing
# with the chair empty, 35 finishing.
TINT=$(plain "select id from service where tenant_id='$T1' and name='Root tint'")
CUT=$(plain  "select id from service where tenant_id='$T1' and name='Cut & blow dry'")
chk "a root tint carries its gap from the seed" "20|35" \
    "$(plain "select gap_after_min || '|' || gap_min from service where id='$TINT'")"
chk "a dry cut carries none"                    "|" \
    "$(plain "select coalesce(gap_after_min::text,'') || '|' ||
              coalesce(gap_min::text,'') from service where id='$CUT'")"
# Patch test off for this block: the point here is the shape of the time, and
# the test requirement is already proven above.
psql -q -c "update service set patch_test_hours=null where tenant_id='$T1'" > /dev/null

START=$(plain "select min(at) from free_slots('salon-ivy','$TINT'::uuid,
                 current_date, current_date + 14) as f(at)")
R=$(plain "select ref from book('salon-ivy','$TINT','$START','Nadia Shah','nadia@example.com')")
chk "the colour goes in" "8" "$(plain "select length('$R')")"
chk "and the booking remembers the shape it was sold at" "20|35" \
    "$(plain "select gap_after_min || '|' || gap_min from booking where ref='$R'")"
chk "which is two spans, not one" "2" \
    "$(plain "select array_length(array(select unnest(busy)), 1) from booking where ref='$R'")"

echo
echo "-- what can now be sold, and what still cannot --"
# The gap is 35 minutes, and slots are offered on her 15-minute grid from the
# time she opens. So the thing that fits is a short treatment starting half an
# hour in - not the hour-long cut, which is the mistake a human would make too.
psql -q -c "insert into service (tenant_id, name, price_pence, duration_min, sort)
            values ('$T1','Fringe trim', 1000, 20, 9)" > /dev/null
FRINGE=$(plain "select id from service where tenant_id='$T1' and name='Fringe trim'")
chk "a fringe trim needs no patch test" "" \
    "$(plain "select coalesce(patch_test_hours::text,'') from service where id='$FRINGE'")"

has "somebody can have the developing half hour" "8" \
    "$(plain "select length(ref) from book('salon-ivy','$FRINGE',
              '$START'::timestamptz + interval '30 minutes','Beth Cole','beth@example.com')")"
has "but not the twenty minutes of applying it" "just took that time" \
    "$(plain "select ref from book('salon-ivy','$FRINGE','$START','Ivy Clash','clash@example.com')")"
has "nor the finishing" "just took that time" \
    "$(plain "select ref from book('salon-ivy','$FRINGE',
              '$START'::timestamptz + interval '60 minutes','Late Clash','late@example.com')")"
has "and an hour-long cut does not fit in a 35 minute gap" "just took that time" \
    "$(plain "select ref from book('salon-ivy','$CUT',
              '$START'::timestamptz + interval '30 minutes','Too Long','long@example.com')")"
chk "so the chair holds two people in ninety minutes" "2" \
    "$(plain "select count(*) from booking where tenant_id='$T1' and status='confirmed'")"

echo
echo "-- and her page offers the gap the same way --"
psql -q -c "delete from booking where tenant_id='$T1'" > /dev/null
R2=$(plain "select ref from book('salon-ivy','$TINT','$START','Nadia Shah','nadia@example.com')")
chk "the gap is offered for a treatment that fits" "1" \
    "$(plain "select count(*) from free_slots('salon-ivy','$FRINGE'::uuid,
              current_date, current_date + 14) as f(at)
              where at = '$START'::timestamptz + interval '30 minutes'")"
chk "the applying time is not" "0" \
    "$(plain "select count(*) from free_slots('salon-ivy','$FRINGE'::uuid,
              current_date, current_date + 14) as f(at) where at = '$START'::timestamptz")"
chk "and neither is the finishing" "0" \
    "$(plain "select count(*) from free_slots('salon-ivy','$FRINGE'::uuid,
              current_date, current_date + 14) as f(at)
              where at = '$START'::timestamptz + interval '60 minutes'")"
chk "an hour-long cut is not offered the gap either" "0" \
    "$(plain "select count(*) from free_slots('salon-ivy','$CUT'::uuid,
              current_date, current_date + 14) as f(at)
              where at = '$START'::timestamptz + interval '30 minutes'")"
chk "and no second colour can start inside the first one's" "0" \
    "$(plain "select count(*) from free_slots('salon-ivy','$TINT'::uuid,
              current_date, current_date + 14) as f(at)
              where at = '$START'::timestamptz + interval '30 minutes'")"

echo "-- nothing that was true before stopped being true --"
chk "cancelling still frees the whole appointment" "1" \
    "$(plain "update booking set status='cancelled' where ref='$R2';
              select count(*) from free_slots('salon-ivy','$TINT'::uuid,
              current_date, current_date + 14) as f(at) where at = '$START'::timestamptz")"
chk "there is still exactly one book()" "1" \
    "$(plain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='book'")"
chk "and the overlap guarantee is still an exclusion constraint" "1" \
    "$(plain "select count(*) from pg_constraint
              where conname='booking_no_overlap' and contype='x'")"

echo
echo "-- 5. the original guarantee, re-proven on the final stack --"
# Every other suite pins itself to the migration it tests, which is right - but
# it means test_booking.sh proves the overlap rule against 001 and nothing
# proves it against 019, the migration that REPLACED the constraint. So the
# plain, ungapped case is re-run here, at the end of the stack.
psql -q -c "delete from booking where tenant_id='$T1'" > /dev/null
S2=$(plain "select min(at) from free_slots('salon-ivy','$CUT'::uuid,
            current_date, current_date + 14) as f(at)")
chk "a plain appointment goes in" "8" \
    "$(plain "select length(ref) from book('salon-ivy','$CUT','$S2','First In','first@example.com')")"
has "the same minute cannot be sold twice" "just took that time" \
    "$(plain "select ref from book('salon-ivy','$CUT','$S2','Second','second@example.com')")"
has "nor can a time that merely overlaps it" "just took that time" \
    "$(plain "select ref from book('salon-ivy','$CUT',
              '$S2'::timestamptz + interval '30 minutes','Partial','part@example.com')")"
chk "an ungapped booking is one span, as it always was" "1" \
    "$(plain "select array_length(array(select unnest(busy)), 1) from booking
              where tenant_id='$T1' and status='confirmed'")"
chk "and cancelling puts the time back on sale" "1" \
    "$(plain "update booking set status='cancelled' where tenant_id='$T1';
              select count(*) from free_slots('salon-ivy','$CUT'::uuid,
              current_date, current_date + 14) as f(at) where at = '$S2'::timestamptz")"
# The deadlock path is the one that cannot be provoked serially: two inserts
# can each write and then wait on the other's index check. It is handled in
# book() and must stay handled, so this asserts the handler is still there.
chk "book() still maps a deadlock to the same refusal" "1" \
    "$(plain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='book'
                and pg_get_functiondef(p.oid) like '%deadlock_detected%'")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

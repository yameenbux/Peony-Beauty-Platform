#!/bin/bash
# A barber's booking page should not be blush pink.
#
# brand_hex and logo_path have been in the schema since 013 and the booking
# page reads neither, so "your brand" has meant the Stories card and nothing
# her clients see. 028 gives every trade a default palette and carries it in
# trade_profile(), which get_studio() already embeds.
#
# The test that matters is the last one: every palette in the table has to be
# readable, measured in the database, against the six pairs app.css actually
# renders. A first attempt checked white-on-accent - a pair this product never
# draws - and "fixed" nine palettes against it.
#
#   ./test_palette.sh          # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-palette-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55499 PGUSER=test PGDATABASE=bookedin
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
         020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease \
         025_paylink 026_trigger_privilege 027_patch_test_seed; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done
echo "ok   001-027 apply"

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
anon()  { psql -qtA -c "set role anon; $1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

psql -q -c "insert into auth.users values ('$U1','ellie@example.com')" >/dev/null
as $U1 "select create_studio('crompton-and-co','Crompton & Co','barber')" > /dev/null

echo
echo "-- 1. before 028, every trade is the same pink --"
chk "  trade_profile carries no palette at all" "" \
    "$(plain "select trade_profile('barber')->>'palette'")"

echo
echo "-- 2. apply 028 --"
psql -q -v ON_ERROR_STOP=1 -f "$HERE/028_trade_palette.sql" > "$DIR/028.log" 2>&1 \
  || { echo "FAILED applying 028"; tail -8 "$DIR/028.log"; exit 1; }
echo "ok   028 applies, its own contrast check passed, and lockdown() passed"
psql -q -v ON_ERROR_STOP=1 -f "$HERE/028_trade_palette.sql" > "$DIR/028.again.log" 2>&1 \
  && echo "ok     and applies a second time too" \
  || { echo "FAIL   028 is not re-runnable"; tail -5 "$DIR/028.again.log"; fail=1; }

echo
echo "-- 3. the barber stops being pink --"
chk "every trade the wizard offers has a palette" "0" \
    "$(plain "select count(*) from (select distinct trade from trade_seed) s
               where trade_profile(s.trade)->'palette' is null")"
chk "  barber's accent is oxblood, not carmine" "#7E3038" \
    "$(plain "select trade_profile('barber')->'palette'->>'accent'")"
chk "  and its ink is slate, not plum"          "#1F262B" \
    "$(plain "select trade_profile('barber')->'palette'->>'ink'")"
chk "lashes is untouched, so nobody already open moves" "#B8465C" \
    "$(plain "select trade_profile('lashes')->'palette'->>'accent'")"
chk "an unknown trade still paints, falling back to other" "#B8465C" \
    "$(plain "select trade_profile('not-a-trade')->'palette'->>'accent'")"
chk "the palette carries all six roles" "accent, blush, deep, ground, ink, petal" \
    "$(plain "select string_agg(k, ', ' order by k)
                from jsonb_object_keys(trade_profile('barber')->'palette') k")"

echo
echo "-- 4. her client's page gets it in the one round trip it already makes --"
S=$(anon "select get_studio('crompton-and-co')")
has "get_studio carries the palette"  "7E3038"  "$S"
has "  and her brand hex to override" "brand_hex" "$S"
has "  and her logo"                  "logo_path" "$S"
chk "anon still cannot read the palette table directly" "f" \
    "$(plain "select has_table_privilege('anon','public.trade_palette','SELECT')
                and exists (select 1 from pg_policies
                             where tablename='trade_palette')")"

echo
echo "-- 5. THE ONE THAT MATTERS: an unreadable palette is refused --"
# Six pairs, measured in the database. This is what stops the next person
# adding a trade with a colour that looks lovely and cannot be read.
has "a low-contrast accent is rejected on insert" "not readable" \
    "$(plain "insert into trade_palette values
                ('aerial','#FFE800','#FFF000','#43192A','#FAEFF0','#F2D7DB','#FDFAFA')")"
has "  and the message says which pair" "accent on ground" \
    "$(plain "insert into trade_palette values
                ('aerial','#FFE800','#FFF000','#43192A','#FAEFF0','#F2D7DB','#FDFAFA')")"
has "updating a good palette to a bad one is refused too" "not readable" \
    "$(plain "update trade_palette set accent = '#FFE800' where trade = 'barber'")"
chk "  so barber is still oxblood" "#7E3038" \
    "$(plain "select accent from trade_palette where trade = 'barber'")"
chk "a readable palette is accepted" "1" \
    "$(plain "with i as (insert into trade_palette values
                ('aerial','#2A6F7A','#1E5058','#13282C','#ECF3F4','#CFE0E3','#FAFDFD')
                returning 1) select count(*) from i")"
chk "and every shipped palette passes the same check" "0" \
    "$(plain "select count(*) from trade_palette p where palette_unreadable(p) is not null")"

echo
echo "-- 6. the colour maths itself --"
chk "white on black is 21"   "21.00" "$(plain "select wcag_ratio('#FFFFFF','#000000')")"
chk "a colour against itself is 1" "1.00" "$(plain "select wcag_ratio('#B8465C','#B8465C')")"
chk "and it matches the figure 013 recorded for carmine under petal" "4.59" \
    "$(plain "select wcag_ratio('#B8465C','#FAEFF0')")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

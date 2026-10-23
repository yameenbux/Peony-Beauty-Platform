#!/bin/bash
# Erasure, and the one thing it must refuse to erase.
#
# A client can ask to be forgotten. The studio has to be able to do it, and
# she also has to still be able to defend a claim: a reaction she cannot
# produce a dated patch test for is a reaction her insurance may not cover.
# Article 17(3) is what makes both true at once, and 033 is what makes a lash
# technician not have to know that.
#
#   ./test_erasure.sh      # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-erasure-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55497 PGUSER=test PGDATABASE=bookedin
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
  -c "create role anon" -c "create role authenticated" -c "create role service_role" \
  -c "grant usage on schema public to anon, authenticated" || exit 1

fail=0
as()     { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
asrole() { psql -qtA -c "set test.uid='$1'; set role authenticated; $2" 2>&1 | tr -d '\n'; }
plain()  { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
want()   { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has()    { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()     { case "$3" in *"$2"*) echo "FAIL $1 -> still found '$2'"; fail=1;; *) echo "ok   $1";; esac; }

APPLY() { for f in "$@"; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }; done; }
APPLY 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
      008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
      014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
      020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease \
      025_paylink 026_trigger_privilege 027_patch_test_seed 028_trade_palette \
      029_slot_taken_readonly 030_launch_hardening 031_trial_notice \
      032_service_tables
echo "ok   001-032 apply"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')" >/dev/null
as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" >/dev/null
as $U2 "select create_studio('nails-by-jo','Nails by Jo','nails')"  >/dev/null
psql -q -c "update tenant set notice_hours=0, pay_mode='none'" >/dev/null 2>&1
PATCHSVC=$(plain "select id from service where name='Patch test'
                    and tenant_id=(select id from tenant where slug='studio-mila')")
LASHSVC=$(plain "select id from service where name<>'Patch test'
                   and tenant_id=(select id from tenant where slug='studio-mila') limit 1")

# Ruby: a patch test and a treatment. Nina: one old treatment and no test.
S1=$(plain "select min(f) from free_slots('studio-mila','$PATCHSVC'::uuid, current_date, current_date+14) f")
plain "select book('studio-mila','$PATCHSVC'::uuid,'$S1'::timestamptz,'Ruby Hall','ruby@example.com','07700 900111','','12 Mill Lane, Nuneaton CV11 4AA')" >/dev/null
RUBY=$(plain "select id from client where email='ruby@example.com'")
as $U1 "select add_patch_test('$RUBY'::uuid, now() - interval '2 days', 'slight redness, fine after an hour')" >/dev/null
# A treatment needing no test. Every seeded lash treatment needs one - Nina's
# booking was refused by the enforcement, which is the enforcement working -
# so she gets a brow tint top-up, inserted and then cleared of the hours the
# trade trigger guesses for it.
psql -q -c "insert into service (tenant_id, name, price_pence, duration_min, active)
            select id,'Brow tint top-up',1500,30,true from tenant where slug='studio-mila'" >/dev/null
NOTEST=$(plain "select id from service where name='Brow tint top-up'")
psql -q -c "update service set patch_test_hours=null, records_patch_test=false
             where id='$NOTEST'::uuid" >/dev/null
S2=$(plain "select min(f) from free_slots('studio-mila','$NOTEST'::uuid, current_date+3, current_date+20) f")
plain "select book('studio-mila','$NOTEST'::uuid,'$S2'::timestamptz,'Nina Patel','nina@example.com','07700 900222','','9 Oak Rise, Coventry')" >/dev/null
NINA=$(plain "select id from client where email='nina@example.com'")
[ -n "$NINA" ] || { echo "FAIL could not seed Nina"; exit 1; }
psql -q -c "update client set notes='allergic to the strong adhesive' where id='$RUBY'::uuid" >/dev/null
psql -q -v ON_ERROR_STOP=1 -c "insert into waitlist (tenant_id, service_id, name, email)
            select id,'$LASHSVC'::uuid,'Ruby Hall','ruby@example.com'
              from tenant where slug='studio-mila'" >/dev/null \
  || { echo "FAIL could not put Ruby on the waiting list"; exit 1; }
want "Ruby is on the waiting list to start with" "1" \
     "$(plain "select count(*) from waitlist where email='ruby@example.com'")"

echo
echo "-- before 033: there is no way for her to do it at all --"
has "erase_client does not exist" "does not exist" \
    "$(asrole $U1 "select erase_client('$RUBY'::uuid)")"
want "and her details are all still there" "ruby@example.com|07700 900111|allergic to the strong adhesive" \
     "$(plain "select email||'|'||phone||'|'||notes from client where id='$RUBY'::uuid")"
echo "     ^ that is the gap: the privacy notice promises it and nothing delivered it"

echo
echo "-- 033 --"
APPLY 033_erasure
echo "ok   033 applies"

echo
echo "-- she has a patch test, so the record has to survive --"
OUT=$(asrole $U1 "select erase_client('$RUBY'::uuid)::text")
has "it says something was kept"      '"kept_anything": true' "$OUT"
has "and why, in her words"           "patch test on record"  "$OUT"
has "with a sentence she can read out" "I have deleted your contact details" "$OUT"
has "that names the date it ends"      "because that is what my insurer needs" "$OUT"

C=$(plain "select coalesce(email,'')||'|'||coalesce(phone,'-')||'|'||coalesce(notes,'-')||'|'||coalesce(address,'-')||'|'||name||'|'||rebook_opt_out from client where id='$RUBY'::uuid")
no  "her email is gone"      "ruby@example.com"   "$C"
has "replaced with a dead end" "@invalid"         "$C"
no  "her phone is gone"      "07700 900111"       "$C"
no  "the studio's notes are gone" "allergic"      "$C"
has "her name is kept, because a dated test with no name proves nothing" "Ruby Hall" "$C"
has "and nothing will ever email her again" "|t"  "$C"

B=$(plain "select coalesce(client_email,'')||'|'||coalesce(client_phone,'-')||'|'||coalesce(client_address,'-')||'|'||coalesce(ip_key,'-')||'|'||client_name from booking where client_id='$RUBY'::uuid limit 1")
no  "the address she gave for a home visit is gone" "Mill Lane" "$B"
no  "so is the hashed IP"                           "deadbeef"  "$B"
no  "and her email on the booking"                  "ruby@example.com" "$B"
has "the booking itself survives, under her name"   "Ruby Hall" "$B"

want "her patch tests are still there, dated" "t" \
     "$(plain "select count(*) > 0 and bool_and(tested_at is not null)
                 from patch_test where client_id='$RUBY'::uuid")"
want "but the free text beside it is not" "" \
     "$(plain "select coalesce(note,'') from patch_test where client_id='$RUBY'::uuid")"
want "her place on the waiting list is gone" "0" \
     "$(plain "select count(*) from waitlist where email='ruby@example.com'")"
want "and an erasure is on record with an end date" "1" \
     "$(plain "select count(*) from erasure where client_id='$RUBY'::uuid and kept_until is not null")"

echo
echo "-- nothing to defend, so nothing is kept --"
# Nina's one treatment is inside the window; push it outside so there is no
# reason to keep anything about her at all.
psql -q -c "update booking set starts_at = now() - interval '9 years',
                               ends_at   = now() - interval '9 years' + interval '1 hour'
             where client_id='$NINA'::uuid" >/dev/null
OUT2=$(asrole $U1 "select erase_client('$NINA'::uuid)::text")
has "it says nothing was kept" '"kept_anything": false' "$OUT2"
has "and tells her so plainly"  "There was nothing I am" "$OUT2"
want "even her name is gone" "Erased at her request" \
     "$(plain "select name from client where id='$NINA'::uuid")"
want "on the booking too" "Erased at her request" \
     "$(plain "select client_name from booking where client_id='$NINA'::uuid limit 1")"
want "and no end date, because nothing is being kept" "" \
     "$(plain "select coalesce(kept_until::text,'') from erasure where client_id='$NINA'::uuid")"

echo
echo "-- it is hers alone to do, and only once --"
has "a second request is refused"  "already been erased" \
    "$(asrole $U1 "select erase_client('$RUBY'::uuid)")"
has "another studio cannot erase her client" "not yours" \
    "$(asrole $U2 "select erase_client('$RUBY'::uuid)")"
has "nor can a signed-out visitor" "denied" \
    "$(psql -qtA -c "set role anon; select erase_client('$RUBY'::uuid)" 2>&1 | tr -d '\n')"

echo
echo "-- and the keeping actually ends --"
want "nothing is due yet" "0" "$(plain "select purge_erasures()")"
want "her name is still there while it is due" "Ruby Hall" \
     "$(plain "select name from client where id='$RUBY'::uuid")"
psql -q -c "update erasure set kept_until = now() - interval '1 day' where client_id='$RUBY'::uuid" >/dev/null
want "once the period runs out it is purged" "1" "$(plain "select purge_erasures()")"
want "and now even her name is gone" "Erased at her request" \
     "$(plain "select name from client where id='$RUBY'::uuid")"
want "the booking follows" "Erased at her request" \
     "$(plain "select client_name from booking where client_id='$RUBY'::uuid limit 1")"
want "the patch test dates are STILL there, which is the point" "t" \
     "$(plain "select count(*) > 0 from patch_test where client_id='$RUBY'::uuid")"
want "and it does not purge twice" "0" "$(plain "select purge_erasures()")"

echo
echo "-- the sweep still holds --"
want "lockdown now grants 32" "32" "$(plain "select lockdown()")"
want "she can call erase_client" "t" \
     "$(plain "select has_function_privilege('authenticated','public.erase_client(uuid,int)','EXECUTE')")"
want "nobody can call the purge but cron" "f" \
     "$(plain "select has_function_privilege('authenticated','public.purge_erasures()','EXECUTE')")"
want "and the erasure log is closed to everyone" "f" \
     "$(plain "select has_table_privilege('authenticated','public.erasure','SELECT')")"

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

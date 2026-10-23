#!/bin/bash
# The hole 032 closes, and the two things it must not break.
#
# Seven tables carry RLS with no policy, which means "nobody but a definer
# function". Supabase's default ACL had granted every one of them to anon and
# authenticated anyway. The rows are unreachable either way, which is why this
# survived 023, 024 and 029 - and TRUNCATE is the exception that makes it
# matter, because RLS does not gate TRUNCATE at all.
#
# So, like the other three, this installs that default ACL before applying
# anything. On a bare Postgres a new table is granted nothing and the test
# would pass on a missing GRANT rather than on the fix.
#
#   ./test_service_tables.sh      # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-service-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55495 PGUSER=test PGDATABASE=bookedin
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

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
want()  { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has()   { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
noerr() { case "$2" in *ERROR*) echo "FAIL $1 -> $2"; fail=1;; *) echo "ok   $1";; esac; }

APPLY() { for f in "$@"; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }; done; }
APPLY 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
      008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
      014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
      020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease \
      025_paylink 026_trigger_privilege 027_patch_test_seed 028_trade_palette \
      029_slot_taken_readonly 030_launch_hardening 031_trial_notice
echo "ok   001-031 apply"

SERVICE="booking_limit platform_setting rebook_nudge trade_palette trade_seed trial_notice mail_outbox"

echo
echo "-- before 032: RLS hides the rows and the grant is still there --"
for t in $SERVICE; do
  want "anon can TRUNCATE $t, which RLS never gated" "t" \
       "$(plain "select has_table_privilege('anon','public.$t','TRUNCATE')")"
done
echo "     ^ that is the hole, on an unpatched schema"

echo
echo "-- 032 --"
APPLY 032_service_tables
echo "ok   032 applies"

for t in $SERVICE; do
  want "nothing is left to anon on $t" "f" \
       "$(plain "select has_table_privilege('anon','public.$t','TRUNCATE')
                 or has_table_privilege('anon','public.$t','SELECT')
                 or has_table_privilege('anon','public.$t','INSERT')")"
done
want "nor to a signed-in studio" "f" \
     "$(plain "select bool_or(has_table_privilege('authenticated','public.'||c.relname,'TRUNCATE'))
                 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                where n.nspname='public' and c.relkind='r' and c.relrowsecurity
                  and not exists (select 1 from pg_policies p
                                   where p.schemaname='public' and p.tablename=c.relname)")"

echo
echo "-- and it has not taken anything a studio actually needs --"
# A table WITH a policy is not the sweep's business: RLS is doing the work
# there, and authenticated has to keep the grant for it to do it.
want "her own bookings are still reachable" "t" \
     "$(plain "select has_table_privilege('authenticated','public.booking','SELECT')")"
want "so are her treatments" "t" \
     "$(plain "select has_table_privilege('authenticated','public.service','SELECT')")"
want "and her client list" "t" \
     "$(plain "select has_table_privilege('authenticated','public.client','SELECT')")"

echo
echo "-- the definer functions still do their jobs --"
psql -q -c "insert into auth.users values ('$U1','ellie@example.com')" >/dev/null
noerr "signup still seeds a studio from trade_seed" \
      "$(as $U1 "select create_studio('studio-mila','Studio Mila','lashes')")"
# five treatments plus the patch test 027 seeds, which is the thing a lash
# client must be able to book before anything else
want "and it really seeded treatments" "6" \
     "$(plain "select count(*) from service where tenant_id=(select id from tenant where slug='studio-mila')")"
has "the booking page still gets a trade palette" "accent" \
    "$(plain "select trade_profile('barber')::text")"
has "and a studio still reads back" "Studio Mila" "$(as $U1 "select get_studio('studio-mila')::text")"
SVC=$(plain "select id from service where name='Patch test' and tenant_id=(select id from tenant where slug='studio-mila')")
psql -q -c "update tenant set notice_hours=0 where slug='studio-mila'" >/dev/null
SLOT=$(plain "select min(f) from free_slots('studio-mila','$SVC'::uuid, current_date, current_date + 14) f")
noerr "a client can still book, which writes booking_limit" \
      "$(plain "select book('studio-mila','$SVC'::uuid,'$SLOT'::timestamptz,'Ruby Hall','ruby@example.com')")"
want "and the booking is there" "1" \
     "$(plain "select count(*) from booking where status='confirmed'")"
want "with its confirmation queued, which writes mail_outbox" "2" \
     "$(plain "select count(*) from mail_outbox")"

echo
echo "-- the standing assertion, so the fifth time does not happen --"
psql -q -c "grant select, truncate on trial_notice to anon" > /dev/null
want "lockdown repairs a re-granted service table" "31" "$(plain "select lockdown()")"
want "and it is closed again" "f" \
     "$(plain "select has_table_privilege('anon','public.trial_notice','TRUNCATE')")"
# A brand new policy-less table is the next one somebody adds.
psql -q -c "create table scratch_notes (id int primary key, note text)" >/dev/null
psql -q -c "alter table scratch_notes enable row level security" >/dev/null
psql -q -c "grant all on scratch_notes to anon" >/dev/null
want "a brand new one is swept too" "31" "$(plain "select lockdown()")"
want "and anon holds nothing on it" "f" \
     "$(plain "select has_table_privilege('anon','public.scratch_notes','TRUNCATE')")"
# Giving it a policy takes it out of the sweep, which is the documented escape.
# Not `using (true)`: 023 taught lockdown to refuse a policy that hands a
# whole table to anyone, and it is right to. A real policy is scoped.
psql -q -c "create policy p on scratch_notes for select using (id = 0)" >/dev/null
psql -q -c "grant select on scratch_notes to anon" >/dev/null
want "a table with a policy is left to RLS" "31" "$(plain "select lockdown()")"
want "and keeps the grant RLS needs" "t" \
     "$(plain "select has_table_privilege('anon','public.scratch_notes','SELECT')")"

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

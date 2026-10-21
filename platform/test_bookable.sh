#!/bin/bash
# Can a brand new client book anything at all?
#
# Nobody had ever asked. Every other test seeds a studio and then books as
# somebody whose patch test is already recorded, or books a trade that needs
# none - so a page that refuses every treatment to every first-time client
# passed the whole suite.
#
# A lash studio's five seeded treatments all need a patch test 48 hours ahead.
# trade_seed had no records_patch_test column, so nothing it created could BE
# the test. The page told her client to book a patch test and offered none.
#
#   ./test_bookable.sh         # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-bookable-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55497 PGUSER=test PGDATABASE=bookedin

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

for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
         014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
         020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease \
         025_paylink 026_trigger_privilege; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done
echo "ok   001-026 apply"

fail=0
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

# One studio per trade, so the question is asked of every page the wizard can
# produce rather than of the one trade somebody happened to test.
make_studios() {
  psql -q -c "
    do \$\$
    declare r record; i int := 0; u uuid;
    begin
      for r in select distinct trade from trade_seed order by trade loop
        i := i + 1;
        u := ('00000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
        insert into auth.users values (u, r.trade || '@example.com')
          on conflict do nothing;
        perform set_config('test.uid', u::text, false);
        begin
          perform create_studio(r.trade || '-studio', initcap(r.trade), r.trade);
        exception when others then null;   -- already made on a second call
        end;
      end loop;
    end \$\$;" >/dev/null
}

# A new client can book a service when it needs no patch test, or when it IS
# the patch test. Anything else refuses her until she has one on record.
BOOKABLE="select t.trade, count(*) filter (
            where s.active and (s.patch_test_hours is null or s.records_patch_test)
          ) as bookable
          from tenant t join service s on s.tenant_id = t.id
          group by t.trade order by t.trade"

make_studios
echo
echo "-- 1. the bug, before 027 closes it --"
chk "  every trade got a page" "11" "$(plain "select count(*) from tenant")"
DEAD=$(plain "select coalesce(string_agg(trade, ', ' order by trade), '(none)')
                from ($BOOKABLE) x where bookable = 0")
chk "  trades where a new client can book NOTHING" "brows, lashes, pmu" "$DEAD"
chk "  and no trade seeds anything that could BE the test" "0" \
    "$(plain "select count(*) from service where records_patch_test")"

echo
echo "-- 2. apply 027 --"
psql -q -v ON_ERROR_STOP=1 -f "$HERE/027_patch_test_seed.sql" > "$DIR/027.log" 2>&1 \
  || { echo "FAILED applying 027"; tail -8 "$DIR/027.log"; exit 1; }
echo "ok   027 applies, and lockdown() passed"
psql -q -v ON_ERROR_STOP=1 -f "$HERE/027_patch_test_seed.sql" > "$DIR/027.again.log" 2>&1 \
  && echo "ok     and applies a second time too" \
  || { echo "FAIL   027 is not re-runnable"; tail -5 "$DIR/027.again.log"; fail=1; }

echo
echo "-- 3. the backfill fixed the studios that already existed --"
# These eleven were created BEFORE 027, which is the state every live studio
# is in on the morning this migration runs.
chk "no trade is left with nothing bookable" "(none)" \
    "$(plain "select coalesce(string_agg(trade, ', ' order by trade), '(none)')
                from ($BOOKABLE) x where bookable = 0")"
chk "  the five affected trades each got one patch test" "5" \
    "$(plain "select count(*) from service where records_patch_test")"
chk "  and it went to the right trades" "brows, hair, lashes, pmu, skin" \
    "$(plain "select string_agg(t.trade, ', ' order by t.trade)
                from tenant t join service s on s.tenant_id = t.id
               where s.records_patch_test")"
chk "  nails is untouched: it never needed one" "0" \
    "$(plain "select count(*) from service s join tenant t on t.id = s.tenant_id
               where t.trade = 'nails' and s.records_patch_test")"

echo
echo "-- 4. a NEW studio gets one from the seed, not the backfill --"
psql -q -c "insert into auth.users values
            ('00000000-0000-0000-0000-999999999999','new@example.com')" >/dev/null
psql -q -c "select set_config('test.uid','00000000-0000-0000-0000-999999999999',false);
            select create_studio('brand-new-lashes','Brand New','lashes')" >/dev/null
chk "she has a bookable patch test on day one" "1" \
    "$(plain "select count(*) from service s join tenant t on t.id = s.tenant_id
               where t.slug = 'brand-new-lashes' and s.records_patch_test")"
chk "  it is free"          "0"  "$(plain "select price_pence from service s join tenant t on t.id=s.tenant_id
                                            where t.slug='brand-new-lashes' and s.records_patch_test")"
chk "  fifteen minutes"     "15" "$(plain "select duration_min from service s join tenant t on t.id=s.tenant_id
                                            where t.slug='brand-new-lashes' and s.records_patch_test")"
chk "  needs no test of its own (the name does that)" "t" \
    "$(plain "select patch_test_hours is null from service s join tenant t on t.id=s.tenant_id
               where t.slug='brand-new-lashes' and s.records_patch_test")"
chk "  and earns no rebook nudge" "t" \
    "$(plain "select rebook_weeks is null from service s join tenant t on t.id=s.tenant_id
               where t.slug='brand-new-lashes' and s.records_patch_test")"

echo
echo "-- 5. and it works end to end: book it, and the lash set unlocks --"
psql -q -c "update tenant set notice_hours = 0 where slug = 'brand-new-lashes'" >/dev/null
PT=$(plain "select s.id from service s join tenant t on t.id=s.tenant_id
             where t.slug='brand-new-lashes' and s.records_patch_test")
FULL=$(plain "select s.id from service s join tenant t on t.id=s.tenant_id
               where t.slug='brand-new-lashes' and s.name='Classic full set'")
# free_slots returns `setof timestamptz` - a bare set of values, not a table
# with a starts_at column. The first draft of this block assumed the latter.
# Near window for the test, far window for the set, so the two never collide.
SOON=$(plain "select to_char(f,'YYYY-MM-DD HH24:MI:SSOF')
                from free_slots('brand-new-lashes','$PT'::uuid,
                                current_date, current_date + 4) f limit 1")
LATER=$(plain "select to_char(f,'YYYY-MM-DD HH24:MI:SSOF')
                 from free_slots('brand-new-lashes','$FULL'::uuid,
                                 current_date + 10, current_date + 24) f limit 1")

has "a first-time client is refused the lash set" "needs a patch test" \
    "$(plain "select book('brand-new-lashes','$FULL'::uuid,'$LATER'::timestamptz,
                          'Ruby Hall','ruby@example.com')")"
chk "but she CAN book the patch test" "1" \
    "$(plain "select count(*) from book('brand-new-lashes','$PT'::uuid,
                '$SOON'::timestamptz,'Ruby Hall','ruby@example.com')")"
chk "  which records the test against her" "1" \
    "$(plain "select count(*) from patch_test p join client c on c.id = p.client_id
               where c.email = 'ruby@example.com'")"
# The test is recorded as of the appointment, so age it past the 48 hours.
psql -q -c "update patch_test set tested_at = now() - interval '3 days'" >/dev/null
chk "and three days later the lash set is hers to book" "1" \
    "$(plain "select count(*) from book('brand-new-lashes','$FULL'::uuid,
                '$LATER'::timestamptz,'Ruby Hall','ruby@example.com')")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

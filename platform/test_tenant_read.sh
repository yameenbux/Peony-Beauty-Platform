#!/bin/bash
# The hole 023 closes, and the two locks that close it.
#
# `tenant` carried a `for select using (true)` policy from 001, when the table
# held nothing but the shop front. Six later migrations added her bank details
# and her Stripe ids to the same table and nobody went back to the policy. RLS
# cannot restrict columns, so the policy was handing a sort code and an account
# number for every studio on the platform to anybody holding the anon key.
#
# Like test_lockdown.sh, this file installs Supabase's default ACL before
# applying anything, because that ACL is half of why the bug was invisible: a
# bare Postgres grants a new table nothing, so a test that reads `tenant` as
# anon on a bare Postgres is stopped by a missing GRANT rather than by a
# correct policy, and passes for the wrong reason.
#
# The first block asserts the hole is OPEN. If that block ever starts failing,
# this test has stopped testing anything and must be read before it is trusted.
#
#   ./test_tenant_read.sh      # needs postgresql-16
set -u
DIR=${TMPDIR:-/tmp}/bookedin-tenantread-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55481 PGUSER=test PGDATABASE=bookedin
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

# THE POINT OF THIS FILE: Supabase's default ACL, for tables as well as
# functions. Every table a migration creates from here is handed to anon and
# authenticated as it is created, exactly as it is on the real project.
psql -q -v ON_ERROR_STOP=1 -c "alter default privileges in schema public
       grant all on tables to anon, authenticated, service_role" \
  -c "alter default privileges in schema public
       grant execute on functions to anon, authenticated, service_role" || exit 1

fail=0
as()     { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain()  { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
anon()   { psql -qtA -c "set role anon; $1" 2>&1 | tr -d '\n'; }
asrole() { psql -qtA -c "set test.uid='$1'; set role authenticated; $2" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }
no()  { case "$3" in *"$2"*) echo "FAIL $1 -> leaked '$2' in: $3"; fail=1;; *) echo "ok   $1";; esac; }

for f in 001_schema 002_signup 003_cancel 004_photos 005_email 007_reminders \
         008_billing 009_lockdown 010_abuse 011_clients 012_rebook 013_brand \
         014_patch 015_venue 016_proplus 017_deposits 018_earn 019_sector \
         020_pay 021_lockdown 022_pgcrypto_path; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done
echo "ok   001-022 apply"

psql -q -c "insert into auth.users values ('$U1','ellie@example.com'),('$U2','jo@example.com')" >/dev/null
as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
as $U2 "select create_studio('nails-by-jo','Nails by Jo','nails')" > /dev/null
# Her bank details, as the deposit form writes them. Obviously-fake numbers.
as $U1 "update tenant set deposit_pence=1000, deposit_how='bank',
          deposit_name='E Mila', deposit_sort='00-00-00', deposit_account='12345678'
        where slug='studio-mila'" > /dev/null
chk "the studio has its deposit details set" "00-00-00" \
    "$(plain "select deposit_sort from tenant where slug='studio-mila'")"
SVC=$(plain "select id from service where name='Russian full set'
               and tenant_id=(select id from tenant where slug='studio-mila')")

echo
echo "-- 1. the hole, before 023 closes it --"
# If any of these four reads the other way, the default ACL or the policy has
# changed and nothing below is meaningful.
chk "  anon holds SELECT on tenant (Supabase's default ACL)" "t" \
    "$(plain "select has_table_privilege('anon','public.tenant','SELECT')")"
chk "  a blanket read policy is on the table" "1" \
    "$(plain "select count(*) from pg_policies
              where schemaname='public' and tablename='tenant' and qual='true'")"
chk "  so anon sees every studio's row" "2" "$(anon "select count(*) from tenant")"
chk "  including the sort code (the bug)" "00-00-00" \
    "$(anon "select deposit_sort from tenant where slug='studio-mila'")"
chk "  and the account number (the bug)" "12345678" \
    "$(anon "select deposit_account from tenant where slug='studio-mila'")"

echo
echo "-- 2. apply 023, 024 and 025 --"
for f in 023_tenant_read 024_mail_lease 025_paylink; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -8 "$DIR/$f.log"; exit 1; }
done
echo "ok   023, 024 and 025 apply, and lockdown()'s own assertions passed"
# Both are run by hand in a SQL editor, so a second attempt after a half-applied
# first one has to be safe rather than a new problem.
for f in 023_tenant_read 024_mail_lease 025_paylink; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.again.log" 2>&1 \
    && echo "ok     $f applies a second time too" \
    || { echo "FAIL   $f is not re-runnable"; tail -5 "$DIR/$f.again.log"; fail=1; }
done

echo
echo "-- 3. both locks are on --"
has "lock one: the blanket policy is gone" "permission denied" \
    "$(anon "select deposit_sort from tenant")"
chk "  only tenant_own is left on the table" "tenant_own" \
    "$(plain "select string_agg(policyname,',' order by policyname)
              from pg_policies where schemaname='public' and tablename='tenant'")"
chk "lock two: anon holds no SELECT on tenant" "f" \
    "$(plain "select has_table_privilege('anon','public.tenant','SELECT')")"
for p in INSERT UPDATE DELETE; do
  chk "  nor $p" "f" \
      "$(plain "select has_table_privilege('anon','public.tenant','$p')")"
done

echo
echo "-- 4. and the pages still work --"
S=$(anon "select get_studio('studio-mila')")
has "the booking page still gets the studio"  "Studio Mila"       "$S"
has "and its treatments"                      "Russian full set"  "$S"
no  "but never the sort code"                 "00-00-00"          "$S"
no  "nor the account number"                  "12345678"          "$S"
no  "nor the account name"                    "E Mila"            "$S"
chk "slug_available still answers for a signup" "f" \
    "$(anon "select slug_available('studio-mila')")"
# The service id is resolved as the owner. Looking it up inside the anon
# query would read `tenant` as anon, which is the thing being forbidden - the
# first draft of this line failed for that reason rather than any fault in
# free_slots.
chk "free_slots still answers" "t" \
    "$(anon "select count(*) >= 0 from free_slots('studio-mila','$SVC'::uuid,
              current_date, current_date + 14)")"

echo
echo "-- 5. she is unaffected, and still cannot see anyone else --"
chk "she reads her own row" "1" \
    "$(asrole $U1 "select count(*) from tenant")"
chk "  and only her own" "studio-mila" \
    "$(asrole $U1 "select slug from tenant")"
chk "her own deposit details still reach her through my_studio()" "00-00-00" \
    "$(asrole $U1 "select my_studio()->>'deposit_sort'")"
# Her settings screen writes with sb.from("tenant").update(...), which is a
# PATCH with Prefer: return=minimal - no SELECT on the written columns. This is
# the regression that would hurt most, so it is asserted by its effect.
asrole $U1 "update tenant set tagline='Lashes in Coventry' where slug='studio-mila'" >/dev/null
chk "she can still save her settings (the .update path)" "Lashes in Coventry" \
    "$(plain "select tagline from tenant where slug='studio-mila'")"
chk "the other studio cannot see hers" "0" \
    "$(asrole $U2 "select count(*) from tenant where slug='studio-mila'")"
chk "  and gets nothing if she asks for the sort code" "" \
    "$(asrole $U2 "select deposit_sort from tenant where slug='studio-mila'")"
has "she still cannot set her own plan" "set by billing" \
    "$(asrole $U1 "update tenant
         set plan = case when plan = 'free' then 'pro' else 'free' end
       where slug='studio-mila'")"

echo
echo "-- 6. the standing assertions: putting it back must fail loudly --"
# This is the part that matters in a year. Closing the policy today does not
# stop migration 031 reopening it, so lockdown() refuses to pass while it is
# open - the same shape as its function sweep.
psql -q -c "create policy tenant_read on tenant for select using (true)" >/dev/null
has "lockdown() refuses while a blanket policy exists" "hand a whole table" \
    "$(plain "select lockdown()")"
psql -q -c "drop policy tenant_read on tenant" >/dev/null
chk "  and passes once it is dropped again" "t" \
    "$(plain "select lockdown() > 0")"

psql -q -c "grant select on tenant to anon" >/dev/null
has "lockdown() refuses while anon holds SELECT on tenant" "anon can select from tenant" \
    "$(plain "select lockdown()")"
psql -q -c "revoke select on tenant from anon" >/dev/null
chk "  and passes once it is revoked again" "t" \
    "$(plain "select lockdown() > 0")"

# A new table with a blanket read is the general case, and it must be caught
# without anybody having thought of that table in advance.
psql -q -c "create table _later (id int, secret text)" \
     -c "alter table _later enable row level security" \
     -c "create policy _later_read on _later for select using (true)" >/dev/null
has "a NEW table handed out wholesale is caught too" "_later._later_read" \
    "$(plain "select lockdown()")"
psql -q -c "drop table _later" >/dev/null
chk "  and the sweep is clean again" "t" "$(plain "select lockdown() > 0")"

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

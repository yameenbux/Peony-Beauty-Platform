#!/bin/bash
# A payment link could be a javascript: URI, and her client is the one who taps
# it.
#
# esc() on the client pages replaces & < > " and ' - correct for text, and no
# help at all against a scheme. `javascript:alert(1)` contains none of those
# five characters, so it went through esc() unchanged into
#
#     <a href="javascript:...">Pay here</a>
#
# on book/manage.html and book/index.html. The only guard was in the browser,
# in app/index.html, and her settings are saved with
# sb.from("tenant").update(...) - so a studio with her own token could PATCH
# PostgREST directly and never meet it.
#
# Two locks, one per layer: a check constraint here, so it cannot be stored,
# and safeUrl() on the pages, so it could not be rendered even if it were.
#
#   ./test_paylink.sh          # needs postgresql-16; the JS half needs node
set -u
DIR=${TMPDIR:-/tmp}/bookedin-paylink-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55487 PGUSER=test PGDATABASE=bookedin
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
         020_pay 021_lockdown 022_pgcrypto_path 023_tenant_read 024_mail_lease; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" > "$DIR/$f.log" 2>&1 \
    || { echo "FAILED applying $f"; tail -5 "$DIR/$f.log"; exit 1; }
done

fail=0
as()    { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
plain() { psql -qtA -c "$1" 2>&1 | tr -d '\n'; }
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 -> got '$3' want '$2'"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac; }

psql -q -c "insert into auth.users values ('$U1','ellie@example.com')" >/dev/null
as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
set_link() { as $U1 "update tenant set deposit_pence=1000, deposit_how='link',
                       deposit_link=\$x\$$1\$x\$ where slug='studio-mila'"; }
# psql -q suppresses the command tag, so a successful UPDATE prints nothing at
# all. Assert what is in the column instead of what psql said about it - the
# same correction test_tenant_read.sh needed.
stored() { plain "select coalesce(deposit_link,'(null)') from tenant where slug='studio-mila'"; }
paypal() { plain "select coalesce(deposit_paypal,'(null)') from tenant where slug='studio-mila'"; }

echo
echo "-- 1. the hole, before 025 closes it --"
# If this stops failing, the constraint arrived early or the test is wrong.
set_link 'javascript:alert(1)' > /dev/null
chk "  a javascript: URI can be stored, and sits in the column (the bug)" \
    "javascript:alert(1)" "$(stored)"

echo
echo "-- 2. apply 025 --"
# It has to refuse to apply while that row is there, which is the constraint
# doing its job on real data rather than on an empty table.
has "025 refuses to apply while a bad link is stored" "tenant_deposit_link_scheme" \
    "$(psql -q -v ON_ERROR_STOP=1 -f "$HERE/025_paylink.sql" 2>&1 | tr -d '\n')"
as $U1 "update tenant set deposit_pence=0, deposit_how='none', deposit_link=null
        where slug='studio-mila'" >/dev/null
psql -q -v ON_ERROR_STOP=1 -f "$HERE/025_paylink.sql" > "$DIR/025.log" 2>&1 \
  || { echo "FAILED applying 025"; tail -8 "$DIR/025.log"; exit 1; }
echo "ok   025 applies once the column is clean, and lockdown() passed"
psql -q -v ON_ERROR_STOP=1 -f "$HERE/025_paylink.sql" > "$DIR/025.again.log" 2>&1 \
  && echo "ok     and applies a second time too" \
  || { echo "FAIL   025 is not re-runnable"; tail -5 "$DIR/025.again.log"; fail=1; }

echo
echo "-- 3. the scheme is settled in the database --"
for bad in 'javascript:alert(1)' 'JavaScript:alert(1)' 'data:text/html,<script>x</script>' \
           'http://pay.example.com' 'vbscript:x' '/relative/path' 'pay.example.com'; do
  has "  refused: $bad" "violates check constraint" "$(set_link "$bad")"
done
set_link 'https://pay.example.com/ellie' > /dev/null
chk "accepted: https://pay.example.com/ellie" "https://pay.example.com/ellie" "$(stored)"
set_link 'HTTPS://pay.example.com/ellie' > /dev/null
chk "accepted: HTTPS:// in capitals, since a scheme is case-insensitive" \
    "HTTPS://pay.example.com/ellie" "$(stored)"

echo
echo "-- 4. the rules that were already there still hold --"
has "a link route with no link is still refused" "tenant_deposit_route_check" \
    "$(as $U1 "update tenant set deposit_pence=1000, deposit_how='link', deposit_link=null
               where slug='studio-mila'")"
as $U1 "update tenant set deposit_pence=1000, deposit_how='paypal',
          deposit_link=null, deposit_paypal='paypal.me/ellie'
        where slug='studio-mila'" > /dev/null
chk "and paypal still takes a bare paypal.me, which has no scheme" \
    "paypal.me/ellie" "$(paypal)"

echo
echo "-- 5. patch_status comes off the public list (025) --"
# It answered "is this address a client of this studio, and when was she last
# patch tested" to anybody, and nothing in any page ever called it.
chk "anon can no longer reach patch_status" "f" \
    "$(plain "select has_function_privilege('anon','patch_status(text,text)','EXECUTE')")"
chk "  nor can a signed-in studio" "f" \
    "$(plain "select has_function_privilege('authenticated','patch_status(text,text)','EXECUTE')")"
chk "but the function is still there for whoever writes the caller" "t" \
    "$(plain "select to_regprocedure('public.patch_status(text,text)') is not null")"
chk "and her own patch-test screen is untouched" "t" \
    "$(plain "select has_function_privilege('authenticated','my_patch_tests()','EXECUTE')")"
chk "as is the refusal that actually enforces a patch test" "t" \
    "$(plain "select has_function_privilege('anon',
                'book(text,uuid,timestamptz,text,text,text,text,text)','EXECUTE')")"
# lockdown() sweeps before it asserts, so a careless re-grant is repaired
# rather than reported - the same behaviour test_lockdown.sh pins down for a
# hand-granted function. What matters is that the grant does not survive.
psql -q -c "grant execute on function patch_status(text,text) to anon" >/dev/null
chk "a careless re-grant does expose it again" "t" \
    "$(plain "select has_function_privilege('anon','patch_status(text,text)','EXECUTE')")"
chk "  and lockdown() takes it straight back" "31" "$(plain "select lockdown()")"
chk "  leaving it unreachable" "f" \
    "$(plain "select has_function_privilege('anon','patch_status(text,text)','EXECUTE')")"

echo
echo "-- 6. and safeUrl() on the pages, which is the other lock --"
if command -v node > /dev/null 2>&1; then
  node - "$HERE/../book/manage.html" "$HERE/../book/index.html" <<'JS' || fail=1
const fs = require("fs");
let bad = 0;
for (const path of process.argv.slice(2)) {
  const src = fs.readFileSync(path, "utf8");
  const m = src.match(/function safeUrl\(v\)\{[\s\S]*?\n  \}/);
  if (!m) { console.log(`FAIL safeUrl() not found in ${path}`); bad = 1; continue; }
  const safeUrl = new Function("v", m[0].replace(/^function safeUrl\(v\)\{/, "").replace(/\}$/, ""));
  const cases = [
    ["https://pay.example.com/x", "https://pay.example.com/x"],
    ["HTTPS://pay.example.com/x", "HTTPS://pay.example.com/x"],
    ["javascript:alert(1)",       ""],
    ["JavaScript:alert(1)",       ""],
    ["  javascript:alert(1)",     ""],
    ["data:text/html,<script>x</script>", ""],
    ["vbscript:x",                ""],
    ["http://pay.example.com",    ""],
    ["//evil.example.com",        ""],
    ["pay.example.com",           ""],
    ["",                          ""],
    [null,                        ""],
    [undefined,                   ""],
  ];
  const name = path.replace(/.*\//, "");
  for (const [input, want] of cases) {
    const got = safeUrl(input);
    if (got === want) console.log(`ok     ${name}: ${JSON.stringify(input)} -> ${JSON.stringify(got)}`);
    else { console.log(`FAIL   ${name}: ${JSON.stringify(input)} -> got ${JSON.stringify(got)} want ${JSON.stringify(want)}`); bad = 1; }
  }
}
process.exit(bad);
JS
else
  echo "skip: node unavailable, cannot exercise safeUrl()"
fi

echo
if [ "$fail" = "0" ]; then echo "all passed"; else echo "FAILURES"; fi
exit $fail

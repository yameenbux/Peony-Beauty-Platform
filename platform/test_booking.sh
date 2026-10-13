#!/bin/bash
# Proves the one thing the current booking page cannot do: refuse a second
# person the slot a first person has just taken.
#
# Spins up a throwaway Postgres, applies 001_schema.sql, then fires N real
# concurrent book() calls at a single slot. Exactly one must win.
#
#   ./test_booking.sh          # needs postgresql-16 and an unprivileged user
set -u
DIR=${TMPDIR:-/tmp}/bookedin-booking-test
SQL=$(cd "$(dirname "$0")" && pwd)/001_schema.sql
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55432 PGUSER=test PGDATABASE=bookedin
TENANT=22222222-2222-2222-2222-222222222222
SVC=33333333-3333-3333-3333-333333333333

rm -rf "$DIR"; mkdir -p "$DIR/sock"
initdb -D "$DIR/data" -U test --auth=trust -E UTF8 > "$DIR/initdb.log" 2>&1 || exit 1
pg_ctl -D "$DIR/data" -o "-p $PGPORT -k $DIR/sock -c listen_addresses=''" \
       -l "$DIR/pg.log" -w start > /dev/null || exit 1
trap 'pg_ctl -D "$DIR/data" -m immediate stop >/dev/null 2>&1' EXIT
createdb bookedin

# Supabase supplies these; stub them so the migration runs unmodified
psql -q -v ON_ERROR_STOP=1 \
  -c "create schema auth" \
  -c "create table auth.users (id uuid primary key)" \
  -c "create function auth.uid() returns uuid language sql stable as 'select null::uuid'" \
  -c "create role anon" -c "create role authenticated" || exit 1
psql -q -v ON_ERROR_STOP=1 -f "$SQL" || { echo "schema failed"; exit 1; }

psql -q -v ON_ERROR_STOP=1 <<EOF || exit 1
insert into auth.users values ('11111111-1111-1111-1111-111111111111');
insert into tenant (id,owner,slug,display_name,notice_hours)
  values ('$TENANT','11111111-1111-1111-1111-111111111111','studio-mila','Studio Mila',0);
insert into service (id,tenant_id,name,price_pence,duration_min)
  values ('$SVC','$TENANT','Russian full set',5000,90);
insert into opening (tenant_id,weekday,starts,ends) values ('$TENANT',5,'09:00','18:00');
EOF

# ---------------------------------------------------------------- the dates
# Every date below is worked out from today rather than written down. The
# literals that used to be here were an October 2026 week, and the morning that
# week went past, "a weekday she does not work" became a date in the past and
# started failing on a different check entirely - a test that quietly expires
# is worse than no test, because it fails long after whoever wrote it has gone.
#
# Monday of the week after next, in her timezone, and the five days that follow
# it. Far enough ahead that no notice period can reach it and no run of this
# file can drift over a weekend boundary mid-way.
eval "$(psql -qtA -c "select
    'DMON='  || to_char(d,   'YYYY-MM-DD') || chr(10) ||
    'DTUE='  || to_char(d+1, 'YYYY-MM-DD') || chr(10) ||
    'DWED='  || to_char(d+2, 'YYYY-MM-DD') || chr(10) ||
    'DTHU='  || to_char(d+3, 'YYYY-MM-DD') || chr(10) ||
    'DFRI='  || to_char(d+4, 'YYYY-MM-DD') || chr(10) ||
    'DSAT='  || to_char(d+5, 'YYYY-MM-DD') || chr(10) ||
    'DMON2=' || to_char(d+7, 'YYYY-MM-DD') || chr(10) ||
    'DTUE2=' || to_char(d+8, 'YYYY-MM-DD') || chr(10) ||
    'DFRI2=' || to_char(d+11,'YYYY-MM-DD')
  from (select (date_trunc('week', now() at time zone 'Europe/London')
                + interval '14 days')::date d) x")"
# British Summer Time ends in late October, so the offset cannot be written
# down either: ask Postgres what it is on the day in question.
OFF=$(psql -qtA -c "select to_char('$DMON 12:00'::timestamp at time zone 'Europe/London', 'OF')")

fail=0
for N in 20 50; do
  psql -qtA -c "delete from booking" > /dev/null
  rm -f "$DIR"/o.*
  for i in $(seq 1 "$N"); do
    ( psql -qtA -c "select ref from book('studio-mila','$SVC'::uuid,
        '$DFRI 09:00$OFF'::timestamptz,'Client $i','c$i@example.com')" \
      > "$DIR/o.$i" 2>&1 ) &
  done
  wait
  won=0; lost=0; odd=0
  for f in "$DIR"/o.*; do
    if grep -q "^ERROR" "$f"; then
      grep -q "just took that time" "$f" && lost=$((lost+1)) || odd=$((odd+1))
    else won=$((won+1)); fi
  done
  rows=$(psql -qtA -c "select count(*) from booking where status='confirmed'")
  if [ "$won" = 1 ] && [ "$rows" = 1 ] && [ "$odd" = 0 ] && [ "$lost" = "$((N-1))" ]; then
    echo "ok   $N concurrent attempts -> 1 booked, $lost refused"
  else
    echo "FAIL $N concurrent -> booked=$won refused=$lost unexpected=$odd rows=$rows"
    grep -h "^ERROR" "$DIR"/o.* | grep -v "just took that time" | sort -u | head -3 | sed 's/^/     /'
    fail=1
  fi
done

check() { # label, expected fragment ("" means: must succeed), sql
  out=$(psql -qtA -c "$3" 2>&1 | tr -d '\n')
  if [ -z "$2" ]; then
    case "$out" in *ERROR*) echo "FAIL $1 -> $out"; fail=1;; *) echo "ok   $1 ($out)";; esac
  else
    case "$out" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $out"; fail=1;; esac
  fi
}
BOOK="select ref from book('studio-mila','$SVC'::uuid"
psql -qtA -c "delete from booking" > /dev/null
psql -qtA -c "$BOOK,'$DFRI 09:00$OFF','A','a@example.com')" > /dev/null
check "a 90-minute 09:00 booking blocks 10:00" "just took that time" \
      "$BOOK,'$DFRI 10:00$OFF','B','b@example.com')"
check "10:30 is clear and books"               ""   "$BOOK,'$DFRI 10:30$OFF','C','c@example.com')"
check "a time outside her hours is refused"    "not a time she works" \
      "$BOOK,'$DFRI 22:00$OFF','D','d@example.com')"
check "a weekday she does not work is refused" "not a time she works" \
      "$BOOK,'$DMON 10:00$OFF','E','e@example.com')"
psql -qtA -c "insert into closure (tenant_id,on_date) values ('$TENANT','$DFRI2')" > /dev/null
check "a closed date is refused"               "closed that day" \
      "$BOOK,'$DFRI2 11:00$OFF','F','f@example.com')"
psql -qtA -c "update booking set status='cancelled' where starts_at='$DFRI 09:00$OFF'" > /dev/null
check "cancelling frees the slot again"        ""   "$BOOK,'$DFRI 09:00$OFF','G','g@example.com')"

[ $fail = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

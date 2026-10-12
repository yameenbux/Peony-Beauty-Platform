#!/bin/bash
# Cancelling, from both sides, and blocking out a day.
set -u
DIR=${TMPDIR:-/tmp}/bookedin-cancel-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55434 PGUSER=test PGDATABASE=bookedin
U1=11111111-1111-1111-1111-111111111111
U2=99999999-9999-9999-9999-999999999999

rm -rf "$DIR"; mkdir -p "$DIR/sock"
initdb -D "$DIR/data" -U test --auth=trust -E UTF8 > "$DIR/initdb.log" 2>&1 || exit 1
pg_ctl -D "$DIR/data" -o "-p $PGPORT -k $DIR/sock -c listen_addresses=''" \
       -l "$DIR/pg.log" -w start > /dev/null || exit 1
trap 'pg_ctl -D "$DIR/data" -m immediate stop >/dev/null 2>&1' EXIT
createdb bookedin
psql -q -v ON_ERROR_STOP=1 \
  -c "create schema auth" -c "create table auth.users (id uuid primary key)" \
  -c "create function auth.uid() returns uuid language sql stable as
      \$\$ select nullif(current_setting('test.uid', true), '')::uuid \$\$" \
  -c "create role anon" -c "create role authenticated" || exit 1
for f in 001_schema 002_signup 003_cancel; do
  psql -q -v ON_ERROR_STOP=1 -f "$HERE/$f.sql" || { echo "$f failed"; exit 1; }
done
echo "ok   all three migrations apply"
psql -q -c "insert into auth.users values ('$U1'),('$U2')"

fail=0
as() { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
want() {
  if [ -z "$2" ]; then
    case "$3" in *ERROR*) echo "FAIL $1 -> $3"; fail=1;; *) echo "ok   $1";; esac
  else
    case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac
  fi
}

as $U1 "select create_studio('studio-mila','Studio Mila','lashes')" > /dev/null
as $U1 "update tenant set notice_hours=0, cancel_hours=24 where slug='studio-mila'" > /dev/null
SVC=$(as $U1 "select id from service where name='Russian full set'")

# a Tuesday three weeks out, comfortably past any notice or cancel window
FAR=$(as $U1 "select to_char(date_trunc('week', current_date + 21) + interval '1 day', 'YYYY-MM-DD')")
B=$(as $U1 "select ref||' '||token from book('studio-mila','$SVC'::uuid,'$FAR 10:00+01','Ruby','ruby@x.com')")
REF=$(echo "$B" | cut -d' ' -f1); TOK=$(echo "$B" | cut -d' ' -f2)
[ -n "$REF" ] && [ -n "$TOK" ] && echo "ok   book() hands back a reference and a token" \
  || { echo "FAIL book returned '$B'"; fail=1; }

want "the right reference and token find the booking" "Studio Mila" \
     "$(as $U1 "select get_booking('$REF','$TOK'::uuid)::text")"
want "a guessed reference with the wrong token shows nothing" "(null)" \
     "$(as $U1 "select coalesce(get_booking('$REF',gen_random_uuid())::text,'(null)')")"
want "it says the client may still cancel" '"can_cancel": true' \
     "$(as $U1 "select get_booking('$REF','$TOK'::uuid)::text")"

TAKEN=$(as $U1 "select count(*) from free_slots('studio-mila','$SVC'::uuid,'$FAR','$FAR') f where f = '$FAR 10:00+01'")
[ "$TAKEN" = 0 ] && echo "ok   the booked time is not offered to anyone else" \
  || { echo "FAIL still offered"; fail=1; }

want "the client can cancel" '"cancelled": true' "$(as $U1 "select cancel_booking('$REF','$TOK'::uuid)::text")"
BACK=$(as $U1 "select count(*) from free_slots('studio-mila','$SVC'::uuid,'$FAR','$FAR') f where f = '$FAR 10:00+01'")
[ "$BACK" = 1 ] && echo "ok   cancelling puts the time back on sale" \
  || { echo "FAIL not freed ($BACK)"; fail=1; }
want "cancelling twice is refused" "already cancelled" "$(as $U1 "select cancel_booking('$REF','$TOK'::uuid)::text")"
want "a cancelled booking reports it cannot be cancelled" '"can_cancel": false' \
     "$(as $U1 "select get_booking('$REF','$TOK'::uuid)::text")"

# somebody else can take the freed slot, which is the whole point of freeing it
want "the freed time can be booked by somebody else" "" \
     "$(as $U1 "select ref from book('studio-mila','$SVC'::uuid,'$FAR 10:00+01','Second','two@x.com')")"

# Too close to the appointment. Rather than wait, widen her window to its
# maximum of 336 hours and book a Tuesday inside it — the far date above is
# three weeks out and would legitimately still be cancellable.
NEAR=$(as $U1 "select to_char(date_trunc('week', current_date + 7) + interval '1 day', 'YYYY-MM-DD')")
B2=$(as $U1 "select ref||' '||token from book('studio-mila','$SVC'::uuid,'$NEAR 14:00+01','Late','late@x.com')")
R2=$(echo "$B2" | cut -d' ' -f1); T2=$(echo "$B2" | cut -d' ' -f2)
as $U1 "update tenant set cancel_hours=336 where slug='studio-mila'" > /dev/null
want "inside her notice window the client is sent to her instead" "message Studio Mila directly" \
     "$(as $U1 "select cancel_booking('$R2','$T2'::uuid)::text")"
want "and it reports that it cannot be cancelled" '"can_cancel": false' \
     "$(as $U1 "select get_booking('$R2','$T2'::uuid)::text")"

# but she is never locked out of her own diary
ID2=$(as $U1 "select id from booking where ref='$R2'")
want "she can cancel it herself whatever the window" '"cancelled": true' \
     "$(as $U1 "select studio_cancel('$ID2'::uuid)::text")"
want "and the diary records who cancelled it" "studio" \
     "$(as $U1 "select cancelled_by from booking where ref='$R2'")"
want "a stranger cannot cancel her booking" "not your booking" \
     "$(as $U2 "select studio_cancel('$ID2'::uuid)::text")"
want "cancelling an already-cancelled booking is refused, not reported as done" "already cancelled" \
     "$(as $U1 "select studio_cancel('$ID2'::uuid)::text")"
as $U1 "update tenant set cancel_hours=24 where slug='studio-mila'" > /dev/null

echo
echo "-- blocking out a day --"
want "she can close a day" '"closed": true' "$(as $U1 "select set_closure('$FAR'::date, true, 'Holiday')::text")"
N=$(as $U1 "select count(*) from free_slots('studio-mila','$SVC'::uuid,'$FAR','$FAR')")
[ "$N" = 0 ] && echo "ok   a closed day offers nothing" || { echo "FAIL closed day offers $N"; fail=1; }
want "the closure shows in her dashboard" "Holiday" "$(as $U1 "select my_studio()->'closures'->>0")"
want "she can open it again" '"closed": false' "$(as $U1 "select set_closure('$FAR'::date, false)::text")"
N=$(as $U1 "select count(*) from free_slots('studio-mila','$SVC'::uuid,'$FAR','$FAR')")
[ "$N" -gt 0 ] && echo "ok   reopening it puts the times back" || { echo "FAIL reopened offers $N"; fail=1; }
want "a signed-out visitor cannot close her days" "Sign in first" \
     "$(psql -qtA -c "set test.uid=''; select set_closure('$FAR'::date,true)" 2>&1 | tr -d '\n')"

echo
echo "-- the overlap constraint still holds after all this --"
psql -qtA -c "delete from booking" > /dev/null
rm -f "$DIR"/o.*
for i in $(seq 1 30); do
  ( psql -qtA -c "select ref from book('studio-mila','$SVC'::uuid,'$FAR 10:00+01','C$i','c$i@x.com')" \
    > "$DIR/o.$i" 2>&1 ) &
done
wait
won=0; for f in "$DIR"/o.*; do grep -q "^ERROR" "$f" || won=$((won+1)); done
rows=$(psql -qtA -c "select count(*) from booking where status='confirmed'")
[ "$won" = 1 ] && [ "$rows" = 1 ] && echo "ok   30 concurrent attempts still yield exactly one booking" \
  || { echo "FAIL won=$won rows=$rows"; fail=1; }

[ $fail = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

#!/bin/bash
# Exercises self-serve signup end to end against a throwaway Postgres:
# claiming a link, seeding a trade, and working out which times are bookable.
set -u
DIR=${TMPDIR:-/tmp}/bookedin-signup-test
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/lib/postgresql/16/bin:$PATH
export PGHOST=$DIR/sock PGPORT=55433 PGUSER=test PGDATABASE=bookedin
U1=11111111-1111-1111-1111-111111111111
U2=99999999-9999-9999-9999-999999999999

rm -rf "$DIR"; mkdir -p "$DIR/sock"
initdb -D "$DIR/data" -U test --auth=trust -E UTF8 > "$DIR/initdb.log" 2>&1 || exit 1
pg_ctl -D "$DIR/data" -o "-p $PGPORT -k $DIR/sock -c listen_addresses=''" \
       -l "$DIR/pg.log" -w start > /dev/null || exit 1
trap 'pg_ctl -D "$DIR/data" -m immediate stop >/dev/null 2>&1' EXIT
createdb bookedin

# Supabase reads auth.uid() out of the request JWT. Locally we read a GUC, so a
# test can say who is signed in.
psql -q -v ON_ERROR_STOP=1 \
  -c "create schema auth" \
  -c "create table auth.users (id uuid primary key)" \
  -c "create function auth.uid() returns uuid language sql stable as
      \$\$ select nullif(current_setting('test.uid', true), '')::uuid \$\$" \
  -c "create role anon" -c "create role authenticated" || exit 1
psql -q -v ON_ERROR_STOP=1 -f "$HERE/001_schema.sql" || { echo "001 failed"; exit 1; }
psql -q -v ON_ERROR_STOP=1 -f "$HERE/002_signup.sql" || { echo "002 failed"; exit 1; }
echo "ok   both migrations apply"
psql -q -c "insert into auth.users values ('$U1'),('$U2')"

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
as() { psql -qtA -c "set test.uid='$1'; $2" 2>&1 | tr -d '\n'; }
want() { # label, fragment ("" = must not error), output
  case "$1" in *) :;; esac
  if [ -z "$2" ]; then
    case "$3" in *ERROR*) echo "FAIL $1 -> $3"; fail=1;; *) echo "ok   $1";; esac
  else
    case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1 -> $3"; fail=1;; esac
  fi
}

want "a reserved link is unavailable"  "f" "$(as $U1 "select slug_available('app')")"
want "a malformed link is unavailable" "f" "$(as $U1 "select slug_available('No Spaces!')")"
want "a free link is available"        "t" "$(as $U1 "select slug_available('studio-mila')")"
want "signed-out signup is refused"  "Sign in first" \
     "$(psql -qtA -c "select create_studio('x-studio','X')" 2>&1 | tr -d '\n')"
want "she can claim her link"          "" "$(as $U1 "select create_studio('studio-mila','Studio Mila','lashes')")"
want "the link is now taken"           "f" "$(as $U2 "select slug_available('studio-mila')")"
want "a second person cannot take it"  "link is taken" \
     "$(as $U2 "select create_studio('studio-mila','Copycat','nails')")"
want "she cannot claim a second page"  "already have a page" \
     "$(as $U1 "select create_studio('another-one','Another','nails')")"
want "a reserved link is refused"      "link is taken" \
     "$(as $U2 "select create_studio('admin','Admin','nails')")"

N=$(as $U1 "select count(*) from service where tenant_id=(select id from tenant where slug='studio-mila')")
[ "$N" = 5 ] && echo "ok   her trade seeded 5 treatments" || { echo "FAIL seeded $N"; fail=1; }
D=$(as $U1 "select count(*) from opening where tenant_id=(select id from tenant where slug='studio-mila')")
[ "$D" = 5 ] && echo "ok   seeded Tuesday to Saturday" || { echo "FAIL openings $D"; fail=1; }

want "get_studio returns her page" "Studio Mila" "$(as $U1 "select get_studio('studio-mila')::text")"
want "get_studio on an unknown link is empty" "" "$(as $U1 "select coalesce(get_studio('nobody')::text,'(null)')")"
want "my_studio returns her own only" "Studio Mila" "$(as $U1 "select my_studio()::text")"
want "my_studio is empty for a stranger" "(null)" "$(as $U2 "select coalesce(my_studio()::text,'(null)')")"

SVC=$(as $U1 "select id from service where name='Russian full set'")

echo
echo "-- availability --"
# the notice period is real, so pin it to 0 while checking the slot geometry
as $U1 "update tenant set notice_hours=0 where slug='studio-mila'" > /dev/null
SLOTS() { as $U1 "select count(*) from free_slots('studio-mila','$SVC'::uuid,'$DTUE','$DSAT')"; }
BASE=$(SLOTS)
[ "$BASE" -gt 0 ] && echo "ok   free_slots offers $BASE times that week" || { echo "FAIL no slots"; fail=1; }

# Read back in her timezone, not as a UTC string. The old assertions expected
# "08:00:00+00", which is 09:00 London only while British Summer Time is in
# force; on the other side of the last Sunday in October the same correct
# answer prints as 09:00:00+00 and the test failed for being right.
FIRST=$(as $U1 "select to_char(min(f) at time zone 'Europe/London','HH24:MI')
                  from free_slots('studio-mila','$SVC'::uuid,'$DTUE','$DTUE') f")
want "the first Tuesday start is 09:00 local" "09:00" "$FIRST"
LAST=$(as $U1 "select to_char(max(f) at time zone 'Europe/London','HH24:MI')
                 from free_slots('studio-mila','$SVC'::uuid,'$DTUE','$DTUE') f")
want "the last start leaves room to finish by 18:00" "15:30" "$LAST"

MON=$(as $U1 "select count(*) from free_slots('studio-mila','$SVC'::uuid,'$DMON','$DMON')")
[ "$MON" = 0 ] && echo "ok   Monday, which she does not work, offers nothing" || { echo "FAIL Monday=$MON"; fail=1; }

B=$(as $U1 "select book('studio-mila','$SVC'::uuid,'$DTUE 09:00$OFF','A','a@x.com')")
want "a client can book the 09:00" "" "$B"
AFTER=$(SLOTS)
[ "$AFTER" -lt "$BASE" ] && echo "ok   that booking removed the times it covers ($BASE -> $AFTER)" \
  || { echo "FAIL $BASE -> $AFTER"; fail=1; }

as $U1 "insert into closure (tenant_id,on_date) select id,'$DWED' from tenant where slug='studio-mila'" >/dev/null
WED=$(as $U1 "select count(*) from free_slots('studio-mila','$SVC'::uuid,'$DWED','$DWED')")
[ "$WED" = 0 ] && echo "ok   a closed day offers nothing" || { echo "FAIL closed day=$WED"; fail=1; }

# 600 minutes will not fit a 09:00-18:00 window, so it must offer nothing at all
# rather than offer 09:00 and then refuse it
as $U1 "insert into service (tenant_id,name,price_pence,duration_min)
        select id,'Very long thing',20000,600 from tenant where slug='studio-mila'" > /dev/null
LONG=$(as $U1 "select id from service where name='Very long thing'")
BIG=$(as $U1 "select count(*) from free_slots('studio-mila','$LONG'::uuid,'$DTUE','$DSAT')")
[ "$BIG" = 0 ] && echo "ok   a treatment too long for her day offers nothing" || { echo "FAIL $BIG"; fail=1; }

as $U1 "update tenant set notice_hours=48 where slug='studio-mila'" > /dev/null
SOON=$(as $U1 "select count(*) from free_slots('studio-mila','$SVC'::uuid,current_date,current_date+1)")
[ "$SOON" = 0 ] && echo "ok   a 48-hour notice hides tomorrow" || { echo "FAIL soon=$SOON"; fail=1; }
as $U1 "update tenant set notice_hours=0 where slug='studio-mila'" > /dev/null

echo
echo "-- row level security, as a role that does not own the tables --"
# Postgres bypasses RLS for a table owner, so none of the policies are exercised
# unless the query runs as somebody else. This is the part that keeps one
# studio's client list away from every other studio.
psql -q -v ON_ERROR_STOP=1 \
  -c "grant usage on schema public to anon, authenticated" \
  -c "grant select, insert, update, delete on all tables in schema public to authenticated" \
  -c "grant select on all tables in schema public to anon" \
  -c "create role app_user" \
  -c "grant authenticated to app_user" || exit 1

# a second studio, so there is somebody else's data to try to read
as $U2 "select create_studio('other-studio','Other Studio','nails')" > /dev/null
SVC2=$(as $U2 "select id from service where name='Gel manicure'")
as $U2 "update tenant set notice_hours=0 where slug='other-studio'" > /dev/null
as $U2 "select book('other-studio','$SVC2'::uuid,'$DWED 10:00$OFF','Someone Else','else@x.com')" > /dev/null

asrole() { psql -qtA -c "set test.uid='$1'; set role app_user; $2" 2>&1 | tr -d '\n'; }
anon()   { psql -qtA -c "set test.uid=''; set role app_user; $1" 2>&1 | tr -d '\n'; }

N=$(asrole $U1 "select count(*) from booking")
[ "$N" = 1 ] && echo "ok   she sees only her own booking, not the other studio's" \
  || { echo "FAIL she sees $N bookings"; fail=1; }

N=$(anon "select count(*) from booking")
[ "$N" = 0 ] && echo "ok   a signed-out visitor sees no bookings at all" \
  || { echo "FAIL anon sees $N bookings"; fail=1; }

N=$(anon "select count(*) from service where active")
[ "$N" -gt 0 ] && echo "ok   a signed-out visitor can still read the treatments on offer" \
  || { echo "FAIL anon sees $N services"; fail=1; }

want "a signed-out visitor cannot write a booking directly" "violates row-level security" \
  "$(anon "insert into booking (tenant_id,service_id,starts_at,ends_at,client_name,client_email,ref)
       select t.id,'$SVC'::uuid,'$DTUE2 09:00$OFF','$DTUE2 10:00$OFF','Sneak','s@x.com','SNEAK1'
         from tenant t where t.slug='studio-mila'")"

want "but booking through book() still works for them" "" \
  "$(anon "select book('studio-mila','$SVC'::uuid,'$DFRI 11:00$OFF','Walkin','w@x.com')")"

want "she cannot rename another studio" "0" \
  "$(asrole $U1 "with u as (update tenant set display_name='Hijacked' where slug='other-studio' returning 1)
                 select count(*) from u")"

N=$(asrole $U1 "select jsonb_array_length(my_studio()->'bookings')")
[ "$N" -ge 1 ] && echo "ok   my_studio returns her bookings ($N)" || { echo "FAIL my_studio bookings=$N"; fail=1; }
MINE=$(asrole $U1 "select my_studio()->>'slug'")
want "my_studio is scoped to the signed-in owner" "studio-mila" "$MINE"

[ $fail = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail

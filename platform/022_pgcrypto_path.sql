-- 022 — where pgcrypto actually lives.
--
-- book() and studio_book() build their reference with gen_random_bytes, which
-- comes from pgcrypto, and both pin "set search_path = public" so that nothing
-- can be shadowed under them. On a bare Postgres that is fine: 001 runs
-- "create extension if not exists pgcrypto" and it lands in public.
--
-- Supabase already has pgcrypto, installed into the extensions schema. So the
-- create in 001 is a no-op that moves nothing, the pinned search_path cannot
-- see extensions, and every attempt to book dies at the last line before the
-- insert:
--
--     ERROR: function gen_random_bytes(integer) does not exist
--     CONTEXT: PL/pgSQL function book(...) line 81 at assignment
--
-- Both ways in - her client's page and her own diary - so the product does
-- not work at all. No local test could catch it: a bare Postgres puts
-- pgcrypto in public, which is exactly the case that works.
--
-- Naming extensions in the search_path fixes it everywhere, because Postgres
-- ignores a schema in search_path that does not exist. 015 and 018 now create
-- these functions that way; this is for a database that already has them.
alter function book(text, uuid, timestamptz, text, text, text, text, text)
  set search_path = public, extensions;
alter function studio_book(uuid, timestamptz, text, text, text, text)
  set search_path = public, extensions;

-- Nothing new is created here, but the rule is the rule.
select lockdown();

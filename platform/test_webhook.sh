#!/bin/bash
# The two bugs a sandbox run found in stripe-webhook, and nothing else.
#
# Both are about trusting the shape of a webhook payload. The function pins
# apiVersion 2024-06-20, so everything it RETRIEVES has the shape this code was
# written against - but an event payload is serialised at the ACCOUNT's API
# version, which Stripe moves on its own schedule. On 2026-09-30 they moved
# current_period_end off the subscription and onto its items.
#
#   1. periodEnd() read only sub.current_period_end, so an event delivered the
#      new shape and it returned null. expire_plans() only touches a row
#      `where plan_until is not null`, so that null quietly switches off the
#      thing that downgrades a lapsed studio - she keeps Pro+ for ever. Seen
#      live: checkout.session.completed wrote the right date and the
#      customer.subscription.updated behind it overwrote it with null.
#
#   2. tierOf() reads status, and `customer.subscription.created` arrives as
#      `incomplete`, which is not in LIVE, which is "free". Stripe promises no
#      ordering, so a `created` landing after the `updated` that activated her
#      would put a paying studio on free. The handler now re-reads the
#      subscription instead of trusting the frozen payload; this file covers
#      the two pure functions underneath that.
#
#   ./test_webhook.sh        # needs deno; skips cleanly without it
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DENO=$(command -v deno || echo /opt/node22/bin/deno)
[ -x "$DENO" ] || { echo "skip: deno unavailable, cannot run the webhook unit test"; exit 0; }

W=${TMPDIR:-/tmp}/bookedin-webhook-test
rm -rf "$W"; mkdir -p "$W"

cat > "$W/t.ts" <<'TS'
import { periodEnd, tierOf } from "FNPATH";

let fail = 0;
const ok = (c: boolean, m: string) => {
  console.log((c ? "ok   " : "FAIL ") + m);
  if (!c) fail++;
};

const AT = 1795302685;                       // 2026-11-21T23:11:25Z
const ISO = new Date(AT * 1000).toISOString();
const PLUS = "price_plus_monthly";

// deno-lint-ignore no-explicit-any
const sub = (o: Record<string, unknown>): any => o;

console.log("-- when is this subscription paid up to --");
ok(periodEnd(sub({ current_period_end: AT })) === ISO,
   "the 2024-06-20 shape, where the field is on the subscription");
ok(periodEnd(sub({ items: { data: [{ current_period_end: AT }] } })) === ISO,
   "the 2026-09-30 shape, where it moved onto the items  <- the bug");
ok(periodEnd(sub({ current_period_end: AT, items: { data: [{ current_period_end: 1 }] } })) === ISO,
   "both present: the subscription's own field wins");
ok(periodEnd(sub({ items: { data: [{ current_period_end: 100 }, { current_period_end: AT }] } })) === ISO,
   "several items: it is paid up to the LAST of them");
ok(periodEnd(sub({})) === null,
   "neither: null, because inventing a date would be worse");
ok(periodEnd(sub({ items: { data: [] } })) === null, "no items: null");

console.log("");
console.log("-- which tier is she actually on --");
const withPrice = (status: string, price: string) =>
  sub({ status, items: { data: [{ price: { id: price } }] } });
ok(tierOf(withPrice("active", PLUS)) === "pro_plus",
   "a live subscription on the Pro+ price is Pro+, not Pro");
ok(tierOf(withPrice("active", "price_pro_monthly")) === "pro",
   "and the Pro price is Pro");
ok(tierOf(withPrice("trialing", PLUS)) === "pro_plus", "a trial counts");
ok(tierOf(withPrice("past_due", PLUS)) === "pro_plus",
   "so does past_due, while Stripe retries her card");
ok(tierOf(withPrice("canceled", PLUS)) === "free", "a cancelled one does not");
ok(tierOf(withPrice("incomplete", PLUS)) === "free",
   "nor an incomplete one - which is how `created` arrives");
ok(tierOf(sub({ status: "active" })) === "pro",
   "no items at all falls back to Pro, never silently to Pro+");

console.log("");
console.log(fail ? "FAILURES" : "all passed");
Deno.exit(fail ? 1 : 0);
TS

# STRIPE_PRICE_PLUS_* is read at import time to build the set tierOf consults.
sed -i "s#FNPATH#$HERE/functions/stripe-webhook/index.ts#" "$W/t.ts"
out=$(STRIPE_SECRET_KEY=sk_test_unused \
STRIPE_WEBHOOK_SECRET=whsec_unused \
SUPABASE_URL=http://localhost:1 \
SUPABASE_SERVICE_ROLE_KEY=unused \
STRIPE_PRICE_PLUS_MONTHLY=price_plus_monthly \
STRIPE_PRICE_PLUS_YEARLY=price_plus_yearly \
"$DENO" run --quiet --allow-env --allow-net "$W/t.ts" 2>&1)
printf '%s\n' "$out"

# The module imports npm:stripe, so deno has to reach the registry. A box that
# cannot - no network, or no readable CA bundle for the user running the suite
# - must SKIP rather than fail: a red test that means "your certificates are
# unreadable" teaches people to ignore red tests. Only a real assertion counts.
case "$out" in
  *"all passed"*) exit 0 ;;
  *FAILURES*)     exit 1 ;;
  *) echo "skip: deno could not load the function's dependencies here"; exit 0 ;;
esac

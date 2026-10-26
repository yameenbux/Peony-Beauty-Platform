#!/bin/bash
# Creates the two products and four prices Booked In sells, and prints the
# secrets to set. Run it ONCE, against the Booked In Stripe account.
#
#   stripe login                 # pick the Booked In account, not another one
#   ./stripe-setup.sh            # add --live only when you mean it
#
# Prices are immutable in Stripe: you never edit one, you create another and
# point at it. So running this twice makes a second set rather than changing
# the first - which is why it refuses to run if the products already exist.
#
# It does not touch Supabase. Setting a secret is deliberately a thing a person
# does: the value never passes through anything that could log it.
set -u
LIVE=""
[ "${1:-}" = "--live" ] && LIVE="--live"

command -v stripe >/dev/null || { echo "The Stripe CLI is not installed."; exit 1; }

WHO=$(stripe config --list 2>/dev/null | grep -m1 account_id || echo "")
echo "account: ${WHO:-（whatever stripe login selected）}"
echo "mode:    ${LIVE:-test}"
echo
printf 'Create Booked In products and prices in %s mode? [y/N] ' "${LIVE:-test}"
read -r go; [ "$go" = "y" ] || { echo "nothing done"; exit 0; }

# Prices are immutable and products are not unique by name, so a second run
# would quietly produce a second set and nothing would tell you which one
# Supabase is pointing at. Refuse instead.
EXISTING=$(stripe products list $LIVE --limit 100 2>/dev/null \
  | python3 -I -c "
import sys, json
try:    d = json.load(sys.stdin).get('data', [])
except Exception: sys.exit(0)
print('\n'.join(p.get('name','') for p in d))" | grep -c '^Booked In Pro' || true)
if [ "${EXISTING:-0}" -gt 0 ]; then
  echo "This account already has Booked In products. Creating them again would"
  echo "make a second set of prices with nobody able to tell which is live."
  echo "Archive the old ones in the dashboard first, or copy the existing price"
  echo "ids out of it instead of running this."
  exit 1
fi

mk_product() {
  stripe products create $LIVE --name="$1" -d "description=$2" 2>/dev/null \
    | python3 -I -c "import sys,json; print(json.load(sys.stdin)['id'])"
}
mk_price() {   # product, pence, interval, nickname
  stripe prices create $LIVE -d "product=$1" -d "currency=gbp" \
    -d "unit_amount=$2" -d "recurring[interval]=$3" -d "nickname=$4" 2>/dev/null \
    | python3 -I -c "import sys,json; print(json.load(sys.stdin)['id'])"
}

PRO=$(mk_product "Booked In Pro" "Deposits paid straight to you, rebooking and reminders.")
PLUS=$(mk_product "Booked In Pro+" "A waiting list, standing appointments, lapsed patch tests chased, the insurance pack.")
[ -n "$PRO" ] && [ -n "$PLUS" ] || { echo "Could not create the products. Is the CLI logged in?"; exit 1; }

# The figures on the pricing page. If you change them there, change them here,
# and remember a new price id has to reach Supabase or nothing changes.
M=$(mk_price  "$PRO"  1000  month "Pro monthly")
Y=$(mk_price  "$PRO"  9600  year  "Pro yearly")
PM=$(mk_price "$PLUS" 2400  month "Pro+ monthly")
PY=$(mk_price "$PLUS" 23000 year  "Pro+ yearly")

cat <<OUT

Done. Four prices, matching the pricing page:

  Pro    £10 / month   $M
  Pro    £96 / year    $Y
  Pro+   £24 / month   $PM
  Pro+   £230 / year   $PY

Now set these in Supabase (Edge Functions > Secrets). Paste the values in
yourself - the key especially, which should be a RESTRICTED key, not the
unrestricted secret one:

  STRIPE_SECRET_KEY          rk_...   (create it in the Stripe dashboard)
  STRIPE_WEBHOOK_SECRET      whsec_...(from the webhook endpoint, step 2)
  STRIPE_PRICE_MONTHLY       $M
  STRIPE_PRICE_YEARLY        $Y
  STRIPE_PRICE_PLUS_MONTHLY  $PM
  STRIPE_PRICE_PLUS_YEARLY   $PY
  SITE_URL                   https://booked-in.co.uk

Then, in order:

  1. supabase functions deploy checkout
     supabase functions deploy stripe-webhook --no-verify-jwt

  2. Add a webhook endpoint in Stripe pointing at
     https://<ref>.supabase.co/functions/v1/stripe-webhook
     for checkout.session.completed and the three customer.subscription.*
     events. Copy its signing secret into STRIPE_WEBHOOK_SECRET, then DEPLOY
     stripe-webhook AGAIN - a changed secret does not reach a running worker.

  3. Buy one subscription yourself and watch tenant.plan change. Refund it
     after. This is the only test that covers SUPABASE_SERVICE_ROLE_KEY,
     which the sandbox run could not reach and which is the one thing most
     likely to be wrong. platform/README.md step 6 says what to do if it is.
OUT

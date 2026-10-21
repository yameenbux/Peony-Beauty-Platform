// Booked In — the only thing that may change a plan.
//
// Every request is verified against the webhook signing secret before it is
// read. Without that check this endpoint is an open door: anybody who knows
// the URL could post a subscription event and put themselves on Pro.
//
// Deploy:  supabase functions deploy stripe-webhook --no-verify-jwt
//          (--no-verify-jwt because Stripe sends no Supabase JWT; the
//           signature below is what authenticates the caller)
// Secrets: supabase secrets set STRIPE_SECRET_KEY=... STRIPE_WEBHOOK_SECRET=whsec_...

import Stripe from "npm:stripe@16.12.0";
import { createClient } from "jsr:@supabase/supabase-js@2";

const STRIPE_KEY     = Deno.env.get("STRIPE_SECRET_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;
const SUPABASE_URL   = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2024-06-20" });
// set_plan is reachable by service_role and nothing else
const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

function periodEnd(sub: Stripe.Subscription): string | null {
  const s = sub as unknown as { current_period_end?: number };
  return s.current_period_end ? new Date(s.current_period_end * 1000).toISOString() : null;
}

// Only these statuses are worth paying for. past_due keeps her on while Stripe
// retries the card, because cutting a salon off mid-week over a expired card
// is a good way to lose her.
const LIVE = new Set(["active", "trialing", "past_due"]);

// Which tier a live subscription is. Read off the price she is actually being
// charged, not assumed: this said "pro" flat, which would have taken £24 from a
// Pro+ subscriber and given her the £10 plan. Unset means the tier is not on
// sale here, so nothing can match it and nobody is wrongly promoted.
const PLUS_PRICES = new Set(
  [Deno.env.get("STRIPE_PRICE_PLUS_MONTHLY"), Deno.env.get("STRIPE_PRICE_PLUS_YEARLY")]
    .filter((p): p is string => !!p),
);

function tierOf(sub: Stripe.Subscription): string {
  if (!LIVE.has(sub.status)) return "free";
  const onPlus = sub.items?.data?.some((i) => i.price?.id && PLUS_PRICES.has(i.price.id));
  return onPlus ? "pro_plus" : "pro";
}

async function apply(sub: Stripe.Subscription, tenantHint?: string | null) {
  const customer = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
  const tenant = tenantHint ?? sub.metadata?.tenant ?? null;
  const plan = tierOf(sub);
  const { error } = await db.rpc("set_plan", {
    p_customer: customer,
    p_plan: plan,
    p_until: periodEnd(sub),
    p_subscription: sub.id,
    p_tenant: tenant,
  });
  if (error) throw new Error(`set_plan: ${error.message}`);
}

Deno.serve(async (req: Request): Promise<Response> => {
  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("no signature", { status: 400 });

  // the RAW body: parsing it first would change the bytes the signature covers
  const raw = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(raw, sig, WEBHOOK_SECRET);
  } catch (e) {
    console.error("bad signature", e instanceof Error ? e.message : String(e));
    return new Response("bad signature", { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.mode !== "subscription" || !s.subscription) break;
        const id = typeof s.subscription === "string" ? s.subscription : s.subscription.id;
        const sub = await stripe.subscriptions.retrieve(id);
        // client_reference_id is the only thing that ties this first event to a
        // studio, because the customer is brand new
        await apply(sub, s.client_reference_id ?? s.metadata?.tenant ?? null);
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await apply(event.data.object as Stripe.Subscription);
        break;
      default:
        break;   // everything else is none of our business
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("could not apply", event.type, msg);
    // 500 so Stripe retries rather than dropping a plan change on the floor
    return new Response(msg, { status: 500 });
  }
  return new Response("ok");
});

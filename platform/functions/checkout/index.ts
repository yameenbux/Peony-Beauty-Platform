// Booked In — start a subscription.
//
// Called by the app with her access token. It never trusts the browser for
// who she is: the token is exchanged for her studio through my_tenant_for_
// checkout(), which is scoped to auth.uid(). A tenant id posted in the body
// would be a way to buy somebody else a subscription, or worse, attach your
// card to their studio.
//
// Deploy:  supabase functions deploy checkout
// Secrets: supabase secrets set STRIPE_SECRET_KEY=... STRIPE_PRICE_MONTHLY=price_...
//                               STRIPE_PRICE_YEARLY=price_...
//                               STRIPE_PRICE_PLUS_MONTHLY=price_...
//                               STRIPE_PRICE_PLUS_YEARLY=price_... SITE_URL=https://...

import Stripe from "npm:stripe@16.12.0";
import { createClient } from "jsr:@supabase/supabase-js@2";

const STRIPE_KEY    = Deno.env.get("STRIPE_SECRET_KEY")!;
const PRICE_MONTHLY = Deno.env.get("STRIPE_PRICE_MONTHLY")!;
const PRICE_YEARLY  = Deno.env.get("STRIPE_PRICE_YEARLY")!;
// Pro+. Optional, so the function still boots on a project that has not set up
// the tier yet; a request for it without a price configured is refused below
// rather than falling back to Pro, which would charge £10 for a £24 plan.
const PRICE_PLUS_MONTHLY = Deno.env.get("STRIPE_PRICE_PLUS_MONTHLY") ?? "";
const PRICE_PLUS_YEARLY  = Deno.env.get("STRIPE_PRICE_PLUS_YEARLY") ?? "";
const SITE_URL      = Deno.env.get("SITE_URL") ?? "https://booked-in.co.uk";
const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY      = Deno.env.get("SUPABASE_ANON_KEY")!;

const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2024-06-20" });

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": SITE_URL,
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Studio = {
  tenant: string; slug: string; name: string;
  customer: string | null; email: string | null;
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") {
    return Response.json({ error: "POST only" }, { status: 405, headers: CORS });
  }

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) {
    return Response.json({ error: "Sign in first." }, { status: 401, headers: CORS });
  }

  // the anon key plus her token: this client can only see what she can see
  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });

  const { data, error } = await db.rpc("my_tenant_for_checkout");
  if (error) return Response.json({ error: error.message }, { status: 400, headers: CORS });
  const studio = data as Studio | null;
  if (!studio?.tenant) {
    return Response.json({ error: "Make your page first." }, { status: 400, headers: CORS });
  }

  let body: { yearly?: boolean; portal?: boolean; plan?: string } = {};
  try { body = (await req.json()) ?? {}; } catch { /* an empty body means Pro, monthly */ }
  const yearly = body.yearly === true;
  const plus = body.plan === "pro_plus";

  // Managing the card, changing the plan and cancelling all happen in Stripe's
  // own portal. Building those screens would mean handling card data badly.
  if (body.portal) {
    if (!studio.customer) {
      return Response.json({ error: "You are not subscribed yet." },
        { status: 400, headers: CORS });
    }
    try {
      const portal = await stripe.billingPortal.sessions.create({
        customer: studio.customer,
        return_url: `${SITE_URL}/app/`,
      });
      return Response.json({ url: portal.url }, { headers: CORS });
    } catch (e) {
      console.error("portal failed", e instanceof Error ? e.message : String(e));
      return Response.json({ error: "Could not open billing." },
        { status: 502, headers: CORS });
    }
  }

  /* Never silently fall back to the cheaper price: taking £10 from somebody who
     asked for Pro+ is worse than telling her the tier is not ready. */
  const price = plus ? (yearly ? PRICE_PLUS_YEARLY : PRICE_PLUS_MONTHLY)
                     : (yearly ? PRICE_YEARLY : PRICE_MONTHLY);
  if (!price) {
    return Response.json({ error: "That plan is not on sale yet." },
      { status: 400, headers: CORS });
  }

  try {
    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      line_items: [{ price, quantity: 1 }],
      // reuse her customer if she has subscribed before, so a second
      // subscription does not create a second customer record
      ...(studio.customer
        ? { customer: studio.customer }
        : { customer_email: studio.email ?? undefined }),
      client_reference_id: studio.tenant,
      // the first webhook knows the studio only from here; every later one
      // matches on the customer
      subscription_data: { metadata: { tenant: studio.tenant } },
      metadata: { tenant: studio.tenant },
      allow_promotion_codes: true,
      success_url: `${SITE_URL}/app/?paid=1`,
      cancel_url: `${SITE_URL}/app/?paid=0`,
    });
    return Response.json({ url: session.url }, { headers: CORS });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("checkout failed", msg);
    return Response.json({ error: "Could not start checkout." }, { status: 502, headers: CORS });
  }
});

// Booked In — drains the mail outbox.
//
// This is deliberately thin. Every word of every email is composed in SQL by
// queue_mail_for(), which is covered by test_email.sh; all this does is take
// what is queued, hand it to a provider, and record what happened. Logic that
// lives here is logic nothing tests.
//
// WHO MAY CALL THIS. Until 024 the answer was anybody. The handler took no
// request argument -- Deno.serve(async () => ...) -- so there was no JWT
// check, no method check and no secret, and it is deployed --no-verify-jwt.
// The URL is in FUNCTIONS_URL in config.js, which is served to every browser.
// Six anonymous POSTs used to retire every queued message permanently, because
// next_mail() counted a pick-up as a delivery attempt and gives up at five.
//
// THE DATABASE DECIDES, and this is the second attempt at it. The first
// compared the incoming bearer against SUPABASE_SERVICE_ROLE_KEY, which looked
// free - the cron job in 006 already sends exactly that - and did not work:
// the value Supabase injects into a function is not the same string as the
// legacy service-role JWT in the dashboard, so a correctly configured cron job
// was refused. Measured rather than guessed - the job's own bearer decodes to
// role=service_role, iss=supabase, 219 characters, and still got a 401.
//
// So this no longer compares anything. It builds the client from the CALLER's
// token and asks the database for the batch, because Postgres is the one place
// that can actually verify a Supabase JWT's signature. next_mail() is
// executable by service_role and nothing else - 021 revokes it from anon and
// authenticated, and lockdown() asserts that it stays revoked - so a forged
// token, the published anon key, or a signed-in studio's token all fail at the
// RPC rather than being trusted here. No shared secret to rotate, and no
// dependency on what an injected variable happens to contain.
//
// --no-verify-jwt stays, and the above is why it is safe to. Letting the
// gateway verify instead would NOT be enough on its own: it checks that a
// token is validly signed, not which role it carries, so it accepts the
// published anon key and every signed-in studio's token too.
//
// Deploy:  supabase functions deploy send-mail --no-verify-jwt
// Secrets: supabase secrets set RESEND_API_KEY=... MAIL_FROM="Booked In <book@booked-in.co.uk>"
//
// MAIL_FROM is NOT the contact address. These emails land in a lash client's
// inbox, and she has never heard of YSB Designs — a confirmation from that
// domain reads as spam. Send from booked-in.co.uk, which is also the domain to
// verify with Resend. hello@ysbdesigns.uk is where people write back to us.
//
// It is safe to run concurrently: next_mail() takes its batch FOR UPDATE SKIP
// LOCKED, so two runs never pick up the same message.

import { createClient } from "jsr:@supabase/supabase-js@2";

type Mail = {
  id: string;
  to_email: string;
  to_name: string | null;
  subject: string;
  body: string;
  attempts: number;
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const RESEND_KEY   = Deno.env.get("RESEND_API_KEY");
const MAIL_FROM    = Deno.env.get("MAIL_FROM") ?? "Booked In <onboarding@resend.dev>";
const BATCH        = 20;

// The outbox holds client names and addresses, so every call runs as whoever
// the caller proved they are - which, for the cron job, is service_role. No
// module-level client, and no service key held here at all.
function clientFor(token: string) {
  return createClient(SUPABASE_URL, token, { auth: { persistSession: false } });
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

// The plain text is the source of truth. This only dresses it, and turns the
// one link each message carries into something tappable on a phone.
function asHtml(body: string): string {
  const html = escapeHtml(body)
    .replace(/(https?:\/\/[^\s]+)/g,
      '<a href="$1" style="color:#B8465C;font-weight:600">$1</a>')
    .replace(/\n/g, "<br>");
  return `<!doctype html><html><body style="margin:0;background:#FDFAFA">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"
       style="max-width:520px;margin:0 auto;padding:32px 24px;
              font-family:-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;
              font-size:16px;line-height:1.6;color:#2A1119">
  <tr><td style="padding-bottom:24px;border-bottom:1px solid #EFDCDF;
                 font-family:Georgia,serif;font-size:19px;letter-spacing:.09em;
                 text-transform:uppercase;color:#43192A">Booked In</td></tr>
  <tr><td style="padding:28px 0">${html}</td></tr>
  <tr><td style="padding-top:24px;border-top:1px solid #EFDCDF;
                 font-size:12px;color:#80626B">Sent by Booked In on behalf of your studio.</td></tr>
</table></td></tr></table></body></html>`;
}

async function send(m: Mail): Promise<string | null> {
  if (!RESEND_KEY) return "RESEND_API_KEY is not set";
  const to = m.to_name ? `${m.to_name} <${m.to_email}>` : m.to_email;
  let res: Response;
  try {
    res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: MAIL_FROM, to: [to],
        subject: m.subject, text: m.body, html: asHtml(m.body),
      }),
    });
  } catch (e) {
    // a network failure is worth retrying, so report it rather than throwing
    return `network: ${e instanceof Error ? e.message : String(e)}`;
  }
  if (res.ok) return null;
  return `${res.status}: ${(await res.text()).slice(0, 400)}`;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  // One answer for a wrong method and a missing bearer, so this says nothing
  // about which it was.
  if (req.method !== "POST" || !token) {
    return new Response("no", { status: 401 });
  }

  const db = clientFor(token);

  // This call IS the authentication. Only service_role may execute next_mail,
  // so anything else lands in the branch below having proved nothing.
  const { data, error } = await db.rpc("next_mail", { p_limit: BATCH });
  if (error) {
    // A refusal and a genuine fault are told apart for the logs, but a refused
    // caller is given the same bare answer as a missing bearer.
    const refused = /permission denied|JW[TS]|not authori[sz]ed|invalid|42501/i
      .test(`${error.message} ${(error as { code?: string }).code ?? ""}`);
    console.error(refused ? "refused" : "next_mail failed", error.message);
    return refused
      ? new Response("no", { status: 401 })
      : Response.json({ ok: false, error: error.message }, { status: 500 });
  }
  const mail = (data ?? []) as Mail[];

  let sent = 0, failed = 0;
  // one at a time: a provider will rate limit a burst, and a batch of twenty
  // is not worth the complexity of a concurrency pool
  for (const m of mail) {
    const err = await send(m);
    if (err) { failed++; } else { sent++; }
    const { error: markErr } = await db.rpc("mail_sent", { p_id: m.id, p_error: err });
    if (markErr) {
      // The mail may well have gone out, and we have just failed to say so.
      // 024 moved the counter: next_mail() took a five-minute lease and spent
      // no attempt, so this row is picked up again when the lease expires and
      // tried once more. Worst case one duplicate - not a loop, and not a
      // message quietly retired, which is what the old counter would have done.
      console.error("could not record outcome for", m.id, markErr.message);
    }
  }
  return Response.json({ ok: true, picked: mail.length, sent, failed });
});

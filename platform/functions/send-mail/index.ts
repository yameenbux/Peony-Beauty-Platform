// Booked In — drains the mail outbox.
//
// This is deliberately thin. Every word of every email is composed in SQL by
// queue_mail_for(), which is covered by test_email.sh; all this does is take
// what is queued, hand it to a provider, and record what happened. Logic that
// lives here is logic nothing tests.
//
// Deploy:  supabase functions deploy send-mail --no-verify-jwt
// Secrets: supabase secrets set RESEND_API_KEY=... MAIL_FROM="Booked In <book@booked-in.co.uk>"
//
// MAIL_FROM is NOT the contact address. These emails land in a lash client's
// inbox, and she has never heard of YSB Designs — a confirmation from that
// domain reads as spam. Send from booked-in.co.uk, which is also the domain to
// verify with Resend. support@ysbdesigns.uk is where people write back to us.
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
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY   = Deno.env.get("RESEND_API_KEY");
const MAIL_FROM    = Deno.env.get("MAIL_FROM") ?? "Booked In <onboarding@resend.dev>";
const BATCH        = 20;

// The outbox holds client names and addresses, so this runs as service_role
// and the key never leaves the function.
const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

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

Deno.serve(async () => {
  const { data, error } = await db.rpc("next_mail", { p_limit: BATCH });
  if (error) {
    return Response.json({ ok: false, error: error.message }, { status: 500 });
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
      // the mail may well have gone out; attempts was already incremented by
      // next_mail, so the worst case is one duplicate rather than a loop
      console.error("could not record outcome for", m.id, markErr.message);
    }
  }
  return Response.json({ ok: true, picked: mail.length, sent, failed });
});

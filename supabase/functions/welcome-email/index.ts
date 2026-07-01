// Welcome-email Edge Function
// ----------------------------------------------------------------------------
// Triggered by a Database Webhook on INSERT into public.waitlist (see
// supabase/welcome-email.sql). For each real new signup it sends a one-time
// welcome email FROM your personal Gmail (via Gmail SMTP), then stamps
// welcomed_at so nobody is ever emailed twice.
//
// Deploy:
//   supabase functions deploy welcome-email --no-verify-jwt
//
// Required function secrets (supabase secrets set ...):
//   GMAIL_USER            your Gmail address, e.g. nathanbaseball49@gmail.com
//   GMAIL_APP_PASSWORD    a Google app password (requires 2FA on the account)
//   WEBHOOK_SECRET        random string; must match the x-webhook-secret header
//                         configured in the database trigger
// Provided automatically by the Edge runtime:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// ----------------------------------------------------------------------------

import { createClient } from "jsr:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

// Keep this in sync with supabase/keepalive-filter.sql and the GitHub Action.
const KEEPALIVE_KEYWORDS =
  /(keepalive|heartbeat|pingbot|dbwake|cronwake|keepwarm|nosleepdb|botping|nullsignal|synthmail)/i;

// A keepalive fake is any address with a keyword OR on the reserved .invalid TLD.
function isKeepaliveEmail(addr: string): boolean {
  return KEEPALIVE_KEYWORDS.test(addr) || /@[^@]*\.invalid$/i.test(addr);
}

function looksLikeEmail(addr: string): boolean {
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(addr);
}

// Public site URL used for the link in the email.
const SITE_URL = "https://nware49.github.io/nateware/";

function welcomeEmail(toName: string | null) {
  const subject = "welcome to nateware.md";
  const text = [
    `hey${toName ? " " + toName : ""},`,
    "",
    "thanks for dropping your email on nateware.md — you're on the list.",
    "",
    "i'm building in public: software and hardware, sometimes at the same",
    "time. i don't email often, but when i ship something worth seeing,",
    "you'll be among the first to hear about it.",
    "",
    "this note comes straight from my personal inbox, so feel free to just",
    "hit reply — tell me what you're working on, or what you'd want to see.",
    "i read everything.",
    "",
    "— Nate",
    SITE_URL,
  ].join("\n");

  const html = `
  <div style="font-family:'JetBrains Mono',Menlo,Monaco,monospace;font-size:14px;line-height:1.7;color:#1a1a1a;">
    <p>hey${toName ? " " + escapeHtml(toName) : ""},</p>
    <p>thanks for dropping your email on <strong>nateware.md</strong> — you're on the list.</p>
    <p>i'm building in public: software and hardware, sometimes at the same time.
       i don't email often, but when i ship something worth seeing, you'll be
       among the first to hear about it.</p>
    <p>this note comes straight from my personal inbox, so feel free to just hit
       reply — tell me what you're working on, or what you'd want to see. i read
       everything.</p>
    <p>— Nate<br/><a href="${SITE_URL}">nateware.md</a></p>
  </div>`;

  return { subject, text, html };
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string
  ));
}

Deno.serve(async (req) => {
  // 1. Auth: reject anything that doesn't carry our shared secret.
  const expectedSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!expectedSecret || req.headers.get("x-webhook-secret") !== expectedSecret) {
    return new Response("unauthorized", { status: 401 });
  }

  // 2. Parse the Supabase webhook payload.
  let payload: { type?: string; record?: Record<string, unknown> };
  try {
    payload = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  const record = payload.record ?? {};
  const email = String(record.email ?? "").trim();
  const id = record.id;

  if (!email || !looksLikeEmail(email)) {
    return new Response(JSON.stringify({ skipped: "no valid email" }), { status: 200 });
  }

  // 3. Never email the keepalive fakes.
  if (isKeepaliveEmail(email)) {
    return new Response(JSON.stringify({ skipped: "keepalive email" }), { status: 200 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 4. Re-check welcomed_at from the DB (guards against retries / double fires).
  //    Match by id when available, otherwise by email.
  const query = supabase.from("waitlist").select("id, email, welcomed_at").limit(1);
  const { data: rows, error: selErr } = id !== undefined
    ? await query.eq("id", id)
    : await query.eq("email", email);

  if (selErr) {
    console.error("select failed:", selErr.message);
    return new Response("db error", { status: 500 });
  }

  const row = rows?.[0];
  if (row?.welcomed_at) {
    return new Response(JSON.stringify({ skipped: "already welcomed" }), { status: 200 });
  }

  // 5. Send the welcome via Gmail SMTP.
  const gmailUser = Deno.env.get("GMAIL_USER");
  const gmailPass = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!gmailUser || !gmailPass) {
    console.error("missing GMAIL_USER / GMAIL_APP_PASSWORD");
    return new Response("not configured", { status: 500 });
  }

  const { subject, text, html } = welcomeEmail(null);
  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: gmailUser, password: gmailPass },
    },
  });

  try {
    await client.send({
      from: `Nate <${gmailUser}>`,
      to: email,
      subject,
      content: text,
      html,
    });
    await client.close();
  } catch (err) {
    console.error("smtp send failed:", err instanceof Error ? err.message : String(err));
    try { await client.close(); } catch { /* ignore */ }
    return new Response("send failed", { status: 502 });
  }

  // 6. Stamp welcomed_at so this address is never emailed again.
  const stamp = supabase.from("waitlist").update({ welcomed_at: new Date().toISOString() });
  const { error: updErr } = id !== undefined
    ? await stamp.eq("id", id)
    : await stamp.eq("email", email);

  if (updErr) {
    // Email already went out — log but don't fail the request.
    console.error("stamp update failed:", updErr.message);
  }

  return new Response(JSON.stringify({ sent: true, to: email }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

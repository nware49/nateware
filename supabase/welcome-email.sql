-- ============================================================================
-- Welcome email: schema + database webhook
-- ============================================================================
-- Sends a one-time welcome email (from your personal Gmail) the moment a real
-- person joins the waitlist. The actual sending happens in the
-- `welcome-email` Edge Function; this file sets up the table column and the
-- INSERT webhook that triggers it.
--
-- Run this AFTER keepalive-filter.sql (it relies on is_keepalive_email()).
-- Run it in the Supabase SQL editor.
-- ============================================================================

-- 1. Track who has already been welcomed so nobody ever gets two emails.
alter table public.waitlist
  add column if not exists welcomed_at timestamptz;

-- 2. Database webhook: fire the Edge Function on every new signup.
--    We call the Edge Function through pg_net (net.http_post) from a small
--    trigger function. Building the headers/body with jsonb_build_object means
--    there is NO hand-quoted JSON string to get mangled by a copy-paste — set
--    the secret once, in the marked line below.
--
--    The Edge Function is deployed with --no-verify-jwt (so this trigger can
--    reach it without a user JWT), but it's protected by a shared secret: the
--    function rejects any request whose x-webhook-secret header doesn't match
--    its WEBHOOK_SECRET env var. Use the SAME random string here as the value
--    you set for the function's WEBHOOK_SECRET secret.
--
--    The Edge Function itself does the real filtering (keepalive fakes,
--    already-welcomed rows), so this fires broadly and lets the function decide.

-- pg_net ships on hosted Supabase projects; this is a no-op if already enabled.
create extension if not exists pg_net;

create or replace function public.handle_new_signup()
returns trigger
language plpgsql
security definer
set search_path = public, net
as $$
begin
  perform net.http_post(
    url     := 'https://sdmepimcxpywqrlhvcub.supabase.co/functions/v1/welcome-email',
    headers := jsonb_build_object(
      'Content-Type',    'application/json',
      -- ▼▼▼ set this to your WEBHOOK_SECRET (same value as the function secret) ▼▼▼
      'x-webhook-secret', 'REPLACE_WITH_YOUR_WEBHOOK_SECRET'
      -- ▲▲▲
    ),
    body := jsonb_build_object(
      'type',   'INSERT',
      'table',  'waitlist',
      'schema', 'public',
      'record', to_jsonb(new)
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_welcome_email on public.waitlist;

create trigger trg_welcome_email
  after insert on public.waitlist
  for each row
  execute function public.handle_new_signup();

-- ----------------------------------------------------------------------------
-- Notes
-- ----------------------------------------------------------------------------
-- * The function posts { type, table, schema, record } to the Edge Function,
--   matching what functions/welcome-email/index.ts reads (payload.record).
-- * net.http_post is fire-and-forget (async). The send happens in the Edge
--   Function; check its logs under Edge Functions -> welcome-email -> Logs.
-- * To change the secret later, just re-run this file with the new value.
-- * To re-send a welcome to someone, clear their stamp:
--       update public.waitlist set welcomed_at = null where email = '...';

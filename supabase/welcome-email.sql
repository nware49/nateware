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
--    Supabase implements webhooks via the `supabase_functions.http_request`
--    trigger helper (the pg_net / supabase_functions extensions ship enabled
--    on hosted projects). This calls the deployed Edge Function on INSERT.
--
--    The Edge Function is deployed with --no-verify-jwt (so this trigger can
--    reach it without a user JWT), but it's protected by a shared secret: the
--    function rejects any request whose x-webhook-secret header doesn't match
--    its WEBHOOK_SECRET env var. Replace <YOUR_WEBHOOK_SECRET> below with the
--    same random string you set as the function's WEBHOOK_SECRET secret.
--
--    The Edge Function itself does the real filtering (keepalive fakes,
--    already-welcomed rows), so this trigger fires broadly and lets the
--    function decide.

drop trigger if exists trg_welcome_email on public.waitlist;

create trigger trg_welcome_email
  after insert on public.waitlist
  for each row
  execute function supabase_functions.http_request(
    'https://sdmepimcxpywqrlhvcub.supabase.co/functions/v1/welcome-email',
    'POST',
    '{"Content-Type":"application/json","x-webhook-secret":"<YOUR_WEBHOOK_SECRET>"}',
    '{}',
    '5000'
  );

-- ----------------------------------------------------------------------------
-- Notes
-- ----------------------------------------------------------------------------
-- * The webhook posts the standard Supabase payload
--   ({ type, table, record, old_record, schema }) to the function.
-- * If you prefer the dashboard UI instead of this trigger, you can delete the
--   trigger above and create the same thing under
--   Database -> Webhooks -> "Create a new hook" (INSERT on public.waitlist,
--   pointing at the welcome-email function). Keep only one of the two.
-- * To re-send a welcome to someone, clear their stamp:
--       update public.waitlist set welcomed_at = null where email = '...';

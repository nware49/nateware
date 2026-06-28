-- ============================================================================
-- Keepalive fake-email filtering
-- ============================================================================
-- The "Supabase Keepalive" GitHub Action
-- (.github/workflows/supabase-keepalive.yml) inserts one tagged fake signup
-- every 3 days so the free-tier project never pauses. Every fake email's local
-- part contains exactly one of the keywords below (e.g.
-- "keepalive.1a2b3c4d@keepalive.invalid").
--
-- This script gives you a clean way to tell real signups apart from the
-- keepalive noise. Run it once in the Supabase SQL editor.
--
-- IMPORTANT: keep this keyword list in sync with KEYWORDS in
-- .github/workflows/supabase-keepalive.yml.
-- ============================================================================

-- 1. A reusable predicate: is this email a keepalive bot insert?
--    Matches if the local part contains a keyword OR the domain is a reserved
--    .invalid domain (the action only ever uses .invalid domains).
create or replace function public.is_keepalive_email(addr text)
returns boolean
language sql
immutable
as $$
  select
    -- keyword anywhere in the address (case-insensitive)
    addr ~* '(keepalive|heartbeat|pingbot|dbwake|cronwake|keepwarm|nosleepdb|botping|nullsignal|synthmail)'
    -- ...or any address on the reserved .invalid TLD
    or addr ~* '@[^@]*\.invalid$';
$$;

-- 2. A view of only the *real* waitlist signups. Query this instead of the
--    raw table when you want the genuine list.
create or replace view public.real_waitlist as
select *
from public.waitlist
where not public.is_keepalive_email(email);

-- 3. (Optional) A view of just the keepalive inserts, handy for sanity-checking
--    that the cron is actually running.
create or replace view public.keepalive_waitlist as
select *
from public.waitlist
where public.is_keepalive_email(email);

-- ----------------------------------------------------------------------------
-- Optional cleanup
-- ----------------------------------------------------------------------------
-- If you'd rather physically delete the keepalive rows instead of just hiding
-- them behind a view, run this periodically (or once). It's commented out so
-- this script is safe to run as-is.
--
-- delete from public.waitlist where public.is_keepalive_email(email);

-- ----------------------------------------------------------------------------
-- Optional: auto-clean on insert
-- ----------------------------------------------------------------------------
-- Keeps the table itself free of keepalive rows by dropping them right after
-- they're inserted (the insert still wakes the DB, which is all we need).
-- Uncomment to enable.
--
-- create or replace function public.drop_keepalive_rows()
-- returns trigger
-- language plpgsql
-- as $$
-- begin
--   if public.is_keepalive_email(new.email) then
--     return null; -- skip the insert; DB was still touched, so it stays awake
--   end if;
--   return new;
-- end;
-- $$;
--
-- drop trigger if exists trg_drop_keepalive on public.waitlist;
-- create trigger trg_drop_keepalive
--   before insert on public.waitlist
--   for each row execute function public.drop_keepalive_rows();

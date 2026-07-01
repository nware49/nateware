# Supabase setup

Two things live here:

1. **Keepalive** — keeps the free-tier project from pausing (paired with the
   `.github/workflows/supabase-keepalive.yml` GitHub Action).
2. **Welcome email** — emails every real new signup, from your personal Gmail,
   the moment they join the waitlist.

Files:

| File | What it does |
| --- | --- |
| `keepalive-filter.sql` | `is_keepalive_email()` + `real_waitlist` / `keepalive_waitlist` views. |
| `welcome-email.sql` | Adds `welcomed_at` column + the INSERT webhook trigger. |
| `functions/welcome-email/index.ts` | Edge Function that sends the welcome via Gmail SMTP. |

---

## 1. Run the SQL (in order)

In the Supabase dashboard → **SQL editor**, run:

1. `keepalive-filter.sql`
2. `welcome-email.sql` — **first** replace `REPLACE_WITH_YOUR_WEBHOOK_SECRET`
   (marked with ▼▼▼ in the file) with a random string you choose. You'll reuse
   the exact same string as `WEBHOOK_SECRET` below.

> `welcome-email.sql` depends on `is_keepalive_email()` from
> `keepalive-filter.sql`, so run them in that order.

---

## 2. Create a Gmail app password

The welcome email is sent *as* your Gmail account, so it needs an app password:

1. Enable 2-Step Verification on your Google account (required for app passwords).
2. Go to <https://myaccount.google.com/apppasswords>.
3. Create a password (name it e.g. "nateware welcome"). Copy the 16-char value.

---

## 3. Deploy the Edge Function

With the [Supabase CLI](https://supabase.com/docs/guides/cli):

```bash
supabase login
supabase link --project-ref sdmepimcxpywqrlhvcub

# Store the secrets (never commit these):
supabase secrets set \
  GMAIL_USER="nathanbaseball49@gmail.com" \
  GMAIL_APP_PASSWORD="your-16-char-app-password" \
  WEBHOOK_SECRET="the-same-random-string-from-the-sql-trigger"

# Deploy. --no-verify-jwt lets the DB webhook reach it; the function is still
# protected by the WEBHOOK_SECRET shared-secret header.
supabase functions deploy welcome-email --no-verify-jwt
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically — you
don't set those.

---

## 4. Test it

Insert a real-looking row (use a domain that isn't `.invalid` and doesn't
contain a keepalive keyword) from the SQL editor:

```sql
insert into public.waitlist (email) values ('your-other-inbox@gmail.com');
```

Within a few seconds you should get the welcome email, your Gmail **Sent**
folder should show it, and the row's `welcomed_at` should be set:

```sql
select email, welcomed_at from public.waitlist order by welcomed_at desc nulls last;
```

Function logs are under **Edge Functions → welcome-email → Logs** if anything
doesn't fire.

---

## How the pieces fit

```
visitor submits email
        │
        ▼
public.waitlist  ── INSERT ──►  trg_welcome_email (webhook)
        ▲                              │  POST + x-webhook-secret
        │ welcomed_at stamp            ▼
        └──────────────── welcome-email Edge Function
                                       │  - rejects bad secret
                                       │  - skips keepalive *.invalid / keyword rows
                                       │  - skips already-welcomed rows
                                       ▼
                          Gmail SMTP (from your personal inbox)
```

The keepalive cron also inserts into `public.waitlist`, but those addresses all
contain a keyword and use the `.invalid` TLD, so the function skips them — they
keep the DB awake without ever triggering an email.

## Notes & limits

- Free Gmail sends ~500 emails/day (Workspace ~2000). Fine for a waitlist; if
  you ever expect a spike, switch the send path to an email API.
- To re-send a welcome: `update public.waitlist set welcomed_at = null where email = '...';`
- Keep the keepalive keyword list in sync across `keepalive-filter.sql`,
  `functions/welcome-email/index.ts`, and the GitHub Action workflow.

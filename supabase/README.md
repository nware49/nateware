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

The Edge Function (`functions/welcome-email/index.ts`) is the code that actually
sends the email. "Deploying" uploads it to Supabase's cloud so it runs whenever
the webhook calls it. Two ways to do it — pick one:

- **Option A — all in the browser (no CLI, no clone).** Fastest if you just want
  it running.
- **Option B — Supabase CLI.** Better if you'll edit the function often and want
  it version-controlled from your machine.

---

### Option A — Do it in the Supabase dashboard (no CLI)

1. **Create the function.** Dashboard → **Edge Functions** → **Deploy a new
   function** → **Via editor**. Name it exactly `welcome-email`.
2. **Paste the code.** Copy the entire contents of
   `supabase/functions/welcome-email/index.ts` from this repo into the editor
   (open the file on GitHub and copy it).
3. **Turn off JWT verification.** In the function's settings, disable **Verify
   JWT** (this is the dashboard equivalent of `--no-verify-jwt`). The
   `WEBHOOK_SECRET` check is what protects it instead.
4. **Deploy** the function.
5. **Add the secrets.** Dashboard → **Edge Functions** → **Secrets** (or
   **Project Settings → Edge Functions → Secrets**) → add these three:
   - `GMAIL_USER` = your Gmail address
   - `GMAIL_APP_PASSWORD` = the 16-char Google app password (spaces removed)
   - `WEBHOOK_SECRET` = the same random string you put in the SQL trigger
6. That's it — the SQL from step 1 (which you already run in the browser SQL
   editor) is the other half. Skip to **step 4 (Test it)** below.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically in the
dashboard too — you don't add those.

---

### Option B — Supabase CLI

#### 3a. Install the CLI (one time)

The `supabase` command is a separate tool you install on your computer — it's
not part of the website.

- **macOS:** `brew install supabase/tap/supabase`
- **Windows:** `scoop install supabase`
- **Anywhere with Node:** skip installing and prefix every command below with
  `npx`, e.g. `npx supabase login`.

No Docker required — deploying runs in the cloud, not locally.

#### 3b. Open a terminal in this repo

`cd` into your cloned `nateware` folder (the one containing this `supabase/`
directory). The CLI reads the function code from here.

#### 3c. Run the commands

```bash
# 1. Authenticate the CLI to your Supabase account (opens a browser once).
supabase login

# 2. Link THIS folder to your hosted project. The "project ref" is the
#    subdomain of your Supabase URL: https://<ref>.supabase.co
#    (may prompt for your database password).
supabase link --project-ref sdmepimcxpywqrlhvcub

# 3. Store the function's secrets (encrypted on Supabase, never in git).
#    See the table below for what each one is.
supabase secrets set \
  GMAIL_USER="nathanbaseball49@gmail.com" \
  GMAIL_APP_PASSWORD="your-16-char-app-password" \
  WEBHOOK_SECRET="the-same-random-string-from-the-sql-trigger"

# 4. Upload the function and make it live at
#    https://<ref>.supabase.co/functions/v1/welcome-email
supabase functions deploy welcome-email --no-verify-jwt
```

**What the secrets are:**

| Secret | What it is |
| --- | --- |
| `GMAIL_USER` | The Gmail address you send *from*. |
| `GMAIL_APP_PASSWORD` | The 16-char Google **app password** from step 2 — not your normal login password. Strip the spaces Google shows. |
| `WEBHOOK_SECRET` | Any random string, but it **must exactly match** the `x-webhook-secret` value in your SQL trigger, or every call is rejected with 401. |

**Why `--no-verify-jwt`?** By default Supabase rejects any caller that doesn't
present a valid login token (JWT). The database webhook doesn't send one, so
this flag turns that check off — and *that's why* the function verifies
`WEBHOOK_SECRET` itself. The secret header is the replacement lock.

**What you DON'T set:** `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are
injected into every Edge Function automatically. The function uses them to write
the `welcomed_at` stamp back to the table. (The service-role key can bypass all
security rules, which is exactly why it stays server-side in the function and
never touches the website.)

---

## 4. Test it

A live smoke test: pretend to be a signup and confirm the whole chain fires
(insert → trigger → webhook → function → Gmail).

**1. Insert a fake-but-valid row** in the SQL editor. It must NOT look like a
keepalive fake, so use a normal domain (no `.invalid`, no keepalive keyword) —
ideally a second inbox you own so you can see the email land:

```sql
insert into public.waitlist (email) values ('your-other-inbox@gmail.com');
```

**2. Within a few seconds you should see three things:**

- the welcome email in that inbox,
- a copy in your Gmail **Sent** folder (proof it went from your account),
- the row's `welcomed_at` filled in:

```sql
select email, welcomed_at from public.waitlist order by welcomed_at desc nulls last;
```

**3. If nothing arrives,** check **Edge Functions → welcome-email → Logs** in the
dashboard. Most common causes:

- **401 in the logs** → `WEBHOOK_SECRET` doesn't match the value in the SQL trigger.
- **SMTP send failed** → wrong/rotated Gmail app password.
- **No email at all** → 2-Step Verification isn't enabled on the Google account
  (app passwords require it).

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

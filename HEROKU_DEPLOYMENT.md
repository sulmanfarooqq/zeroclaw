# ZeroClaw — Heroku deployment with free persistent memory

This branch adds deployment files only. The ZeroClaw application source is inherited unchanged from the upstream `master` branch.

## Cost model (no paid database)

- **Runtime:** Heroku Basic dyno. Heroku currently lists Basic at $7/month and 512 MB RAM. Eco is cheaper but sleeps after inactivity, so it is not appropriate for an always-on agent.
- **Student credits:** Eligible GitHub Student Developer Pack users may receive $13/month in Heroku platform credits. If the credits are active, one Basic dyno can be covered with $6/month of headroom. This is $0 out of pocket only while the credit is active and the total stays within the allowance.
- **Memory database:** Supabase Free — $0/month, 500 MB Postgres database, 5 GB egress. No Heroku Postgres add-on is created.
- **AI model provider:** model API usage is separate and may cost money. Use a provider/model with a genuinely free quota if you require $0 total spend.

Heroku is not itself a permanently free 24/7 host. Without active student credits, Basic costs money. The Heroku account may require a payment card for student-credit eligibility. Check current terms and billing before deployment.

## What is persistent

ZeroClaw's PostgreSQL memory backend writes memory records to Supabase Postgres. This data is outside the Heroku dyno, so it survives dyno restarts and new container releases.

The dyno filesystem remains ephemeral. Workspace files, locally edited config, local logs and other disk-backed state are not automatically persistent. This setup protects ZeroClaw's configured PostgreSQL memory, not every possible file or runtime state.

Supabase Free projects can pause after roughly seven days with too little database activity. The container runs a small `SELECT 1` keepalive twice daily while the Heroku Basic dyno is running. Supabase says a few real database requests per day are usually enough to prevent inactivity pausing, but this is not an uptime guarantee. A paused Supabase project retains its data and can be resumed in the Supabase dashboard.

## 1. Create a free Supabase database

1. Create a project on [Supabase](https://supabase.com/dashboard).
2. Choose the Free plan. Do not enable paid compute, add-ons, or upgrades.
3. Set a strong database password and save it somewhere private.
4. In the project dashboard, open **Connect**.
5. Copy the **Session pooler** connection string (IPv4-compatible). Use the session pooler on port `5432`, not the transaction pooler on `6543`.
6. Replace the password placeholder with your real database password.

The connection string should resemble:

```text
postgresql://postgres.PROJECT_REF:YOUR_PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres?sslmode=require
```

Do not commit this connection string to GitHub.

## 2. Create the Heroku app

1. Sign in to [Heroku Dashboard](https://dashboard.heroku.com/).
2. Create a new app. Do not add Heroku Postgres or any paid add-on.
3. Open **Settings** and set the app stack to **container** if it is not already selected.
4. Open **Deploy** → **GitHub** and connect the repository `sulmanfarooqq/zeroclaw`.
5. Select branch `heroku-free-deploy`.
6. Enable **Automatic Deploys** for that branch.
7. Deploy the branch once.

The root `heroku.yml` directs Heroku to build `Dockerfile.heroku`. New pushes to this branch are automatically built and released by Heroku's GitHub integration.

## 3. Add the required Heroku Config Vars

In Heroku **Settings → Config Vars**, add:

| Key | Value |
|---|---|
| `SUPABASE_DATABASE_URL` | The complete Supabase Session pooler connection string |
| `REQUIRE_POSTGRES_MEMORY` | `true` |
| `ZEROCLAW_providers__models__openrouter__default__api_key` | Your OpenRouter API key |

Optionally set the model:

| Key | Value |
|---|---|
| `ZEROCLAW_providers__models__openrouter__default__model` | A model ID available to your OpenRouter account |

Use a model/provider with a free quota if you want to avoid model API charges. Free quotas and limits are controlled by the provider and can change.

Do not set a Heroku Postgres add-on or any paid add-on.

## 4. Verify the deployment

1. Open Heroku **Activity** and wait for the Docker build and release to complete.
2. Open **More → View logs** and confirm the Supabase TLS tunnel starts and ZeroClaw initializes PostgreSQL memory.
3. In **Resources**, select one **Basic** web dyno. Do not use Eco if the agent must remain continuously available.
4. Pair the gateway with the ZeroClaw pairing flow. Keep pairing enabled; never expose an unpaired public gateway.
5. Save a test memory, restart the dyno, and ask ZeroClaw to recall it.

The persistence test passes only if the same memory is recalled after the dyno restart.

## 5. Keep costs at zero out of pocket

- Confirm the $13/month Heroku student credit is active before scaling a Basic dyno.
- Do not create Heroku Postgres, Redis, paid add-ons, or paid dynos beyond the student-credit allowance.
- Monitor Heroku invoices and usage. Credits do not cover AI-provider charges or paid third-party add-ons.
- Supabase Free has hard quotas. If its limits are reached, requests may fail; do not upgrade unless you explicitly choose to pay.
- Keep the app to one Basic dyno. Heroku dynos can still restart during routine cycling; persistent memory is protected by the external database.

## Important limitations

- There is no guarantee of truly uninterrupted 24/7 process uptime on one dyno.
- Supabase Free is a free-tier service, not a contractual backup or uptime guarantee. Export important memories periodically if they are irreplaceable.
- Supabase Free projects can pause after a week of low activity. The in-container keepalive helps, but it cannot help while the Heroku dyno itself is stopped.
- Heroku Basic has 512 MB RAM. ZeroClaw may exceed this depending on enabled tools, channels and workload. If it does, the larger dyno may exceed student credits.
- Persistent memory is not the same as persistent workspace files. A future deployment can add object storage or another durable file backend if needed, but that may introduce separate quotas or costs.

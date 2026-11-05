# Deploy ZeroClaw to Heroku with persistent memory

This deployment uses the Heroku container stack and a Heroku Postgres database. The ZeroClaw memory backend is configured as `postgres.default`, so saved conversation memories are stored outside the dyno and survive dyno restarts and redeployments.

## What is persistent

- **Conversation memory:** stored in Heroku Postgres.
- **Runtime/container:** rebuilt from this repository on deployment.
- **Local filesystem:** still ephemeral on Heroku. Files created in the workspace, local configuration edits, and other disk-backed state are not made durable by the Postgres memory backend. Put important files in external object storage or another durable service.

The PostgreSQL driver in this ZeroClaw version uses `NoTls`. The Heroku image therefore runs a local-only `stunnel` client that establishes verified TLS to Heroku Postgres. ZeroClaw connects to the loopback end of that tunnel. The tunnel verifies the AWS RDS CA chain and hostname; do not expose its local port.

## Requirements

- A Heroku account with the Container Registry / container stack available.
- Heroku CLI installed and authenticated.
- A Heroku Postgres Essential-0 add-on.
- An AI provider API key.

## Create the app and database

Replace `APP_NAME` with your Heroku app name.

```bash
heroku login
heroku create APP_NAME
heroku addons:create heroku-postgresql:essential-0 -a APP_NAME
heroku stack:set container -a APP_NAME
heroku config:set REQUIRE_POSTGRES_MEMORY=true -a APP_NAME
```

Heroku automatically exposes the attached database as `DATABASE_URL`. The entrypoint reads that value on every dyno start and configures the Postgres memory backend. `REQUIRE_POSTGRES_MEMORY=true` makes startup fail instead of silently falling back to local SQLite if the database is missing.

## Set the model provider key

Set secrets in the Heroku Dashboard under **Settings → Config Vars**. For the default OpenRouter provider, add:

- Key: `ZEROCLAW_providers__models__openrouter__default__api_key`
- Value: your OpenRouter API key

Do not use the old `OPENROUTER_API_KEY` fallback; this ZeroClaw version uses the `ZEROCLAW_<config_path_with_double_underscores>` override format.

You can also set the model explicitly with:

- Key: `ZEROCLAW_providers__models__openrouter__default__model`
- Value: a model identifier supported by your OpenRouter account

Never commit API keys or database credentials to Git.

## Deploy this branch

From your local clone of the repository:

```bash
git fetch origin
git checkout heroku-persistent-deployment
heroku git:remote -a APP_NAME
git push heroku heroku-persistent-deployment:main
```

The root `heroku.yml` tells Heroku to build `Dockerfile.heroku`. The container starts ZeroClaw's daemon as the web process and binds the gateway to Heroku's injected `PORT`.

Keep one Basic web dyno running:

```bash
heroku ps:scale web=1:basic -a APP_NAME
heroku logs --tail -a APP_NAME
```

The Basic dyno is intended to avoid Eco's idle-sleep behavior. It can still restart during routine dyno cycling or after a fault; Postgres memory is independent of those restarts.

## Pair the gateway

The gateway is configured to require pairing. After the app starts, generate a pairing code:

```bash
heroku run zeroclaw gateway get-paircode --new -a APP_NAME
```

Keep the pairing code private. Do not disable gateway pairing on a public Heroku URL.

## Verify memory persistence

1. Send a message to ZeroClaw that it can save as a memory.
2. Confirm that the message is saved and can be recalled.
3. Restart the dyno:

   ```bash
   heroku dyno:restart -a APP_NAME
   ```

4. Ask ZeroClaw to recall the same memory.

The test passes only if the memory is still available after the restart. Also check `heroku logs --tail -a APP_NAME` for database or TLS tunnel errors.

## Cost and resource limits

The previous GitHub Student offer covered up to $13 USD/month in Heroku credits for eligible students. A Basic dyno plus an Essential-0 database was approximately $12/month under the published prices at the time this deployment was prepared. Confirm current prices and your credit balance in Heroku before enabling resources; overages can be billed to the card on the account.

A Basic dyno has limited memory. Monitor dyno memory and restart logs. If ZeroClaw exceeds the dyno's memory limit, a larger dyno may be required and may exceed the student credit.

## Important limitations

- Postgres memory survives dyno restarts; local workspace files and local configuration changes do not.
- This config disables pgvector by default. PostgreSQL memory uses keyword-based recall unless a compatible vector extension is separately enabled and available.
- A database is not a backup. Configure and verify database backups separately.
- One Basic dyno is not a zero-downtime or uninterrupted-process guarantee. Heroku can cycle dynos; the durable memory database is what protects saved memories.

#!/bin/sh
set -eu

# Heroku injects the HTTP port at runtime. Never hard-code the dyno port.
export ZEROCLAW_gateway__host="${ZEROCLAW_gateway__host:-0.0.0.0}"
export ZEROCLAW_gateway__port="${PORT:-${ZEROCLAW_gateway__port:-42617}}"
export ZEROCLAW_gateway__allow_public_bind="${ZEROCLAW_gateway__allow_public_bind:-true}"
export ZEROCLAW_gateway__require_pairing="${ZEROCLAW_gateway__require_pairing:-true}"

# Use an external free-tier PostgreSQL database. Do not attach paid Heroku Postgres.
DB_URL="${SUPABASE_DATABASE_URL:-}"

if [ -n "$DB_URL" ]; then
  # This ZeroClaw revision's Postgres client uses NoTls. stunnel terminates
  # verified TLS to Supabase and exposes only a loopback TCP socket locally.
  LOCAL_DATABASE_URL="$(SUPABASE_DATABASE_URL="$DB_URL" python3 - <<'PY'
import os
import shlex
from urllib.parse import parse_qsl, quote, unquote, urlencode, urlsplit, urlunsplit

parsed = urlsplit(os.environ["SUPABASE_DATABASE_URL"])
if parsed.scheme not in ("postgres", "postgresql") or not parsed.hostname:
    raise SystemExit("SUPABASE_DATABASE_URL must be a valid postgres:// or postgresql:// URL")

host = parsed.hostname
port = parsed.port or 5432
connect_host = f"[{host}]" if ":" in host else host
username = unquote(parsed.username or "")
password = unquote(parsed.password or "")
database = unquote((parsed.path or "/postgres").lstrip("/"))
if not username or not password or not database:
    raise SystemExit("SUPABASE_DATABASE_URL must include username, password and database")

# Use Debian's system CA bundle, which validates Supabase's public TLS chain.
stunnel_config = f"""foreground = yes
pid = /tmp/zeroclaw-supabase-stunnel.pid
output = /dev/stdout
debug = notice

[supabase-postgres]
client = yes
accept = 127.0.0.1:16432
connect = {connect_host}:{port}
verifyChain = yes
CAfile = /etc/ssl/certs/ca-certificates.crt
checkHost = {host}
sni = {host}
sslVersionMin = TLSv1.2
"""
with open("/tmp/zeroclaw-supabase-stunnel.conf", "w", encoding="utf-8") as f:
    f.write(stunnel_config)

# psql keepalive credentials stay in a mode-0600 temp file, not process args.
pg_env = {
    "PGHOST": "127.0.0.1",
    "PGPORT": "16432",
    "PGUSER": username,
    "PGPASSWORD": password,
    "PGDATABASE": database,
    "PGSSLMODE": "disable",
}
with open("/tmp/zeroclaw-pg-env", "w", encoding="utf-8") as f:
    for key, value in pg_env.items():
        f.write(f"export {key}={shlex.quote(value)}\n")
os.chmod("/tmp/zeroclaw-pg-env", 0o600)

query = [(k, v) for k, v in parse_qsl(parsed.query, keep_blank_values=True)
         if k.lower() != "sslmode"]
query.append(("sslmode", "disable"))
local_user = quote(username, safe="")
local_password = quote(password, safe="")
local_netloc = f"{local_user}:{local_password}@127.0.0.1:16432"
print(urlunsplit(("postgres", local_netloc, "/" + quote(database, safe=""), urlencode(query), "")))
PY
)"
  chmod 600 /tmp/zeroclaw-supabase-stunnel.conf
  . /tmp/zeroclaw-pg-env

  export ZEROCLAW_memory__backend="${ZEROCLAW_memory__backend:-postgres.default}"
  export ZEROCLAW_memory__auto_save="${ZEROCLAW_memory__auto_save:-true}"
  export ZEROCLAW_storage__postgres__default__db_url="$LOCAL_DATABASE_URL"
  export ZEROCLAW_storage__postgres__default__schema="${ZEROCLAW_storage__postgres__default__schema:-public}"
  export ZEROCLAW_storage__postgres__default__table="${ZEROCLAW_storage__postgres__default__table:-memories}"
  export ZEROCLAW_storage__postgres__default__connect_timeout_secs="${ZEROCLAW_storage__postgres__default__connect_timeout_secs:-15}"
  export ZEROCLAW_storage__postgres__default__vector_enabled="${ZEROCLAW_storage__postgres__default__vector_enabled:-false}"
  export ZEROCLAW_storage__postgres__default__vector_dimensions="${ZEROCLAW_storage__postgres__default__vector_dimensions:-1536}"

  stunnel4 /tmp/zeroclaw-supabase-stunnel.conf &
  STUNNEL_PID=$!

  if ! python3 - "$STUNNEL_PID" <<'PY'
import socket
import sys
import time

for _ in range(60):
    try:
        with socket.create_connection(("127.0.0.1", 16432), timeout=0.5):
            sys.exit(0)
    except OSError:
        time.sleep(0.25)
raise SystemExit("Supabase TLS tunnel failed to start")
PY
  then
    kill "$STUNNEL_PID" 2>/dev/null || true
    exit 1
  fi

  # Supabase Free projects may pause after a week with too little DB activity.
  # A lightweight query twice daily helps keep this project active.
  (
    while sleep 43200; do
      if ! psql -X -v ON_ERROR_STOP=1 -q -c 'SELECT 1' >/dev/null 2>&1; then
        echo "Supabase keepalive query failed; check database availability and logs" >&2
      fi
    done
  ) &
elif [ "${REQUIRE_POSTGRES_MEMORY:-true}" = "true" ]; then
  echo "SUPABASE_DATABASE_URL is required; refusing to start with local-only memory" >&2
  exit 1
fi

exec zeroclaw "$@"

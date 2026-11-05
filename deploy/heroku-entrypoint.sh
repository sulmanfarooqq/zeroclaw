#!/bin/sh
set -eu

# Heroku requires the web process to listen on the injected $PORT.
export ZEROCLAW_gateway__host="${ZEROCLAW_gateway__host:-0.0.0.0}"
export ZEROCLAW_gateway__port="${PORT:-${ZEROCLAW_gateway__port:-42617}}"
export ZEROCLAW_gateway__allow_public_bind="${ZEROCLAW_gateway__allow_public_bind:-true}"
export ZEROCLAW_gateway__require_pairing="${ZEROCLAW_gateway__require_pairing:-true}"

if [ -n "${DATABASE_URL:-}" ]; then
  # ZeroClaw's bundled synchronous Postgres driver currently uses NoTls.
  # stunnel provides an authenticated TLS connection to Heroku Postgres while
  # ZeroClaw connects only to a loopback TCP port inside this dyno.
  LOCAL_DATABASE_URL="$(python3 - <<'PY'
import os
from urllib.parse import parse_qsl, quote, unquote, urlencode, urlsplit, urlunsplit

parsed = urlsplit(os.environ["DATABASE_URL"])
if parsed.scheme not in ("postgres", "postgresql") or not parsed.hostname:
    raise SystemExit("DATABASE_URL must be a valid postgres:// or postgresql:// URL")

host = parsed.hostname
port = parsed.port or 5432
connect_host = f"[{host}]" if ":" in host else host

stunnel_config = f"""foreground = yes
output = /dev/stdout
debug = notice

[postgres]
client = yes
accept = 127.0.0.1:16432
connect = {connect_host}:{port}
verifyChain = yes
CAfile = /etc/ssl/certs/aws-rds-global-bundle.pem
checkHost = {host}
sni = {host}
sslVersionMin = TLSv1.2
"""
with open("/tmp/zeroclaw-postgres-stunnel.conf", "w", encoding="utf-8") as config:
    config.write(stunnel_config)

username = quote(unquote(parsed.username or ""), safe="")
password = quote(unquote(parsed.password or ""), safe="")
if not username or not password:
    raise SystemExit("DATABASE_URL must include a username and password")

query = [(key, value) for key, value in parse_qsl(parsed.query, keep_blank_values=True)
         if key.lower() != "sslmode"]
query.append(("sslmode", "disable"))
local_netloc = f"{username}:{password}@127.0.0.1:16432"
print(urlunsplit(("postgres", local_netloc, parsed.path or "/", urlencode(query), "")))
PY
)"
  export ZEROCLAW_memory__backend="${ZEROCLAW_memory__backend:-postgres.default}"
  export ZEROCLAW_memory__auto_save="${ZEROCLAW_memory__auto_save:-true}"
  export ZEROCLAW_storage__postgres__default__db_url="$LOCAL_DATABASE_URL"
  export ZEROCLAW_storage__postgres__default__schema="${ZEROCLAW_storage__postgres__default__schema:-public}"
  export ZEROCLAW_storage__postgres__default__table="${ZEROCLAW_storage__postgres__default__table:-memories}"
  export ZEROCLAW_storage__postgres__default__connect_timeout_secs="${ZEROCLAW_storage__postgres__default__connect_timeout_secs:-15}"
  export ZEROCLAW_storage__postgres__default__vector_enabled="${ZEROCLAW_storage__postgres__default__vector_enabled:-false}"
  export ZEROCLAW_storage__postgres__default__vector_dimensions="${ZEROCLAW_storage__postgres__default__vector_dimensions:-1536}"

  stunnel4 /tmp/zeroclaw-postgres-stunnel.conf &
  STUNNEL_PID=$!
  if ! python3 - "$STUNNEL_PID" <<'PY'
import socket
import sys
import time

for _ in range(50):
    try:
        with socket.create_connection(("127.0.0.1", 16432), timeout=0.25):
            sys.exit(0)
    except OSError:
        time.sleep(0.2)

raise SystemExit("PostgreSQL TLS tunnel failed to start")
PY
  then
    kill "$STUNNEL_PID" 2>/dev/null || true
    exit 1
  fi
elif [ "${REQUIRE_POSTGRES_MEMORY:-false}" = "true" ]; then
  echo "REQUIRE_POSTGRES_MEMORY=true but DATABASE_URL is missing" >&2
  exit 1
fi

exec zeroclaw "$@"

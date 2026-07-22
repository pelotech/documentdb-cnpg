#!/usr/bin/env bash
# documentdb-gw entrypoint. Translates discrete Deployment env vars into the
# DOCUMENTDB_* surface the patched gateway consumes, waits for the backend, execs it.
#
# The gateway takes its PG target only from a file named by DOCUMENTDB_PG_URL_FILE (a
# passwordless postgresql:// URL). It ignores PGHOST/PGPORT/PGUSER/PGDATABASE, and its
# unset-field defaults (localhost/9712/postgres/OS-user) are all wrong for CNPG, so we
# compose the URL from discrete vars here. It runs env-only, no config JSON.
set -euo pipefail

die() { echo "documentdb-gw entrypoint: $*" >&2; exit 1; }

# discrete inputs the Deployment provides
PG_HOST="${PG_HOST:-}"                       # required, e.g. <cluster>-rw.<ns>.svc
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-}"                       # required, the connecting PG role
PG_DATABASE="${PG_DATABASE:-postgres}"
LISTEN_ADDR="${LISTEN_ADDR:-:10260}"         # Mongo-wire listener
PG_TLS_CA_FILE="${PG_TLS_CA_FILE:-}"         # required, CA for verify-full to PG
PG_PASSWORD_FILE="${PG_PASSWORD_FILE:-}"     # required, file holding the SCRAM password
LISTENER_TLS="${LISTENER_TLS:-auto}"         # auto | pem
LOG_LEVEL="${LOG_LEVEL:-info}"
PG_WAIT_TIMEOUT="${PG_WAIT_TIMEOUT:-300}"    # seconds to wait for the backend

# validate required inputs
[ -n "$PG_HOST" ] || die "PG_HOST is required (e.g. <cluster>-rw.<ns>.svc)"
[ -n "$PG_USER" ] || die "PG_USER is required (the connecting PG role)"
[ -n "$PG_TLS_CA_FILE" ] || die "PG_TLS_CA_FILE is required (CA bundle for verify-full to Postgres)"
[ -f "$PG_TLS_CA_FILE" ] || die "PG_TLS_CA_FILE=$PG_TLS_CA_FILE does not exist"
[ -n "$PG_PASSWORD_FILE" ] || die "PG_PASSWORD_FILE is required (file holding the PG role password)"
[ -f "$PG_PASSWORD_FILE" ] || die "PG_PASSWORD_FILE=$PG_PASSWORD_FILE does not exist"

# compose the passwordless PG URL and hand it to the gateway via a file.
# Minimal percent-encoding of the user so role names with special chars survive the URL
# parse; encode PG_USER yourself if it needs characters outside this set. The password
# never goes in the URL (the gateway rejects password-bearing URLs); it comes from the
# file below.
urlencode_user() {
  local s="$1" out="" i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

pg_url="postgresql://$(urlencode_user "$PG_USER")@${PG_HOST}:${PG_PORT}/${PG_DATABASE}"
# /tmp is writable as uid 26; the gateway reads the URL from this file.
url_file="/tmp/pg_url"
umask 077
printf '%s\n' "$pg_url" > "$url_file" || die "failed writing URL file $url_file"

export DOCUMENTDB_PG_URL_FILE="$url_file"
export DOCUMENTDB_PG_PASSWORD_FILE="$PG_PASSWORD_FILE"
export DOCUMENTDB_PG_TLS_CA_FILE="$PG_TLS_CA_FILE"
export DOCUMENTDB_LISTEN_ADDR="$LISTEN_ADDR"
export DOCUMENTDB_LOG_LEVEL="$LOG_LEVEL"

# client-facing (Mongo-wire) TLS on the gateway listener
case "$LISTENER_TLS" in
  auto)
    # Self-signed listener cert generated at startup (dev/testing only). The gateway's
    # generator shells out to the `openssl` CLI, which the hardened base omits, so fail
    # fast with guidance instead of a cryptic "Failed to create TLS provider" panic.
    command -v openssl >/dev/null 2>&1 || die \
      "LISTENER_TLS=auto needs an 'openssl' CLI, which this hardened image omits. Use LISTENER_TLS=pem with a mounted cert (set TLS_CERT_FILE/TLS_KEY_FILE), e.g. issued by cert-manager."
    export DOCUMENTDB_TLS_AUTO_GENERATE=true
    # The gateway writes the generated cert under a TLS state dir, but the hardened
    # base has no writable default for uid 26 and the $HOME fallback may not exist, so
    # auto-gen panics. Point it at a writable, ephemeral dir and ensure it exists.
    tls_state_dir="${DOCUMENTDB_TLS_STATE_DIR:-/tmp/documentdb-gw-tls}"
    mkdir -p "$tls_state_dir" || die "failed creating TLS state dir $tls_state_dir"
    export DOCUMENTDB_TLS_STATE_DIR="$tls_state_dir"
    ;;
  pem)
    [ -n "${TLS_CERT_FILE:-}" ] || die "LISTENER_TLS=pem requires TLS_CERT_FILE"
    [ -n "${TLS_KEY_FILE:-}" ] || die "LISTENER_TLS=pem requires TLS_KEY_FILE"
    [ -f "$TLS_CERT_FILE" ] || die "TLS_CERT_FILE=$TLS_CERT_FILE does not exist"
    [ -f "$TLS_KEY_FILE" ] || die "TLS_KEY_FILE=$TLS_KEY_FILE does not exist"
    export DOCUMENTDB_TLS_CERT_FILE="$TLS_CERT_FILE"
    export DOCUMENTDB_TLS_KEY_FILE="$TLS_KEY_FILE"
    ;;
  *)
    die "LISTENER_TLS must be 'auto' or 'pem' (got '$LISTENER_TLS')"
    ;;
esac

# wait for the Postgres backend to accept connections. pg_isready ships in the CNPG
# base image; it checks only that the listener is up (no TLS/auth) so the gateway does
# not crash-loop while the cluster is still starting.
echo "documentdb-gw entrypoint: waiting up to ${PG_WAIT_TIMEOUT}s for ${PG_HOST}:${PG_PORT}" >&2
deadline=$(( $(date +%s) + PG_WAIT_TIMEOUT ))
until pg_isready -h "$PG_HOST" -p "$PG_PORT" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    die "timed out after ${PG_WAIT_TIMEOUT}s waiting for ${PG_HOST}:${PG_PORT}"
  fi
  sleep 2
done
echo "documentdb-gw entrypoint: ${PG_HOST}:${PG_PORT} is ready; starting gateway" >&2

exec /usr/bin/documentdb_gateway "$@"

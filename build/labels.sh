#!/usr/bin/env bash
# Emit `docker build --label` arguments (one token per line) recording provenance
# that does not belong in the tag: ICU major, documentdb version, target base, and
# Postgres major. Consumed via `mapfile` so values with spaces stay intact.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env
PG_MAJOR="${PG_MAJOR:-$DEFAULT_PG_MAJOR}"
ARTIFACT="${ARTIFACT:-engine}"
base_var="HARDENED_BASE_${PG_MAJOR}"; base="${!base_var:?no hardened base pinned for PG ${PG_MAJOR}}"

case "$ARTIFACT" in
  engine)   desc="DocumentDB-embedded PostgreSQL ${PG_MAJOR}, ICU ${ICU_MAJOR}" ;;
  imagevol) desc="DocumentDB CNPG ImageVolume extension for PostgreSQL ${PG_MAJOR}, ICU ${ICU_MAJOR}" ;;
  *)        echo "unknown ARTIFACT: $ARTIFACT (want engine|imagevol)" >&2; exit 1 ;;
esac

printf '%s\n' \
  --label "org.opencontainers.image.source=https://github.com/pelotech/documentdb-cnpg" \
  --label "org.opencontainers.image.url=https://github.com/pelotech/documentdb-cnpg" \
  --label "org.opencontainers.image.description=${desc}" \
  --label "org.opencontainers.image.base.name=${base%@*}" \
  --label "org.opencontainers.image.base.digest=${base#*@}" \
  --label "com.pelotech.documentdb.icu-major=${ICU_MAJOR}" \
  --label "com.pelotech.documentdb.version=${DOCUMENTDB_TAG#v}" \
  --label "com.pelotech.postgres.major=${PG_MAJOR}"

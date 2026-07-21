#!/usr/bin/env bash
# Single source of truth for image references. Prints the full image ref for a
# given ARTIFACT and PG_MAJOR, so build.sh, build-engine.sh, and CI never re-derive
# the tag formula independently (a mismatch would break docker tag / manifest lookup).
#
#   ARTIFACT=engine   PG_MAJOR=17  -> ${IMAGE_REPO}:<pgver>-documentdb<docver>-icu<icu>
#   ARTIFACT=imagevol PG_MAJOR=18  -> ${IMAGE_REPO}:pg<M>-<docver>-icu<icu>
#
# Engine tags embed the base's PG version (CNPG requires a version-leading tag), read
# by running the pinned base; that needs the hardened-base registry to be reachable.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env
: "${IMAGE_REPO:?set IMAGE_REPO in versions.env}"
PG_MAJOR="${PG_MAJOR:-$DEFAULT_PG_MAJOR}"
ARTIFACT="${ARTIFACT:-engine}"
docver="${DOCUMENTDB_TAG#v}"

case "$ARTIFACT" in
  engine)
    base_var="HARDENED_BASE_${PG_MAJOR}"
    FIPS_BASE="${!base_var:?no hardened base pinned for PG ${PG_MAJOR}}"
    pgver="$(docker run --rm --entrypoint postgres "$FIPS_BASE" --version | grep -m1 -oE '[0-9]+\.[0-9]+')"
    echo "${IMAGE_REPO}:${pgver}-documentdb${docver}-icu${ICU_MAJOR}" ;;
  imagevol)
    echo "${IMAGE_REPO}:pg${PG_MAJOR}-${docver}-icu${ICU_MAJOR}" ;;
  *)
    echo "unknown ARTIFACT: $ARTIFACT (want engine|imagevol)" >&2; exit 1 ;;
esac

#!/usr/bin/env bash
# Single source of truth for image references. Two images: `postgresql-fips` (the
# hardened engine images, one tag per Postgres major) and `extension` (the ImageVolume).
# Engine tags lead with the base's Postgres version because CNPG parses the imageName
# tag for the major version; the extension tag is not consumed as an imageName.
#
#   ARTIFACT=engine   PG_MAJOR=17  REF=<ref>  -> ${IMAGE_REPO}/postgresql-fips:<pgver>-<ref>
#   ARTIFACT=imagevol PG_MAJOR=18  REF=<ref>  -> ${IMAGE_REPO}/extension:pg<M>-<ref>
#
# REF is a git-sha ("git-1a2b3c4"), a release version, or "local" (default) for a
# local build/verify. The engine pgver is read by running the pinned base.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env
: "${IMAGE_REPO:?set IMAGE_REPO in versions.env}"
PG_MAJOR="${PG_MAJOR:-$DEFAULT_PG_MAJOR}"
ARTIFACT="${ARTIFACT:-engine}"
REF="${REF:-local}"

case "$ARTIFACT" in
  engine)
    base_var="HARDENED_BASE_${PG_MAJOR}"
    FIPS_BASE="${!base_var:?no hardened base pinned for PG ${PG_MAJOR}}"
    pgver="$(docker run --rm --entrypoint postgres "$FIPS_BASE" --version | grep -m1 -oE '[0-9]+\.[0-9]+')"
    echo "${IMAGE_REPO}/postgresql-fips:${pgver}-${REF}" ;;
  imagevol)
    echo "${IMAGE_REPO}/extension:pg${PG_MAJOR}-${REF}" ;;
  *)
    echo "unknown ARTIFACT: $ARTIFACT (want engine|imagevol)" >&2; exit 1 ;;
esac

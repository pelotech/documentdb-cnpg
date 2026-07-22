#!/usr/bin/env bash
# Single source of truth for image references. Three images: `postgresql-fips` (the
# hardened engine images, one tag per Postgres major), `extension` (the ImageVolume),
# and `documentdb-gw` (the MongoDB-wire gateway).
# Engine tags lead with the base's Postgres version because CNPG parses the imageName
# tag for the major version; the extension tag is not consumed as an imageName.
#
#   ARTIFACT=engine   PG_MAJOR=17  REF=<ref>  -> ${IMAGE_REPO}/postgresql-fips:<pgver>-<ddb>-icu<ICU_MAJOR>-<ref>
#   ARTIFACT=imagevol PG_MAJOR=18  REF=<ref>  -> ${IMAGE_REPO}/extension:pg<M>-<ddb>-icu<ICU_MAJOR>-<ref>
#   ARTIFACT=gateway               REF=<ref>  -> ${IMAGE_REPO}/documentdb-gw:<ddb>-<ref>
#     (gateway links neither PG nor ICU, so no pgver/icu segment)
#
# <ddb> is DOCUMENTDB_TAG normalized (v0.114-0 -> 0.114.0), the second tag segment;
# icu<ICU_MAJOR> (e.g. icu77) is the third. CNPG's version.FromTag reads only the leading
# `^(\d\.?)+`, so everything after the first `-` is ignored and the pgver must stay first.
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

# documentdb version as a dotted tag segment: v0.114-0 -> 0.114.0
ddb="${DOCUMENTDB_TAG#v}"; ddb="${ddb/-/.}"

case "$ARTIFACT" in
  engine)
    base_var="HARDENED_BASE_${PG_MAJOR}"
    FIPS_BASE="${!base_var:?no hardened base pinned for PG ${PG_MAJOR}}"
    pgver="$(docker run --rm --entrypoint postgres "$FIPS_BASE" --version | grep -m1 -oE '[0-9]+\.[0-9]+')"
    echo "${IMAGE_REPO}/postgresql-fips:${pgver}-${ddb}-icu${ICU_MAJOR}-${REF}" ;;
  imagevol)
    echo "${IMAGE_REPO}/extension:pg${PG_MAJOR}-${ddb}-icu${ICU_MAJOR}-${REF}" ;;
  gateway)
    echo "${IMAGE_REPO}/documentdb-gw:${ddb}-${REF}" ;;
  *)
    echo "unknown ARTIFACT: $ARTIFACT (want engine|imagevol|gateway)" >&2; exit 1 ;;
esac

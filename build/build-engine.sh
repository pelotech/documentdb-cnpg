#!/usr/bin/env bash
# Build a documentdb-embedded engine image for one Postgres major:
# Stage A (.deb via stage-a.sh) -> bake (Dockerfile.engine) into fips:${PG_MAJOR}.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env
: "${IMAGE_REPO:?set IMAGE_REPO in versions.env}"
PG_MAJOR="${PG_MAJOR:-$DEFAULT_PG_MAJOR}"

base_var="HARDENED_BASE_${PG_MAJOR}"
FIPS_BASE="${!base_var:?no hardened base pinned for PG ${PG_MAJOR}}"

host_arch="$(uname -m)"
case "$host_arch" in aarch64|arm64) host_arch=arm64 ;; x86_64|amd64) host_arch=amd64 ;; esac
plat="linux/${TARGETARCH:-$host_arch}"
builder="ddb-builder:pg${PG_MAJOR}"

# CNPG-parseable image tag (embeds the base's PG version) from the single source of truth.
image="$(ARTIFACT=engine PG_MAJOR="$PG_MAJOR" ./build/image-tag.sh)"

debdir="$(PG_MAJOR="$PG_MAJOR" TARGETARCH="${TARGETARCH:-}" ./build/stage-a.sh)"
mapfile -t labels < <(ARTIFACT=engine PG_MAJOR="$PG_MAJOR" ./build/labels.sh)

docker build --platform "$plat" -f build/Dockerfile.engine \
  --build-arg DDB_BUILDER="$builder" \
  --build-arg FIPS_BASE="$FIPS_BASE" \
  --build-arg PG_MAJOR="$PG_MAJOR" \
  --build-context deb-stage="$debdir" \
  "${labels[@]}" \
  -t "$image" .

echo "built $image"

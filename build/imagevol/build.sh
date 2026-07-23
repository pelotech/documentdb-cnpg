#!/usr/bin/env bash
# Build orchestrator: Stage A (.deb via stage-a.sh) -> Stage B (CNPG ImageVolume image).
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a
source versions.env
source "build/imagevol/pins.env"
set +a
: "${IMAGE_REPO:?set IMAGE_REPO in versions.env}"
PG_MAJOR="${PG_MAJOR:-$DEFAULT_PG_MAJOR}"

host_arch="$(uname -m)"
case "$host_arch" in aarch64|arm64) host_arch=arm64 ;; x86_64|amd64) host_arch=amd64 ;; esac
plat="linux/${TARGETARCH:-$host_arch}"

builder="ddb-builder:pg${PG_MAJOR}"
image="$(ARTIFACT=imagevol PG_MAJOR="$PG_MAJOR" ./build/common/image-tag.sh)"

debdir="$(PG_MAJOR="$PG_MAJOR" TARGETARCH="${TARGETARCH:-}" ./build/common/stage-a.sh)"
mapfile -t labels < <(ARTIFACT=imagevol PG_MAJOR="$PG_MAJOR" ./build/common/labels.sh)

# Stage B -> CNPG ImageVolume image (gen_system.sh bundles all non-core deps).
docker build --platform "$plat" -f build/imagevol/Dockerfile.imagevol \
  --build-arg DDB_BUILDER="$builder" \
  --build-context deb-stage="$debdir" \
  "${labels[@]}" \
  -t "$image" .

echo "built $image"

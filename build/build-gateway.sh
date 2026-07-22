#!/usr/bin/env bash
# Build the documentdb-gw image: compile the patched upstream documentdb_gateway in the
# pinned Debian rust builder, then bake the single binary onto the hardened fips base.
# Mirrors build-engine.sh. PG- and ICU-agnostic (the gateway links neither).
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env
: "${IMAGE_REPO:?set IMAGE_REPO in versions.env}"
: "${RUST_BUILDER:?set RUST_BUILDER in versions.env}"
: "${HARDENED_BASE_18:?set HARDENED_BASE_18 in versions.env}"

# Fetch pinned documentdb source (shared with the engine build).
[ -d .work/src ] || git clone --depth 1 --branch "$DOCUMENTDB_TAG" \
  --recurse-submodules --shallow-submodules \
  "https://github.com/documentdb/documentdb.git" .work/src 1>&2

image="$(ARTIFACT=gateway REF="${REF:-local}" ./build/image-tag.sh)"
mapfile -t labels < <(ARTIFACT=gateway ./build/labels.sh)

# Default the target platform to the host arch so callers that don't set TARGETARCH
# don't build amd64 on an arm64 host (yields an amd64 builder image and `exec format
# error`).
host_arch="$(uname -m)"
case "$host_arch" in aarch64|arm64) host_arch=arm64 ;; x86_64|amd64) host_arch=amd64 ;; esac
plat="linux/${TARGETARCH:-$host_arch}"

docker build --platform "$plat" -f build/Dockerfile.gateway \
  --build-arg RUST_BUILDER="$RUST_BUILDER" \
  --build-arg FIPS_BASE="$HARDENED_BASE_18" \
  --build-context gw-src=.work/src/pg_documentdb_gw \
  "${labels[@]}" \
  -t "$image" .

echo "built $image"

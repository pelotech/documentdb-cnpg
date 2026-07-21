#!/usr/bin/env bash
# Produce the Stage-A ICU-77 documentdb .deb for one Postgres major.
# Fetches pinned documentdb source, builds the upstream deb-builder image (ddb-builder:pg${M}),
# then Stage A (Dockerfile.deb) -> a local dir. Prints the output dir on stdout; logs to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env
: "${IMAGE_REPO:?set IMAGE_REPO in versions.env}"
PG_MAJOR="${PG_MAJOR:-$DEFAULT_PG_MAJOR}"

host_arch="$(uname -m)"
case "$host_arch" in aarch64|arm64) host_arch=arm64 ;; x86_64|amd64) host_arch=amd64 ;; esac
plat="linux/${TARGETARCH:-$host_arch}"

work=.work; mkdir -p "$work"
builder="ddb-builder:pg${PG_MAJOR}"
debdir="$work/deb-pg${PG_MAJOR}"

# 1. fetch pinned documentdb source (shared across majors)
[ -d "$work/src" ] || git clone --depth 1 --branch "$DOCUMENTDB_TAG" \
  --recurse-submodules --shallow-submodules \
  "https://github.com/documentdb/documentdb.git" "$work/src" 1>&2

# 2. upstream deb-builder image (per major)
docker build --platform "$plat" -f "$work/src/packaging/deb/Dockerfile-deb" \
  --build-arg BASE_IMAGE=debian:trixie --build-arg POSTGRES_VERSION="$PG_MAJOR" \
  --build-arg DOCUMENTDB_VERSION="${DOCUMENTDB_TAG#v}" -t "$builder" "$work/src" 1>&2

# 3. Stage A -> .deb (per-major output dir)
rm -rf "$debdir"
docker build --platform "$plat" -f build/Dockerfile.deb \
  --build-arg DDB_BUILDER="$builder" \
  --build-arg ICU_VERSION="$ICU_VERSION" \
  --build-arg DOCUMENTDB_TAG="$DOCUMENTDB_TAG" \
  --build-arg PG_MAJOR="$PG_MAJOR" \
  --output "type=local,dest=$debdir" . 1>&2

echo "$debdir"

#!/usr/bin/env bash
# Build orchestrator: fetch pinned documentdb source -> upstream deb-builder ->
# Stage A (ICU-77 .deb) -> Stage B (CNPG ImageVolume image).
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env
: "${IMAGE_REPO:?set IMAGE_REPO in versions.env}"

# Portable target arch (Docker/Go arch names). Override with TARGETARCH=amd64 to cross-build.
host_arch="$(uname -m)"
case "$host_arch" in
  aarch64|arm64) host_arch=arm64 ;;
  x86_64|amd64)  host_arch=amd64 ;;
esac
plat="linux/${TARGETARCH:-$host_arch}"

work=.work; mkdir -p "$work"
image="${IMAGE_REPO}:${DOCUMENTDB_TAG#v}-icu${ICU_MAJOR}"

# 1. fetch pinned documentdb source. Plain anonymous https works in CI (public repo).
#    Locally, if your git rewrites github https->ssh, prepend:
#      git -c url."https://github.com/".insteadOf=git@github.com:
[ -d "$work/src" ] || git clone --depth 1 --branch "$DOCUMENTDB_TAG" \
  --recurse-submodules --shallow-submodules \
  "https://github.com/documentdb/documentdb.git" "$work/src"

# 2. upstream deb-builder image (full dependency tree: libbson, pcre2, Intel
#    decimal-math, postgis, pg_cron, pgvector).
docker build --platform "$plat" -f "$work/src/packaging/deb/Dockerfile-deb" \
  --build-arg BASE_IMAGE=debian:trixie --build-arg POSTGRES_VERSION="$PG_MAJOR" \
  --build-arg DOCUMENTDB_VERSION="${DOCUMENTDB_TAG#v}" -t ddb-builder:local "$work/src"

# 3. Stage A -> .deb (exported to $work/deb). Clear stale output first so Stage B
#    globs exactly the freshly built package(s).
rm -rf "$work/deb"
docker build --platform "$plat" -f build/Dockerfile.deb \
  --build-arg DDB_BUILDER=ddb-builder:local \
  --build-arg ICU_VERSION="$ICU_VERSION" \
  --build-arg DOCUMENTDB_TAG="$DOCUMENTDB_TAG" \
  --build-arg PG_MAJOR="$PG_MAJOR" \
  --output "type=local,dest=$work/deb" .

# 4. Stage B -> CNPG ImageVolume image (gen_system.sh bundles all non-core deps).
docker build --platform "$plat" -f build/Dockerfile.imagevol \
  --build-arg DDB_BUILDER=ddb-builder:local \
  --build-context deb-stage="$work/deb" \
  -t "$image" .

echo "built $image"

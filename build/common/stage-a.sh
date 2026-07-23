#!/usr/bin/env bash
# Produce the Stage-A ICU-77 documentdb .deb for one Postgres major.
# Fetches pinned documentdb source, builds the upstream deb-builder image (ddb-builder:pg${M}),
# then Stage A (Dockerfile.deb) -> a local dir. Prints the output dir on stdout; logs to stderr.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${IMAGE_REPO:?IMAGE_REPO must be exported by the calling build script}"
: "${DOCUMENTDB_TAG:?DOCUMENTDB_TAG must be exported by the calling build script}"
: "${ICU_VERSION:?ICU_VERSION must be exported by the calling build script}"
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

# 1b. The upstream intel-math-lib script fetches from git.launchpad.net, which
# throttles/drops connections from CI (Azure) IP ranges: the fetch dies with
# "expected flush after ref listing" or "the remote end hung up unexpectedly"
# and takes the whole Stage A build with it. Wrap that one fetch in a retry
# loop in our clone of the script so it rides over Launchpad's bad windows.
# Idempotent (marker-guarded) so a reused .work/src is not double-patched.
intel="$work/src/scripts/install_setup_intel_decimal_math_lib.sh"
if [ -f "$intel" ] && ! grep -q 'launchpad fetch retry' "$intel"; then
  FETCH_REPL='n=0; until git fetch --depth 1 origin "$MATH_LIB_VERSION"; do n=$((n+1)); [ "$n" -ge 6 ] && { echo "launchpad fetch failed after $n attempts" >&2; exit 1; }; echo "launchpad fetch retry $n" >&2; sleep "$((n*15))"; done' \
    perl -0pi -e 'BEGIN{$r=$ENV{FETCH_REPL}} s/^git fetch --depth 1 origin "\$MATH_LIB_VERSION"$/$r/m' "$intel" 1>&2
fi

# 2. upstream deb-builder image (per major)
docker build --platform "$plat" -f "$work/src/packaging/deb/Dockerfile-deb" \
  --build-arg BASE_IMAGE=debian:trixie --build-arg POSTGRES_VERSION="$PG_MAJOR" \
  --build-arg DOCUMENTDB_VERSION="${DOCUMENTDB_TAG#v}" -t "$builder" "$work/src" 1>&2

# 3. Stage A -> .deb (per-major output dir)
rm -rf "$debdir"
docker build --platform "$plat" -f build/common/Dockerfile.deb \
  --build-arg DDB_BUILDER="$builder" \
  --build-arg ICU_VERSION="$ICU_VERSION" \
  --build-arg DOCUMENTDB_TAG="$DOCUMENTDB_TAG" \
  --build-arg PG_MAJOR="$PG_MAJOR" \
  --output "type=local,dest=$debdir" . 1>&2

echo "$debdir"

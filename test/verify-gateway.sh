#!/usr/bin/env bash
# Builds the documentdb-gw image, then checks two invariants:
#
#   1. FIPS linkage: the binary must dynamically link the base's libssl.so.3 and
#      libcrypto.so.3 (readelf -d NEEDED). A missing entry, or no openssl NEEDED at all
#      (a vendored static build), fails. readelf is absent from the hardened base, so we
#      extract the binary and run readelf inside the rust builder.
#   2. Runs on base: `documentdb_gateway --help` must run on the base without a bad ELF
#      interpreter ("No such file or directory") or a `GLIBC_... not found`. Confirms the
#      Debian-built binary loads on the MinimOS base.
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env

# Default the platform to the host arch (build-gateway.sh builds host-arch when TARGETARCH
# is unset); defaulting to amd64 would ask for an amd64 variant of an arm64-only image on
# arm64 runners -> "not found" -> pull -> denied.
host_arch="$(uname -m)"
case "$host_arch" in aarch64|arm64) host_arch=arm64 ;; x86_64|amd64) host_arch=amd64 ;; esac
plat="linux/${TARGETARCH:-$host_arch}"

echo "== building documentdb-gw =="
./build/build-gateway.sh
image="$(ARTIFACT=gateway REF="${REF:-local}" ./build/image-tag.sh)"
echo "image: $image"

pass_linkage=0
pass_runsonbase=0

# gate 1: FIPS linkage
echo
echo "== gate 1: FIPS linkage (readelf -d NEEDED) =="
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cid="$(docker create --platform "$plat" "$image")"
docker cp "$cid:/usr/bin/documentdb_gateway" "$workdir/documentdb_gateway"
docker rm -f "$cid" >/dev/null

needed="$(docker run --rm --platform "$plat" -v "$workdir:/in:ro" --entrypoint sh \
  "$RUST_BUILDER" -c 'readelf -d /in/documentdb_gateway | grep NEEDED')"
echo "$needed"

if grep -q 'libssl\.so\.3' <<<"$needed" && grep -q 'libcrypto\.so\.3' <<<"$needed"; then
  echo "PASS: dynamically links libssl.so.3 + libcrypto.so.3 (FIPS crypto from base)"
  pass_linkage=1
else
  echo "FAIL: missing libssl.so.3 and/or libcrypto.so.3 NEEDED (vendored or unlinked OpenSSL)"
fi

# gate 2: runs on base
echo
echo "== gate 2: runs-on-base (interpreter + glibc) =="
set +e
runout="$(docker run --rm --platform "$plat" --entrypoint /usr/bin/documentdb_gateway \
  "$image" --help 2>&1)"
rc=$?
set -e
echo "$runout"
echo "exit: $rc"

if grep -qi 'No such file or directory' <<<"$runout"; then
  echo "FAIL: bad ELF interpreter (loader not found on base)"
elif grep -qi 'GLIBC_.*not found\|version .GLIBC' <<<"$runout"; then
  echo "FAIL: glibc symbol version mismatch against base"
else
  echo "PASS: binary loaded and ran on the hardened base (no bad-interpreter / glibc error)"
  pass_runsonbase=1
fi

# summary
echo
echo "==================== SUMMARY ===================="
echo "image:          $image"
echo "FIPS linkage:   $([ "$pass_linkage"   = 1 ] && echo PASS || echo FAIL)"
echo "runs-on-base:   $([ "$pass_runsonbase" = 1 ] && echo PASS || echo FAIL)"
echo "================================================="
[ "$pass_linkage" = 1 ] && [ "$pass_runsonbase" = 1 ]

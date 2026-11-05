#!/usr/bin/env bash
# Compute the extension's runtime dependency closure.
#
# Transitive ldd closure of every module in /out/lib (the extension .so's we ship),
# minus the libs that must come from the operand: glibc, ICU and the C++ runtime (ABI
# must match the running postgres), and OpenSSL + libpq (the operand's copies, so a FIPS
# operand keeps its own OpenSSL). Everything else is bundled.
#
# Bundling a lib the operand also ships is NOT automatically safe: if it is put on a
# process-wide search path (LD_LIBRARY_PATH / ld_library_path / ldconfig) it replaces the
# operand's copy for postgres itself. The ImageVolume therefore renames every bundled lib
# to a private soname and resolves it via $ORIGIN (build/imagevol/isolate.sh); the engine
# reaches its copy via per-module RPATH.
#
# Inputs: $PKGLIB (installed pkglibdir), modules already copied to /out/lib.
# Output: $SYSTEM_OUT (default /out/system).
set -euo pipefail

: "${PKGLIB:?set PKGLIB to the extension pkglibdir}"
out="${SYSTEM_OUT:-/out/system}"
mkdir -p "$out"

for so in /out/lib/*.so; do
  ldd "$so" 2>/dev/null | awk '/=> \//{print $3}'
done | sort -u | while read -r lib; do
  [ -f "$lib" ] || continue
  name="$(basename "$lib")"
  [ -e "/out/lib/$name" ] && continue   # one of our own modules
  case "$name" in
    libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|ld-linux*|libresolv.so.*|\
    libicudata.so.*|libicui18n.so.*|libicuuc.so.*|libstdc++.so.*|libgcc_s.so.*|\
    libssl.so.*|libcrypto.so.*|libpq.so.*) continue;;
  esac
  cp -aL "$lib" "$out/"
done

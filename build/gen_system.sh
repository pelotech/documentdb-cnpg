#!/usr/bin/env bash
# Compute the extension's /system runtime dependency closure.
#
# Transitive ldd closure of every .so that gets loaded (everything in
# shared_preload_libraries plus everything `CREATE EXTENSION documentdb CASCADE`
# pulls in), minus ONLY the hard-core libs (glibc / ICU / C++ runtime) that must
# come from the base to stay ABI-consistent. Everything else is bundled.
#
# Over-bundling a lib the base also ships is safe (the same soname resolves from
# /lib or /system) and needs no base introspection; an earlier base-lib *diff*
# attempt false-positived on libxml2 and dropped a needed lib. This trades a
# slightly larger image for correctness and simplicity.
#
# Inputs: $PKGLIB (dir with the installed extension libs); writes /out/system.
set -euo pipefail

: "${PKGLIB:?set PKGLIB to the extension pkglibdir}"
mkdir -p /out/system

for so in "$PKGLIB"/pg_documentdb*.so "$PKGLIB"/pg_cron.so "$PKGLIB"/postgis-3.so "$PKGLIB"/vector.so; do
  [ -e "$so" ] || continue   # tolerate an absent input rather than aborting the closure
  ldd "$so" 2>/dev/null | awk '/=> \//{print $3}'
done | sort -u | while read -r lib; do
  [ -f "$lib" ] || continue
  case "$(basename "$lib")" in
    libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|ld-linux*|libresolv.so.*|\
    libicudata.so.*|libicui18n.so.*|libicuuc.so.*|libstdc++.so.*|libgcc_s.so.*) continue;;
  esac
  cp -aL "$lib" /out/system/
done

#!/usr/bin/env bash
# Make /out/lib self-resolving without any ld_library_path (pglayers "isolated layout").
#
# Every bundled dep from $1 is renamed to pglx_documentdb_<soname> (file and SONAME),
# every NEEDED entry that names a bundled dep is rewritten to the mangled name, and every
# ELF in /out/lib gets RUNPATH=$ORIGIN. The dynamic linker then finds bundled deps next to
# the module that needs them, the private sonames cannot collide with anything postgres
# has loaded, and libs we do not bundle (glibc, ICU, OpenSSL, libpq) come from the operand.
set -euo pipefail
deps="${1:?usage: isolate.sh <deps-dir>}"
lib=/out/lib
tag=pglx_documentdb_

for dep in "$deps"/*; do
  [ -f "$dep" ] || continue
  soname="$(patchelf --print-soname "$dep" 2>/dev/null || true)"
  [ -n "$soname" ] || soname="$(basename "$dep")"
  cp -L "$dep" "$lib/${tag}${soname}"
  patchelf --set-soname "${tag}${soname}" "$lib/${tag}${soname}"
done

for obj in "$lib"/*.so*; do
  [ -f "$obj" ] || continue
  for need in $(patchelf --print-needed "$obj"); do
    case "$need" in "$tag"*) continue ;; esac
    if [ -f "$lib/${tag}${need}" ]; then
      patchelf --replace-needed "$need" "${tag}${need}" "$obj"
    fi
  done
  patchelf --set-rpath '$ORIGIN' "$obj"
done

# Fail the build if any shipped ELF still names an unmangled lib we meant to bundle.
for obj in "$lib"/*.so*; do
  for need in $(patchelf --print-needed "$obj"); do
    case "$need" in "$tag"*) continue ;; esac
    if [ -e "$deps/$need" ]; then echo "unmangled NEEDED $need in $obj" >&2; exit 1; fi
  done
done

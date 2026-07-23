#!/usr/bin/env bash
# Assert pins shared across build/<artifact>/pins.env agree, so a documentdb / ICU / base bump
# that must hit multiple artifacts cannot silently land in only some of them. Strict by design:
# building an artifact against a different documentdb than the others requires relaxing this guard.
set -euo pipefail
cd "$(dirname "$0")/../.."

E=build/engine/pins.env
I=build/imagevol/pins.env
G=build/gateway/pins.env

# read one key from one pins.env in an isolated subshell (robust to quoting/comments)
val() { ( set +u; source "$1" >/dev/null 2>&1; printf '%s' "${!2-}" ); }

fail=0
check() { # check KEY FILE...
  local key="$1"; shift
  local first="" ref="" f v
  for f in "$@"; do
    v="$(val "$f" "$key")"
    if [ -z "$v" ]; then echo "::error::$key missing in $f"; fail=1; continue; fi
    if [ -z "$ref" ]; then first="$v"; ref="$f"
    elif [ "$v" != "$first" ]; then echo "::error::$key mismatch: $ref=$first vs $f=$v"; fail=1; fi
  done
  [ "$fail" = 1 ] || echo "OK: $key=$first"
}

check DOCUMENTDB_TAG  "$E" "$I" "$G"
check ICU_VERSION     "$E" "$I"
check ICU_MAJOR       "$E" "$I"
check HARDENED_BASE_18 "$E" "$I" "$G"
exit "$fail"

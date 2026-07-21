# Design notes

## ICU 77

DocumentDB does not link ICU. It references versioned ICU collation symbols
(`ucol_getSortKey_77`, `ucol_open_77`, ...) and resolves them from the host
Postgres process at load time. The extension's build-time ICU major must
therefore match the base's ICU major.

The target base (`cloudnative-pg-postgresql-fips`) ships ICU 77. Upstream
DocumentDB packages ship ICU 67/72/76 depending on the distribution, none of
which is 77, so this repo rebuilds the extension against ICU 77 from source.

## Two delivery mechanisms

**ImageVolume.** DocumentDB is mounted as a CNPG `ImageVolume`, with
`extension_control_path` and `dynamic_library_path` pointing at the mount. This
relies on `extension_control_path`, which was added in Postgres 18, so it is
PG18-only.

**Embedded engine image.** DocumentDB is baked into the base image's standard
extension directories and the image runs as the cluster `imageName`. This works
on any major and is used for PG17 and PG18 in the migration chain below.

## Engine image bake

The base is MinimOS, not Debian: `pkglibdir` is `/usr/lib/postgresql<M>` and
there is no multiarch library directory. The build:

- copies only the DocumentDB and dependency extension modules (`documentdb`,
  `postgis`, `pg_cron`, `vector`, `rum`) into `pkglibdir`, not the whole
  directory, so base Postgres modules are left in place;
- rewrites each module's RPATH (`patchelf`) to `pkglibdir` plus
  `/usr/lib/documentdb-system`, because the Debian build's RPATH does not exist
  on MinimOS and `ldconfig` does not index the non-`lib*` module files;
- bundles the extension's non-base runtime dependencies into
  `/usr/lib/documentdb-system`, skipping the base's FIPS `libcrypto`/`libssl`
  so the certified crypto libraries are not shadowed.

## Guards

- Build: the compiled core `.so` must reference `ucol_*_77` and no `ucol_*_76`.
- CI: the base still ships ICU 77; the built `.so`'s maximum `GLIBC_x.y` symbol
  version is `<=` the base's glibc.
- Acceptance: a CNPG cluster on the base loads the extension
  (`CREATE EXTENSION documentdb CASCADE`) and round-trips a document.

## Migration

Moving an existing deployment off a FerretDB documentdb operand onto this stack
is documented in [migrating-from-ferretdb.md](migrating-from-ferretdb.md).

# Design notes

## ICU

DocumentDB does not link ICU. It references versioned ICU collation symbols
(`ucol_getSortKey_76`, `ucol_open_76`, ...) and resolves them from the host
Postgres process at load time. The extension's build-time ICU major must
therefore match the base's ICU major.

The target base (`ghcr.io/cloudnative-pg/postgresql:<ver>-standard-trixie`) is
Debian trixie with PGDG Postgres and ships ICU 76. Upstream's deb builder runs
on `debian:trixie` too, so the extension links the same distro ICU with no
source-built ICU; `ICU_MAJOR` in the pins records it and the guards below fail
the build if base and builder drift apart.

## Two delivery mechanisms

**ImageVolume.** DocumentDB is mounted as a CNPG `ImageVolume`, with
`extension_control_path` and `dynamic_library_path` pointing at the mount. This
relies on `extension_control_path`, which was added in Postgres 18, so it is
PG18-only.

**Embedded engine image.** DocumentDB is baked into the base image's standard
extension directories and the image runs as the cluster `imageName`. This works
on any major and is used for PG17 and PG18 in the migration chain below.

## Engine image bake

The base is Debian/PGDG: `pkglibdir` is `/usr/lib/postgresql/<M>/lib` and
`sharedir` is `/usr/share/postgresql/<M>`, the same layout as the builder; the
bake asserts both so a layout change fails the build. The build:

- copies only the DocumentDB and dependency extension modules (`documentdb`,
  `postgis`, `pg_cron`, `vector`, `rum`) into `pkglibdir`, not the whole
  directory, so base Postgres modules are left in place;
- bundles the extension's non-core runtime dependencies (postgis' GEOS/PROJ/GDAL
  tree and so on, which the base does not ship) into `/usr/lib/documentdb-system`,
  using the same closure as the ImageVolume `/system` (`gen_system.sh`);
- rewrites each module's RPATH (`patchelf`) to `pkglibdir` plus
  `/usr/lib/documentdb-system`, so the bundled libraries are only visible to
  these modules and the system `ldconfig` cache is left alone;
- runs `ldd` on `pg_documentdb.so` and `postgis-3.so` in the final image and
  fails on any unresolved dependency.

## Guards

- Build: the builder's ICU is `ICU_MAJOR`, and the compiled core `.so` references
  `ucol_*_<ICU_MAJOR>` and no other ICU major.
- CI: the base still ships ICU `ICU_MAJOR`; the built `.so`'s maximum `GLIBC_x.y`
  symbol version is `<=` the base's glibc.
- Acceptance: a CNPG cluster on the base loads the extension
  (`CREATE EXTENSION documentdb CASCADE`) and round-trips a document.

## Migration

Moving an existing deployment off a FerretDB documentdb operand onto this stack
is documented in [migrating-from-ferretdb.md](migrating-from-ferretdb.md).

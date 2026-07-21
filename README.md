# documentdb-cnpg-extension

Builds the [DocumentDB](https://github.com/documentdb/documentdb) Postgres
extension linked against ICU 77, for use with [CloudNativePG](https://cloudnative-pg.io/)
on the hardened Minimus `cloudnative-pg-postgresql-fips` base images.

DocumentDB resolves versioned ICU collation symbols (e.g. `ucol_getSortKey_77`)
from the host Postgres process rather than bundling its own ICU, so the
extension's build-time ICU major has to match the base image's ICU major.
Upstream only ships deb/rhel builds against ICU 60-76; none of those match the
Minimus base, which is on ICU 77, so this repo builds its own.

Two artifacts come out of that build:

- **Engine images**, for PG17 and PG18: documentdb baked directly into the
  Minimus `fips` base, consumed as a cluster's `imageName`.
- **ImageVolume extension**, PG18 only: documentdb packaged as a CNPG
  `ImageVolume` image and mounted into a stock `fips:18` cluster. This needs
  the `extension_control_path` GUC, which only exists in Postgres 18, so it
  can't target PG17.

## Quickstart

Set `IMAGE_REPO` in `versions.env` to your registry namespace, then build and
verify whichever artifact you need.

Engine image:

```bash
PG_MAJOR=17 ./build/build-engine.sh
ENGINE_IMAGE=<printed tag> KIND_EPHEMERAL=1 ./test/verify-engine.sh
```

ImageVolume extension:

```bash
PG_MAJOR=18 ./build/build.sh
EXT_IMAGE=<printed tag> KIND_EPHEMERAL=1 ./test/verify.sh
```

Tags:

- Engine: `<pgver>-documentdb<docver>-icu77`, e.g. `17.10-documentdb0.114-0-icu77`.
  The tag leads with the base's full Postgres version because CNPG parses the
  `imageName` tag to detect major-version upgrades.
- ImageVolume: `pg18-<docver>-icu77`, e.g. `pg18-0.114-0-icu77`.

Both `verify.sh` and `verify-engine.sh` bring up a CNPG cluster, wait for
`Ready`, assert `CREATE EXTENSION documentdb CASCADE` pulls in `documentdb`,
`postgis`, `pg_cron`, and `vector`, and round-trip a smoke document through
the documentdb API.

## How it works

Both artifacts share a common Stage A (`build/stage-a.sh`, `build/Dockerfile.deb`):
it takes the pinned upstream `documentdb/documentdb` source, builds it with
upstream's own `packaging/deb/Dockerfile-deb`, links it against an
ICU-77-from-source install, and emits a `.deb`. A build-time `objdump` check
confirms the result links `ucol_*_77` symbols and nothing from ICU 76.

From there the two artifacts diverge:

- **Engine** (`build/build-engine.sh`, `Dockerfile.engine`): installs the
  `.deb` straight into `FROM fips:${PG_MAJOR}`, patches module RPATHs with
  `patchelf` so dependencies resolve without `ldconfig`, and bundles the
  extension's non-core shared library dependencies alongside the base's own
  `/system` libraries without shadowing its FIPS-certified crypto.
- **ImageVolume** (`build/build.sh`, `Dockerfile.imagevol`): lays the same
  `.deb` out as a standalone `/lib` + `/share` + `/system` tree in the shape
  CNPG expects for an `ImageVolume` mount, with no base image involved.

## Migration flow

The engine images exist to carry documentdb through a Postgres upgrade chain
that starts on FerretDB's own images and ends on the hardened Minimus stack:

1. FerretDB `16` to FerretDB `17` - a CNPG major upgrade on FerretDB's own
   published images (Debian 12, ICU 72). Outside this repo's scope.
2. FerretDB `17` (ICU 72) to this repo's PG17 engine image (Minimus, ICU 77) -
   a same-major engine swap. This is where the ICU 72 to 77 jump happens, so
   it's also where collation versions need refreshing (`ALTER DATABASE ...
   REFRESH COLLATION VERSION` / `REINDEX`).
3. PG17 engine to PG18 engine - a CNPG major upgrade, ICU 77 throughout.
   `pg_upgrade` finds documentdb because it's already baked into the PG18
   engine image.
4. PG18 engine to stock `fips:18` plus the documentdb ImageVolume - a final
   same-major swap onto the ImageVolume artifact.

There's no PG16 engine image: FerretDB already covers 16 and 17, so this repo
only needs to supply an engine from step 2 onward.

## Pins

All reproducibility inputs - the documentdb source tag, ICU version, hardened
base digests, and which Postgres majors get engine vs. ImageVolume builds -
live in `versions.env`.

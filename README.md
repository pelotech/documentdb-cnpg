# documentdb-cnpg-extension

Builds the [DocumentDB](https://github.com/documentdb/documentdb) PostgreSQL 18
extension linked against **ICU 77**, packaged as a
[CloudNativePG](https://cloudnative-pg.io/) `ImageVolume` extension image, and
verifies it loads on a hardened ICU-77 Postgres base. DocumentDB does not carry
its own ICU — it resolves versioned ICU collation symbols (e.g.
`ucol_getSortKey_77`) from the host Postgres process — so the extension's
build-time ICU major must match the base's ICU major. Upstream ships deb11/12/13
and rhel8/9 builds (ICU 67/72/76/60/67); none is 77, so this repo produces one.

## Quickstart

Pins live in [`versions.env`](versions.env). Set `IMAGE_REPO` to your registry
namespace, then build and verify:

```bash
# 1. set IMAGE_REPO in versions.env (e.g. ghcr.io/<org>/documentdb-cnpg-extension)

# 2. build the extension image (fetches pinned documentdb source, builds ICU-77 .deb,
#    packages as a CNPG ImageVolume image)
./build/build.sh

# 3. verify it loads on the hardened base and CREATE EXTENSION documentdb succeeds
EXT_IMAGE="$(source versions.env; echo ${IMAGE_REPO}:${DOCUMENTDB_TAG#v}-icu${ICU_MAJOR})" \
  KIND_EPHEMERAL=1 ./test/verify.sh
```

The build is arm64-proven end-to-end; amd64 is gated behind its own passing
verification run.

## How it works

Two Docker stages, orchestrated by `build/build.sh`:

- **Stage A** (`build/Dockerfile.deb`) consumes the pinned upstream
  `documentdb/documentdb` source at `DOCUMENTDB_TAG`, reuses its
  `packaging/deb/Dockerfile-deb` as the builder, overlays an ICU-77-from-source
  install so the extension links ICU 77, and emits a `.deb`. A build-time
  `objdump` guard asserts the extension links `ucol_*_77` and no `_76` symbol.
- **Stage B** (`build/Dockerfile.imagevol`) installs that `.deb` and lays the
  files out as a CNPG `ImageVolume` image: extension `.so`s in `/lib`, control +
  SQL in `/share`, and the extension's transitive runtime dependency closure
  (minus the core glibc/ICU/C++ libs that must come from the base) in `/system`.

`test/verify.sh` is the acceptance gate: it brings up a CNPG cluster on the
hardened base mounting the built image, waits for `Ready`, asserts
`CREATE EXTENSION documentdb CASCADE` pulls in `documentdb`, `postgis`,
`pg_cron`, and `vector`, and round-trips a smoke document. A build is
publishable for an arch only when that arch's gate is green.

## Pins

All reproducibility inputs live in `versions.env`: the documentdb source tag, the
ICU source version, the hardened base image digest, and the Postgres major.
Bump deliberately — every bump re-runs the full verification gate.

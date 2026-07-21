# documentdb-cnpg

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

Two images: `<IMAGE_REPO>/postgresql-fips` (the hardened engine images, one tag
per Postgres major) and `<IMAGE_REPO>/extension` (the ImageVolume). The build
scripts print the full reference. The `-fips` suffix leaves room for an
unhardened engine variant later.

Engine tags lead with the base's full Postgres version, because CNPG parses the
engine `imageName` tag to detect major-version upgrades: `postgresql-fips:17.10-<ref>`
and `postgresql-fips:18.4-<ref>` (a local build is `postgresql-fips:17.10-local`).
The extension tag carries the major as `extension:pg18-<ref>` and has no
version-leading constraint.

The ICU major, documentdb version, and pinned base are recorded as OCI image
labels (`docker inspect`), not in the tag.

Both `verify.sh` and `verify-engine.sh` bring up a CNPG cluster, wait for
`Ready`, assert `CREATE EXTENSION documentdb CASCADE` pulls in `documentdb`,
`postgis`, `pg_cron`, and `vector`, and round-trip a smoke document through
the documentdb API.

## Using it in a cluster

Two supported delivery paths, matching the two artifacts. Both are what CI
stands up and asserts green on both arches; the only differences here are that
CI `kind load`s locally-built images (so it sets `pullPolicy: Never`) whereas
these pull the published tags from GHCR, and CI uses a throwaway 1Gi single
instance. Replace `0.1.2` with the release you want.

Two settings are load-bearing on every cluster and are easy to miss:

- `shared_preload_libraries: [pg_cron, pg_documentdb_core, pg_documentdb]`.
- A loopback `trust` rule in `pg_hba`. documentdb opens an internal libpq
  connection back to itself (`host=localhost`, no password) for
  `create_collection` / DDL, and that self-connection must authenticate. It is
  a real requirement, not a test shortcut. Tighten the rule as your posture
  needs, but the self-connection must still succeed.

### Path A — engine image (documentdb baked in)

The image is a hardened `fips` Postgres with documentdb already inside, so you
only set `imageName`. Works on PG17 and PG18, needs nothing beyond CNPG.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: documentdb
spec:
  instances: 1
  # documentdb + ICU 77 baked into the hardened Minimus fips base.
  # PG17: postgresql-fips:17.10-0.1.2   PG18: postgresql-fips:18.4-0.1.2
  imageName: ghcr.io/pelotech/documentdb-cnpg/postgresql-fips:18.4-0.1.2
  enableSuperuserAccess: true          # lets you psql -U postgres for the smoke test
  storage:
    size: 10Gi
  postgresql:
    shared_preload_libraries: [pg_cron, pg_documentdb_core, pg_documentdb]
    parameters:
      cron.database_name: postgres
      max_replication_slots: "10"
      max_wal_senders: "10"
    pg_hba:
      - host all all 127.0.0.1/32 trust
      - host all all ::1/128 trust
  bootstrap:
    initdb:
      database: postgres
      postInitSQL:
        - "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"
```

### Path B — ImageVolume extension (stock base + mounted extension), PG18 only

The cluster runs a **stock** hardened `fips:18` base and CNPG mounts documentdb
as a declarative extension via an ImageVolume. PG18-only, because it needs the
`extension_control_path` GUC. **Requires Kubernetes >= 1.35 with the
`ImageVolume` feature gate enabled, and CNPG >= 1.27.**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: documentdb
spec:
  instances: 1
  # Stock hardened Minimus fips:18 base — documentdb is NOT in this image; it is
  # mounted from the extension ImageVolume below. The base MUST be ICU 77 (this
  # pinned digest is), because documentdb links versioned ucol_*_77 symbols.
  imageName: reg.mini.dev/cloudnative-pg-postgresql-fips:18.4@sha256:9bbeaf6f3dc096cea12a5ff5112ffa81e76c9c4c86b49d765579ed71ea55db31
  enableSuperuserAccess: true
  storage:
    size: 10Gi
  postgresql:
    shared_preload_libraries: [pg_cron, pg_documentdb_core, pg_documentdb]
    parameters:
      cron.database_name: postgres
      max_replication_slots: "10"
      max_wal_senders: "10"
    pg_hba:
      - host all all 127.0.0.1/32 trust
      - host all all ::1/128 trust
    extensions:
      - name: documentdb
        image:
          reference: ghcr.io/pelotech/documentdb-cnpg/extension:pg18-0.1.2
        extension_control_path: [share]
        dynamic_library_path: [lib]
        ld_library_path: [lib, system]
  bootstrap:
    initdb:
      database: postgres
      postInitSQL:
        - "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"
```

### Verify (the same assertions CI gates on)

```bash
kubectl apply -f cluster.yaml
kubectl wait --for=condition=Ready cluster/documentdb --timeout=300s

primary=$(kubectl get pod \
  -l cnpg.io/cluster=documentdb,cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')

# 1) CASCADE pulled in the full stack: documentdb / pg_cron / postgis / vector
kubectl exec "$primary" -c postgres -- psql -U postgres -d postgres -tAqc \
  "select extname from pg_extension where extname in ('documentdb','postgis','pg_cron','vector') order by 1"

# 2) round-trip a document through the documentdb API
kubectl exec "$primary" -c postgres -- psql -U postgres -d postgres -tAqc \
  "select documentdb_api.insert_one('demo','things','{ \"_id\": 1, \"marker\": \"hello\" }')"
kubectl exec "$primary" -c postgres -- psql -U postgres -d postgres -tAqc \
  "set documentdb_core.bsonUseEJson to on;
   select document::text from documentdb_api.collection('demo','things')"
```

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

## Migrating an existing deployment

Moving an existing CNPG cluster off a FerretDB documentdb operand onto this
stack — including the uid 999 -> 26 and ICU -> 77 boundary — is written up
separately in [docs/migrating-from-ferretdb.md](docs/migrating-from-ferretdb.md).

## CI and publishing

`pull-request.yaml` builds and verifies every artifact on a pull request.
`main.yaml` does the same on push to `main` and then publishes multi-arch images:
a `git-<short_sha>` tag for each commit, and a release version when release-please
cuts a release. Both call the reusable `_build.yaml`. Published tags follow the
scheme above, e.g. `postgresql-fips:17.10-git-1a2b3c4` or `extension:pg18-1.2.0`.
Releases are driven by release-please from conventional commit messages, and a
`lint-title` workflow enforces a conventional pull-request title (squash merges use
it as the commit message release-please reads).

A weekly scheduled run builds and verifies without publishing, and a `base-drift`
job compares the pinned base digests against the live `fips:NN` tags and fails the
run if a tag has moved, as a prompt to re-pin.

## Pins

All reproducibility inputs - the documentdb source tag, ICU version, hardened
base digests, and which Postgres majors get engine vs. ImageVolume builds -
live in `versions.env`.

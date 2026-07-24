# documentdb-gateway source patches

Carried patches to the upstream `documentdb_gateway` Rust workspace
(`documentdb/documentdb`, the `pg_documentdb_gw` sub-tree). The gateway is compiled
from source for the FIPS image, so these apply in the builder stage before `cargo build`.

- Authored against `DOCUMENTDB_TAG=v0.114-0`.
- Apply from the `pg_documentdb_gw` workspace root (the directory holding `Cargo.toml`,
  `documentdb_gateway_core/`, `documentdb_macros/`, ...).

Upstream connects to a loopback-trusted Postgres with passwordless local-peer auth and
`NoTls`. Pointing it at a CloudNativePG cluster over the network needs SCRAM password auth
over TLS, so the patches add two out-of-band, file-based inputs and wire them through the
existing connection pools.

- `0001-build-gw-add-postgres-openssl-*` adds the `postgres-openssl` 0.5 dependency. It
  reuses the `openssl` 0.10 / `openssl-sys` 0.9 already in-tree, so no duplicate and no
  vendored OpenSSL, keeping the FIPS system-OpenSSL link.
- `0002-feat-gw-TLS-password-file-auth-*` is the credential + TLS wiring.
- `0003-fix-gw-recreate-reaped-data-pool-*` self-heals a pool-lifecycle defect: the
  gateway reaps per-user data pools left unused for 2h (`POSTGRES_POOL_DISPOSE_INTERVAL_SEC`),
  but an authenticated Mongo connection can stay open longer (idle timeout is larger), so a
  client that goes quiet then resumes hits `get_data_pool` after its pool was disposed and
  upstream returns "Connection pool missing for user." In file-password mode every user's
  data pool authenticates as the one `postgres_data_user`, so `get_data_pool` falls back to
  the lazily-(re)created shared service-account pool instead of erroring. Gated on file-password
  mode, so upstream (per-user role) behaviour is unchanged.

Both new inputs are file paths, read at startup:

- `DOCUMENTDB_PG_PASSWORD_FILE`: backend SCRAM password, read after the existing
  password-rejection guards so `PGPASSWORD`, in-URL passwords, and the JSON
  `PostgresDataUserPassword` field all stay rejected. A single trailing newline is
  trimmed. Populates both `postgres_data_user_password` and the new
  `postgres_system_user_password` field (the system/bootstrap pool authenticates as the
  separate `postgres_system_user` role and previously passed no password).
- `DOCUMENTDB_PG_TLS_CA_FILE`: CA PEM anchoring trust for the outbound Postgres TLS
  connection, distinct from the Mongo-facing listener CA (`CertificateOptions.ca_path`).
  When unset, the OpenSSL default trust store is used; peer verification is always
  enforced.

## Applying

From the `pg_documentdb_gw` workspace root, in order (`0001` → `0002` → `0003`):

```sh
git apply /path/to/build/gateway/patches/0001-*.patch \
          /path/to/build/gateway/patches/0002-*.patch \
          /path/to/build/gateway/patches/0003-*.patch
# or, to preserve authorship/history:
git am /path/to/build/gateway/patches/*.patch
```

The final tree compiles and `cargo test -p documentdb_gateway_core` passes.

These are temporary. Upstream has planned `*_FILE` credential indirection; once a tagged
release ships file-based password and backend TLS configuration, drop these and switch to
the upstream env keys. Re-verify on each `DOCUMENTDB_TAG` bump: a patch that fails to apply
means upstream moved the surrounding code or landed the feature.

# Migrating from a FerretDB documentdb operand

A worked sketch for moving an existing CloudNativePG cluster off FerretDB's
documentdb-augmented operand image (`ferretdb/postgres-documentdb`, Debian-based,
Postgres uid **999**, Debian ICU) and onto this repo's upstream-CNPG stack
(Debian trixie, uid **26**, ICU **76**), ending on a stock CNPG
`18.x-standard-trixie` base with the documentdb ImageVolume extension.

It uses the images this repo builds — the `postgresql-fips` engine images and
the `extension` ImageVolume (see
[Using it in a cluster](../README.md#using-it-in-a-cluster)) — as the migration
vehicle. This is a **sketch**: rehearse every step against a clone before doing
it in production.

## Two kinds of transition

The path has two mechanically different kinds of step, and they need different
handling:

- **Major-version bumps inside one vendor/uid/ICU regime** → CNPG declarative
  major upgrade: change the cluster's `imageName` to the higher-major tag and
  CNPG runs `pg_upgrade` in place. `pg_upgrade` needs the extension present in
  *both* the old and new image; the engine images carry documentdb inside, so it
  is found on both sides.
- **Crossing the FerretDB → CNPG-image boundary** changes the Postgres uid
  (999 → 26) and, unless the FerretDB image is already on trixie, the ICU major
  (→ 76) at once. You cannot do that as an in-place
  operand swap on one `Cluster`: PGDATA on the PVC is owned by uid 999 and
  Postgres refuses to start under uid 26 against a data directory it does not
  own, and CNPG's `postgresUID`/`postgresGID` are fixed at cluster creation.
  Cross it by streaming into a **new** cluster whose fresh PVC is created under
  uid 26.

## The chain

1. **FerretDB 16 → FerretDB 17** — a CNPG declarative major upgrade on FerretDB's
   own images (stays Debian / uid 999 / Debian ICU). Outside this repo's scope.
   This repo builds engine images for PG17 and PG18 only, so the chain enters at
   PG17; bring anything older up to 17 on its current image first, so the
   boundary crossing in step 2 is same-major.
2. **FerretDB 17 → `postgresql-fips:17.11` engine** — the boundary crossing
   (uid 999 → 26, ICU → 76). Do it as a **new** cluster cloned from the FerretDB
   17 cluster via `bootstrap.pg_basebackup` (configure the source under
   `externalClusters`):
   - The new cluster uses CNPG's default uid/gid **26** and provisions its own
     fresh PVC, so the data is written by uid 26 from the start — no chown.
   - `pg_basebackup` is a physical clone (same major 17, so the on-disk format is
     compatible across distros). It copies indexes built under the old ICU, so on
     the ICU-76 target their recorded collation version may be stale (check
     the FerretDB image's ICU major; if it is already 76 this is a no-op). After
     promotion, per database (`datallowconn` in `pg_database`):

     ```sql
     ALTER DATABASE "<db>" REFRESH COLLATION VERSION;
     REINDEX DATABASE "<db>";   -- rebuild collation-dependent indexes
     ```

   - Reconcile extension versions: FerretDB ships its own documentdb version,
     this engine ships `DOCUMENTDB_TAG`. If they differ, run
     `ALTER EXTENSION documentdb UPDATE;` (and likewise for `postgis`, `pg_cron`,
     `vector`).
   - Carry `shared_preload_libraries`, `cron.database_name`, and the loopback
     `trust` pg_hba onto the new cluster.
   - Cut the application over to the new cluster's service, then retire the
     FerretDB cluster.
   - Alternative: a logical `bootstrap.initdb.import` rebuilds schema + data fresh
     under ICU 76, sidestepping the REINDEX and any extension-ABI skew, at the
     cost of a full logical copy (more downtime for large data). Pick per data
     size / downtime budget.
3. **`postgresql-fips:17.11` → `postgresql-fips:18.6` engine** — a pure major
   bump, now entirely within CNPG trixie / uid 26 / ICU 76. CNPG declarative major
   upgrade: change `imageName` to the PG18 engine tag; CNPG runs `pg_upgrade`.
   documentdb is inside both engine images, so `pg_upgrade` finds it on both
   sides. No uid or ICU change — no chown, no collation reindex.
4. **`postgresql-fips:18.6` engine → stock CNPG `18.6-standard-trixie` + documentdb
   ImageVolume** — a same-major operand swap, same uid (26) and ICU (76). Change
   `imageName` to the stock CNPG base and add the `extensions:` ImageVolume block
   ([Path B](../README.md#path-b--imagevolume-extension-stock-base--mounted-extension-pg18-only)).
   CNPG does a rolling restart; documentdb now loads from the mounted extension
   image instead of being baked in. If the ImageVolume ships a different
   documentdb version than was baked in, run `ALTER EXTENSION documentdb UPDATE;`.
   No pg_upgrade, no chown, no reindex.

End state: stock CNPG `18.x-standard-trixie` with documentdb delivered as a versioned
ImageVolume you can bump independently of the engine.

## Cross-cutting checklist

- **uid/gid**: new clusters use CNPG's default 26/26 — don't set
  `postgresUID: 999`.
- **collations**: only the ICU crossing (step 2) needs REFRESH COLLATION VERSION
  + REINDEX; steps 3–4 stay on ICU 76.
- **extension versions**: reconcile documentdb / postgis / pg_cron / vector with
  `ALTER EXTENSION ... UPDATE` after any image whose version differs.
- **preload + pg_hba + cron.database_name**: carry these on every cluster in the
  chain.
- **backups / monitoring / DSNs**: the step-2 cutover is a new cluster with a new
  name and service — repoint backups, scrape configs, and application connection
  strings, or front it with a stable Service.

## Moving off the FIPS-based images (engine/imagevol 0.1.3 and earlier)

Releases up to engine/imagevol 0.1.3 were built on a vendor FIPS base: same
uid 26 and PGDATA layout, but ICU **77** and a newer glibc (2.43 vs trixie's
2.41). The current images are on the upstream CNPG trixie base with ICU **76**.
The uid is unchanged, so the existing PVCs can be reused by swapping
`imageName` in place (same major: a CNPG rolling minor update), but the ICU
major goes *down* a version, so check collations before and after.

- **Swap atomically on the ImageVolume path.** Change `imageName` *and* the
  `extensions[].image.reference` in the same spec update. An ICU-76 base with the
  old ICU-77 extension (or vice versa) cannot load `pg_documentdb_core`, and
  because it is in `shared_preload_libraries` Postgres will not start.
- **Rehearse on a clone first** (a `bootstrap.pg_basebackup` or backup-restore
  copy on the new image) and keep a fresh base backup before swapping.
- **Database collation / locale.** CNPG's default initdb locale is `C`, which
  does not depend on glibc or ICU. Check what you actually have:

  ```sql
  SELECT datname, datlocprovider, datcollate, datctype, datcollversion,
         pg_database_collation_actual_version(oid) AS actual
  FROM pg_database WHERE datallowconn;
  SELECT collname, collprovider, collversion, pg_collation_actual_version(oid) AS actual
  FROM pg_collation WHERE collversion IS DISTINCT FROM pg_collation_actual_version(oid);
  ```

  Any row whose recorded version differs from `actual` after the swap (or any
  non-`C` libc locale, or an `icu` provider) means collation-dependent indexes
  must be rebuilt: `REINDEX DATABASE "<db>";` then
  `ALTER DATABASE "<db>" REFRESH COLLATION VERSION;` (and
  `ALTER COLLATION ... REFRESH VERSION` for the listed collations).
- **documentdb collation-aware indexes.** documentdb computes ICU sort keys for
  collections/indexes created with a non-simple `collation`. Those keys were
  computed under ICU 77; reindex them under ICU 76 (`REINDEX DATABASE` covers
  them). Without collation options nothing ICU-dependent is stored.
- **Extension versions.** The documentdb version is unchanged by the base move;
  postgis / pg_cron / vector / rum come from the current PGDG trixie packages, so
  run `ALTER EXTENSION ... UPDATE` for any whose `\dx` version lags the
  available one.

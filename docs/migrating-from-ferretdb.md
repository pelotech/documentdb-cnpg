# Migrating from a FerretDB documentdb operand

A worked sketch for moving an existing CloudNativePG cluster off FerretDB's
documentdb-augmented operand image (`ferretdb/postgres-documentdb`, Debian-based,
Postgres uid **999**, Debian ICU) and onto this repo's hardened Minimus stack
(uid **26**, ICU **77**), ending on a stock `fips:18` base with the documentdb
ImageVolume extension.

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
- **Crossing the FerretDB → Minimus boundary** changes the Postgres uid
  (999 → 26) and the ICU major (→ 77) at once. You cannot do that as an in-place
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
2. **FerretDB 17 → `postgresql-fips:17.10` engine** — the boundary crossing
   (uid 999 → 26, ICU → 77). Do it as a **new** cluster cloned from the FerretDB
   17 cluster via `bootstrap.pg_basebackup` (configure the source under
   `externalClusters`):
   - The new cluster uses CNPG's default uid/gid **26** and provisions its own
     fresh PVC, so the data is written by uid 26 from the start — no chown.
   - `pg_basebackup` is a physical clone (same major 17, so the on-disk format is
     compatible across distros). It copies indexes built under the old ICU, so on
     the ICU-77 target their recorded collation version is stale. After
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
     under ICU 77, sidestepping the REINDEX and any extension-ABI skew, at the
     cost of a full logical copy (more downtime for large data). Pick per data
     size / downtime budget.
3. **`postgresql-fips:17.10` → `postgresql-fips:18.4` engine** — a pure major
   bump, now entirely within Minimus / uid 26 / ICU 77. CNPG declarative major
   upgrade: change `imageName` to the PG18 engine tag; CNPG runs `pg_upgrade`.
   documentdb is inside both engine images, so `pg_upgrade` finds it on both
   sides. No uid or ICU change — no chown, no collation reindex.
4. **`postgresql-fips:18.4` engine → stock `fips:18` + documentdb ImageVolume** —
   a same-major operand swap, same uid (26) and ICU (77). Change `imageName` to
   the stock hardened `fips:18` base and add the `extensions:` ImageVolume block
   ([Path B](../README.md#path-b--imagevolume-extension-stock-base--mounted-extension-pg18-only)).
   CNPG does a rolling restart; documentdb now loads from the mounted extension
   image instead of being baked in. If the ImageVolume ships a different
   documentdb version than was baked in, run `ALTER EXTENSION documentdb UPDATE;`.
   No pg_upgrade, no chown, no reindex.

End state: stock hardened `fips:18` with documentdb delivered as a versioned
ImageVolume you can bump independently of the engine.

## Cross-cutting checklist

- **uid/gid**: new Minimus clusters use CNPG's default 26/26 — don't set
  `postgresUID: 999`.
- **collations**: only the ICU crossing (step 2) needs REFRESH COLLATION VERSION
  + REINDEX; steps 3–4 stay on ICU 77.
- **extension versions**: reconcile documentdb / postgis / pg_cron / vector with
  `ALTER EXTENSION ... UPDATE` after any image whose version differs.
- **preload + pg_hba + cron.database_name**: carry these on every cluster in the
  chain.
- **backups / monitoring / DSNs**: the step-2 cutover is a new cluster with a new
  name and service — repoint backups, scrape configs, and application connection
  strings, or front it with a stable Service.

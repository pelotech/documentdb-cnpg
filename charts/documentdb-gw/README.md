# documentdb-gw

A Helm chart that stands up the [DocumentDB](https://github.com/documentdb/documentdb)
MongoDB-wire **gateway** in front of a [CloudNativePG](https://cloudnative-pg.io/)
cluster, and — optionally — the backing CNPG `ImageVolume` cluster itself.

The gateway (`documentdb-gw`) is a small Rust service that listens for MongoDB
clients on `:10260` and translates their requests into `documentdb_api` SQL
against Postgres. See the repo [README](../../README.md) for how the extension
and gateway are built.

## What it deploys

Always:

- a gateway `Deployment` (non-root uid 26, TCP probes on `:10260`),
- a `Service` (ClusterIP `:10260` by default),
- a listener-TLS secret/`Certificate` (see [Listener TLS](#listener-tls)).

Additionally, when `cluster.create=true` (the default):

- a CNPG `Cluster` running the stock hardened `fips:18` base with documentdb
  mounted as a declarative `ImageVolume` extension,
- a CNPG `managed.roles` entry provisioning the `gwuser` login role with
  membership in `documentdb_admin_role`,
- a chart-managed `kubernetes.io/basic-auth` `Secret` holding a generated
  password for that role (CNPG reconciles the role's password from it).

The chart supports two modes:

- **Create mode** (`cluster.create=true`, default): full bring-up — the chart
  owns the cluster, the gateway role, and its password.
- **Attach mode** (`cluster.create=false`): the gateway connects to a cluster
  you already run; you supply the backend host, user, password secret, and CA
  secret, and grant the role `documentdb_admin_role` yourself.

## Prerequisites

- **Helm v4.**
- **CloudNativePG operator >= 1.27** installed in the cluster.
- **Kubernetes >= 1.35 with the `ImageVolume` feature gate enabled** — only when
  `cluster.create=true`. Attach mode has no minimum-version requirement beyond
  what the existing cluster needs.

## Install — full bring-up (create mode)

`cluster.create` defaults to `true`, so a bare install provisions everything:

```bash
helm install documentdb-gw \
  oci://ghcr.io/pelotech/documentdb-cnpg/charts/documentdb-gw \
  --version 0.1.0
```

This creates the `Cluster/ddb-pg`, provisions the `gwuser` role (via CNPG
`managed.roles`) with `documentdb_admin_role` membership and a generated-password
Secret, and issues a self-signed listener certificate. No manual `GRANT` is
needed — CNPG reconciles the role membership.

The cluster's base image (`cluster.imageName`) defaults to the pinned hardened
`cloudnative-pg-postgresql-fips:18.4` digest and the extension
(`cluster.extensionImage`) to the matching published tag; override both for your
environment.

> **Multi-release caveat.** The `ImageVolume` `Cluster` is named by
> `cluster.name` (default `ddb-pg`), **not** by the release name. Two
> `cluster.create=true` releases in the same namespace with the default
> `cluster.name` collide on `Cluster/ddb-pg`. Either set a distinct
> `cluster.name` per release, or install additional releases with
> `cluster.create=false` to share one cluster.

## Install — attach mode

Point the gateway at a cluster you already run. You must supply the backend
connection details and password/CA secrets:

```bash
helm install documentdb-gw \
  oci://ghcr.io/pelotech/documentdb-cnpg/charts/documentdb-gw \
  --version 0.1.0 \
  --set cluster.create=false \
  --set gateway.pg.host=mycluster-rw \
  --set gateway.pg.user=gwuser \
  --set gateway.pg.existingSecret=mycluster-app \
  --set gateway.pg.caSecret=mycluster-ca
```

`gateway.pg.existingSecret` must have a `password` key; `gateway.pg.caSecret`
must have a `ca.crt` key (a CNPG-generated `<cluster>-app` / `<cluster>-ca` pair
satisfies both). The chart fails the render fast if any of
`gateway.pg.existingSecret` / `gateway.pg.caSecret` / (`gateway.pg.host` or a
non-default `cluster.name`) is unset in attach mode.

**Required grant (attach mode).** A plain CNPG `LOGIN` role cannot run the
`documentdb_api` functions. Before the gateway can serve traffic, grant the
backend role membership in the documentdb admin role, once, against the existing
cluster:

```sql
GRANT documentdb_admin_role TO "gwuser";
```

(Substitute your `gateway.pg.user` for `gwuser`.) In create mode the chart
does this for you via `managed.roles.inRoles`.

## Listener TLS

The Mongo-facing listener always serves TLS. `gateway.listenerTLS.mode` selects
how the certificate is provided:

| Mode          | Behavior                                                                                     | Required values |
| ------------- | -------------------------------------------------------------------------------------------- | --------------- |
| `generate`    | **Default.** Chart generates a self-signed cert (stable across upgrades via a `lookup`). Clients must pass `tlsAllowInvalidCertificates=true`. | — |
| `certManager` | Chart renders a cert-manager `Certificate`; cert-manager issues the secret.                  | `gateway.listenerTLS.certManager.issuerRef.name` |
| `existing`    | Chart authors nothing; you provide the TLS secret.                                           | `gateway.listenerTLS.existingSecret` |

Example, cert-manager:

```bash
--set gateway.listenerTLS.mode=certManager \
--set gateway.listenerTLS.certManager.issuerRef.name=my-issuer
```

## Connecting

Port-forward the Service and connect with `mongosh`. In create mode, read the
chart-generated password from the backend Secret first:

```bash
# create mode: read the generated gateway password
pw=$(kubectl get secret documentdb-gw-documentdb-gw-pg \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl port-forward svc/documentdb-gw-documentdb-gw 10260:10260

mongosh "mongodb://gwuser:${pw}@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true"
```

The Secret name is `<release>-documentdb-gw-pg` (here the release is
`documentdb-gw`). `tlsAllowInvalidCertificates=true` is required with the default
self-signed listener cert (`listenerTLS.mode=generate`).

## Values

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `ghcr.io/pelotech/documentdb-cnpg/documentdb-gw` | Gateway image repository. |
| `image.tag` | `""` | Gateway image tag; empty falls back to `.Chart.AppVersion` (`0.114.0-0.1.3`). |
| `image.pullPolicy` | `IfNotPresent` | Gateway image pull policy. |
| `gateway.replicas` | `2` | Gateway Deployment replica count. |
| `gateway.logLevel` | `info` | Gateway log level. |
| `gateway.service.type` | `ClusterIP` | Service type. |
| `gateway.service.port` | `10260` | Service port (the container always listens on `:10260`). |
| `gateway.resources` | requests `100m`/`128Mi`, limits `1`/`512Mi` | Gateway container resources. |
| `gateway.pg.host` | `""` | Backend Postgres host; empty resolves to `<cluster.name>-rw.<namespace>.svc`. |
| `gateway.pg.port` | `5432` | Backend Postgres port. |
| `gateway.pg.database` | `postgres` | Backend database. In create mode the chart installs documentdb in `postgres`; in attach mode set it to the database where documentdb is installed. |
| `gateway.pg.user` | `gwuser` | Backend login role. |
| `gateway.pg.existingSecret` | `""` | Attach mode: secret with a `password` key. Empty = chart-managed (create mode). |
| `gateway.pg.caSecret` | `""` | Backend CA secret (`ca.crt` key); empty resolves to `<cluster.name>-ca`. |
| `gateway.listenerTLS.mode` | `generate` | `generate` \| `certManager` \| `existing`. |
| `gateway.listenerTLS.existingSecret` | `""` | TLS secret name when `mode=existing`. |
| `gateway.listenerTLS.certManager.issuerRef` | `{}` | cert-manager issuer ref (`{name, kind, group}`) when `mode=certManager`. |
| `gateway.listenerTLS.certManager.duration` | `2160h` | Certificate duration. |
| `gateway.listenerTLS.certManager.dnsNames` | `[]` | Extra DNS names; defaults to the Service FQDN. |
| `networkPolicy.enabled` | `false` | Render a gateway NetworkPolicy. |
| `networkPolicy.clientNamespaceSelector` | `{}` | Ingress namespace selector for clients. |
| `cluster.create` | `true` | Create the CNPG ImageVolume cluster, gateway role, and password secret. |
| `cluster.name` | `ddb-pg` | Cluster name (not release-scoped — see the multi-release caveat). |
| `cluster.instances` | `1` | Cluster instance count. |
| `cluster.imageName` | pinned `cloudnative-pg-postgresql-fips:18.4@sha256:…` | Stock hardened base image (documentdb is mounted, not baked). |
| `cluster.extensionImage` | `ghcr.io/pelotech/documentdb-cnpg/extension:pg18-0.114.0-icu77-0.1.3` | documentdb ImageVolume extension. |
| `cluster.extensionPullPolicy` | `IfNotPresent` | Extension image pull policy. |
| `cluster.storage` | `1Gi` | Cluster storage size. |
| `cluster.enableSuperuserAccess` | `false` | CNPG superuser access. |

See [`values.yaml`](values.yaml) for the full, commented value surface.

## Pulling the chart

The chart is published to GHCR as an OCI artifact:

```bash
helm pull oci://ghcr.io/pelotech/documentdb-cnpg/charts/documentdb-gw --version 0.1.0
```

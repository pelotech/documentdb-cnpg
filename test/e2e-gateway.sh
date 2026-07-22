#!/usr/bin/env bash
# End-to-end test for documentdb-gw: brings up a CloudNativePG DocumentDB cluster and the
# gateway as a standalone Deployment, then drives a MongoDB insert+find round-trip through
# the gateway over TLS + SCRAM (mongosh -> gateway -> TLS/SCRAM -> Postgres -> documentdb).
# Exercises what unit tests and the build-time linkage check cannot: the image runs on the
# hardened base, backend TLS+SCRAM auth works over the network, and data round-trips.
#
# Usage:  [KIND_KEEP=1] ./test/e2e-gateway.sh
# Inputs (env, all have defaults):
#   ENGINE_IMAGE  documentdb-embedded engine image (a CNPG-runnable cluster image)
#   GW_IMAGE      the documentdb-gw image under test
#   KIND_KEEP=1   keep the ephemeral kind cluster on exit (default: delete)
set -euo pipefail
log(){ echo "[e2e-gateway] $*" >&2; }
fail(){ echo "[e2e-gateway] FAIL: $*" >&2; exit 1; }

KC=documentdb-gw-e2e
NS=documentdb-gw-e2e
CLUSTER=ddb-engine
ENGINE_IMAGE="${ENGINE_IMAGE:-ghcr.io/pelotech/documentdb-cnpg-extension:18.4-documentdb0.114-0-icu77}"
GW_IMAGE="${GW_IMAGE:-ghcr.io/pelotech/documentdb-cnpg/documentdb-gw:0.114.0-local}"
CNPG_MANIFEST="${CNPG_MANIFEST:-https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.1.yaml}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0}"
GW_PASS="${GW_PASS:-gwpass123}"

created_cluster=0
cleanup(){ local rc=$?
  if [ -n "${PF:-}" ]; then kill "$PF" 2>/dev/null || true; fi
  if [ "$created_cluster" = 1 ] && [ "${KIND_KEEP:-0}" != 1 ]; then
    kind delete cluster --name "$KC" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

# 1. ephemeral kind cluster + CNPG operator
if ! kind get clusters 2>/dev/null | grep -qx "$KC"; then
  log "creating ephemeral kind cluster $KC ($KIND_NODE_IMAGE)"
  kind create cluster --name "$KC" --image "$KIND_NODE_IMAGE" >/dev/null
  created_cluster=1
fi
kubectl config use-context "kind-$KC" >/dev/null
kubectl get deploy -n cnpg-system cnpg-controller-manager >/dev/null 2>&1 \
  || kubectl apply --server-side -f "$CNPG_MANIFEST" >/dev/null
kubectl wait --for=condition=Available deploy/cnpg-controller-manager -n cnpg-system --timeout=240s \
  || fail "CNPG operator did not become Available"

# 2. load images + bring up the DocumentDB cluster (with a gw service role)
log "loading images into kind"
kind load docker-image "$ENGINE_IMAGE" --name "$KC"
kind load docker-image "$GW_IMAGE" --name "$KC"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "applying DocumentDB cluster $CLUSTER (+ gwuser + documentdb_admin_role)"
cat <<EOF | kubectl apply -n "$NS" -f - >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: $CLUSTER }
spec:
  instances: 1
  imageName: $ENGINE_IMAGE
  imagePullPolicy: Never
  enableSuperuserAccess: true
  storage: { size: 1Gi }
  postgresql:
    shared_preload_libraries: [pg_cron, pg_documentdb_core, pg_documentdb]
    parameters: { cron.database_name: postgres }
    pg_hba:
      - host all all 127.0.0.1/32 trust
      - host all all ::1/128 trust
  bootstrap:
    initdb:
      database: postgres
      postInitSQL:
        - "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"
        - "CREATE ROLE gwuser WITH LOGIN PASSWORD '$GW_PASS'"
        - "GRANT documentdb_admin_role TO gwuser"
EOF
kubectl wait --for=condition=Ready "cluster/$CLUSTER" -n "$NS" --timeout=360s \
  || fail "cluster did not reach Ready"

# 3. deploy the gateway (standalone Deployment; pem listener TLS)
# Backend password (SCRAM to -rw) as a mounted secret; cluster CA for verify-full.
kubectl create secret generic gw-pg-secret -n "$NS" --from-literal=password="$GW_PASS" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Self-signed listener cert. LISTENER_TLS=auto can't work on the hardened base (its cert
# generator needs an openssl CLI the base lacks), so deploy in pem mode with a mounted cert.
workdir="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=documentdb-gw" \
  -keyout "$workdir/tls.key" -out "$workdir/tls.crt" >/dev/null 2>&1 \
  || fail "could not generate listener cert (need openssl on the runner)"
kubectl create secret tls gw-listener-tls -n "$NS" --cert="$workdir/tls.crt" --key="$workdir/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "deploying documentdb-gw"
cat <<EOF | kubectl apply -n "$NS" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: documentdb-gw, labels: { app.kubernetes.io/name: documentdb-gw } }
spec:
  replicas: 1
  selector: { matchLabels: { app.kubernetes.io/name: documentdb-gw } }
  template:
    metadata: { labels: { app.kubernetes.io/name: documentdb-gw } }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 26, runAsGroup: 26, fsGroup: 26 }
      containers:
        - name: documentdb-gw
          image: $GW_IMAGE
          imagePullPolicy: Never
          ports: [{ containerPort: 10260 }]
          env:
            - { name: PG_HOST, value: $CLUSTER-rw.$NS.svc }
            - { name: PG_USER, value: gwuser }
            - { name: PG_DATABASE, value: postgres }
            - { name: LISTENER_TLS, value: pem }
            - { name: TLS_CERT_FILE, value: /etc/documentdb/tls/tls.crt }
            - { name: TLS_KEY_FILE, value: /etc/documentdb/tls/tls.key }
            - { name: PG_PASSWORD_FILE, value: /etc/documentdb/pg/password }
            - { name: PG_TLS_CA_FILE, value: /etc/documentdb/pg/ca.crt }
          volumeMounts:
            - { name: pg-pass, mountPath: /etc/documentdb/pg/password, subPath: password, readOnly: true }
            - { name: pg-ca, mountPath: /etc/documentdb/pg/ca.crt, subPath: ca.crt, readOnly: true }
            - { name: listener-tls, mountPath: /etc/documentdb/tls, readOnly: true }
          readinessProbe: { tcpSocket: { port: 10260 }, initialDelaySeconds: 5, periodSeconds: 5 }
      volumes:
        - { name: pg-pass, secret: { secretName: gw-pg-secret } }
        - { name: pg-ca, secret: { secretName: $CLUSTER-ca } }
        - { name: listener-tls, secret: { secretName: gw-listener-tls } }
EOF
kubectl rollout status deploy/documentdb-gw -n "$NS" --timeout=150s \
  || { kubectl logs -n "$NS" -l app.kubernetes.io/name=documentdb-gw --tail=40 >&2; fail "gateway did not roll out"; }

# 4. mongosh round-trip through the gateway
log "mongosh round-trip over TLS+SCRAM"
kubectl port-forward -n "$NS" deploy/documentdb-gw 10260:10260 >/dev/null 2>&1 &
PF=$!; sleep 4
marker="gw-e2e-$(date +%s)"
out="$(mongosh "mongodb://gwuser:${GW_PASS}@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true" \
  --quiet --eval "
    const c = db.getSiblingDB('smoke').things;
    c.deleteMany({});   // idempotent across reruns on a reused cluster
    c.insertOne({_id: 1, marker: '$marker'});
    const got = c.findOne({_id: 1});
    print(got && got.marker === '$marker' ? 'ROUNDTRIP_OK' : 'ROUNDTRIP_FAIL:' + (got ? got.marker : 'null'));
  " 2>&1)" || fail "mongosh errored: $out"
echo "$out" | grep -q ROUNDTRIP_OK || fail "round-trip did not verify: $out"
log "PASS: MongoDB insert/find round-trip through documentdb-gw verified (marker=$marker)"

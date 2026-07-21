#!/usr/bin/env bash
# Runs a documentdb-embedded ENGINE image as a plain CNPG cluster (no ImageVolume)
# and asserts documentdb loads + round-trips. Exit status gates the publish step.
#
# Usage:  ENGINE_IMAGE=<built engine ref> [KIND_EPHEMERAL=1] ./test/verify-engine.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source versions.env
: "${ENGINE_IMAGE:?pass the built engine image ref, e.g. ENGINE_IMAGE=<repo>:<pgver>-documentdb...}"

NS=documentdb-engine-verify
CLUSTER=ddb-engine
KIND_CLUSTER="${KIND_CLUSTER:-ddb-ext-verify}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0}"
CNPG_MANIFEST="${CNPG_MANIFEST:-https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.1.yaml}"
KIND_EPHEMERAL="${KIND_EPHEMERAL:-0}"
created_cluster=0

log(){ printf '\n=== %s ===\n' "$*" >&2; }
fail(){ printf '\nFAIL: %s\n' "$*" >&2; exit 1; }
cleanup(){ local rc=$?; kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true;
  if [ "$created_cluster" = 1 ] && [ "${KIND_KEEP:-0}" != 1 ]; then kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true; fi; exit "$rc"; }
trap cleanup EXIT

if [ "$KIND_EPHEMERAL" = 1 ]; then
  if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    log "creating ephemeral kind cluster $KIND_CLUSTER"
    kind create cluster --name "$KIND_CLUSTER" --image "$KIND_NODE_IMAGE" --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  ImageVolume: true
EOF
    created_cluster=1
  fi
  kubectl config use-context "kind-${KIND_CLUSTER}" >/dev/null
fi

# CNPG operator ready
if ! kubectl get deploy -n cnpg-system cnpg-controller-manager >/dev/null 2>&1; then
  kubectl apply --server-side -f "$CNPG_MANIFEST"
fi
kubectl wait --for=condition=Available deploy/cnpg-controller-manager -n cnpg-system --timeout=180s || fail "CNPG operator not Available"

log "loading $ENGINE_IMAGE into kind"
kind load docker-image "$ENGINE_IMAGE" --name "$KIND_CLUSTER"

log "applying engine cluster in ns $NS"
kubectl delete ns "$NS" --ignore-not-found --wait=true --timeout=120s
kubectl create ns "$NS"
sed -e "s|__ENGINE_IMAGE__|${ENGINE_IMAGE}|g" test/engine-cluster.yaml | kubectl apply -n "$NS" -f -

log "waiting for cluster/$CLUSTER Ready (<=300s)"
if ! kubectl wait --for=condition=Ready "cluster/$CLUSTER" -n "$NS" --timeout=300s; then
  kubectl get pods -n "$NS" -o wide >&2 || true
  kubectl logs -n "$NS" -l "cnpg.io/cluster=$CLUSTER" --tail=60 --all-containers >&2 2>&1 || true
  fail "cluster did not become Ready"
fi

primary="$(kubectl get pod -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}')"
[ -n "$primary" ] || fail "no primary pod"
psql(){ kubectl exec -n "$NS" "$primary" -c postgres -- psql -U postgres -d postgres -tAqc "$1"; }

log "asserting extensions present"
got="$(psql "select extname from pg_extension where extname in ('documentdb','postgis','pg_cron','vector') order by 1" | tr -d '\r' | paste -sd' ' -)"
echo "  present: $got" >&2
[ "$got" = "documentdb pg_cron postgis vector" ] || fail "expected 'documentdb pg_cron postgis vector', got '$got'"

log "smoke round-trip"
marker="engine-ok-${DOCUMENTDB_TAG#v}"
psql "select documentdb_api.insert_one('smoke_db','things','{ \"_id\": 1, \"marker\": \"${marker}\" }')" >/dev/null
readback="$(psql "set documentdb_core.bsonUseEJson to on; select document::text from documentdb_api.collection('smoke_db','things')")"
echo "  read back: $readback" >&2
grep -q "$marker" <<<"$readback" || fail "round-trip: marker '$marker' not found"

log "PASS: engine cluster Ready, extensions present, documentdb round-trip equal"

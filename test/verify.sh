#!/usr/bin/env bash
# Self-contained acceptance gate. Brings up a CNPG cluster on the hardened base
# mounting the built extension image, then proves the extension loads:
# CREATE EXTENSION documentdb CASCADE succeeds (pulling in postgis + pg_cron +
# vector) and a smoke document round-trips. Green here is the publish condition.
#
# Usage:  EXT_IMAGE=<built ref> [KIND_EPHEMERAL=1] ./test/verify.sh
#
# Env:
#   EXT_IMAGE       (required) the built extension image ref to verify
#   KIND_EPHEMERAL  =1 to create/tear down a throwaway kind cluster
#   KIND_CLUSTER    kind cluster name              (default: ddb-ext-verify)
#   KIND_NODE_IMAGE kind node image, k8s >= 1.35   (default: kindest/node:v1.35.0)
#   CNPG_MANIFEST   CNPG operator install manifest (default: 1.27.1 release)
#   KIND_KEEP       =1 to keep the ephemeral cluster after the run (debug)
set -euo pipefail

cd "$(dirname "$0")/.."
source versions.env
: "${EXT_IMAGE:?pass the built image ref, e.g. EXT_IMAGE=<repo>:<tag>}"
: "${HARDENED_BASE:?versions.env must define HARDENED_BASE}"

NS=documentdb-ext-verify
CLUSTER=ddb-pg
KIND_CLUSTER="${KIND_CLUSTER:-ddb-ext-verify}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0}"
CNPG_MANIFEST="${CNPG_MANIFEST:-https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.1.yaml}"
KIND_EPHEMERAL="${KIND_EPHEMERAL:-0}"
created_cluster=0

log(){ printf '\n=== %s ===\n' "$*" >&2; }
fail(){ printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

cleanup(){
  local rc=$?
  kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [ "$created_cluster" = 1 ] && [ "${KIND_KEEP:-0}" != 1 ]; then
    log "tearing down ephemeral kind cluster $KIND_CLUSTER"
    kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

# 1. ensure a kind cluster (k8s >= 1.35 with the ImageVolume feature gate on) + CNPG
if [ "$KIND_EPHEMERAL" = 1 ]; then
  if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    log "creating ephemeral kind cluster $KIND_CLUSTER ($KIND_NODE_IMAGE)"
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

# 1a. gate on k8s >= 1.35 (CNPG declarative extensions mount via the ImageVolume feature)
kver="$(kubectl version -o json 2>/dev/null || true)"
kmaj="$(printf '%s' "$kver" | yq -r '.serverVersion.major // ""')"
kmin="$(printf '%s' "$kver" | yq -r '.serverVersion.minor // ""')"
kmin="${kmin//[^0-9]/}"
{ [ "$kmaj" = 1 ] && [ "${kmin:-0}" -ge 35 ]; } \
  || fail "kubernetes server is '${kmaj:-?}.${kmin:-?}'; this gate needs >= 1.35 (ImageVolume). Set KIND_EPHEMERAL=1 or point kubectl at a >=1.35 cluster."

# 1b. ensure CNPG operator (>= 1.27 for declarative extensions) is installed and ready
if ! kubectl get deploy -n cnpg-system cnpg-controller-manager >/dev/null 2>&1; then
  log "installing CNPG operator ($CNPG_MANIFEST)"
  kubectl apply --server-side -f "$CNPG_MANIFEST"
fi
kubectl wait --for=condition=Available deploy/cnpg-controller-manager -n cnpg-system --timeout=180s \
  || fail "CNPG operator did not become Available"

# 2. load the built extension image into the kind node (manifest sets pullPolicy: Never)
log "loading $EXT_IMAGE into kind cluster $KIND_CLUSTER"
kind load docker-image "$EXT_IMAGE" --name "$KIND_CLUSTER"

# 3. render and apply the cluster on the hardened base with the built image
log "applying CNPG cluster $CLUSTER in ns $NS"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f -
sed -e "s|__BASE__|${HARDENED_BASE}|g" -e "s|__EXT_IMAGE__|${EXT_IMAGE}|g" test/cluster.yaml \
  | kubectl apply -n "$NS" -f -

# 4. wait for the cluster to reach Ready (initdb runs postInitSQL: CREATE EXTENSION documentdb CASCADE)
log "waiting for cluster/$CLUSTER to be Ready (<=300s)"
if ! kubectl wait --for=condition=Ready "cluster/$CLUSTER" -n "$NS" --timeout=300s; then
  kubectl get pods -n "$NS" -o wide >&2 || true
  kubectl describe "cluster/$CLUSTER" -n "$NS" 2>&1 | tail -40 >&2 || true
  kubectl logs -n "$NS" -l "cnpg.io/cluster=$CLUSTER" --tail=60 --all-containers >&2 2>&1 || true
  fail "cluster did not become Ready"
fi

# psql into the primary as superuser
primary="$(kubectl get pod -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}')"
[ -n "$primary" ] || fail "could not find primary pod"
psql(){ kubectl exec -n "$NS" "$primary" -c postgres -- psql -U postgres -d postgres -tAqc "$1"; }

# 5. assert the expected extensions are present
log "asserting extensions present"
got="$(psql "select extname from pg_extension where extname in ('documentdb','postgis','pg_cron','vector') order by 1" \
  | tr -d '\r' | paste -sd' ' -)"
echo "  present: $got" >&2
[ "$got" = "documentdb pg_cron postgis vector" ] \
  || fail "expected 'documentdb pg_cron postgis vector', got '$got'"

# 6. smoke: insert one document through the documentdb API and read it back; assert equal
log "smoke round-trip through documentdb API"
marker="smoke-ok-${DOCUMENTDB_TAG#v}"
psql "select documentdb_api.insert_one('smoke_db','things', '{ \"_id\": 1, \"marker\": \"${marker}\" }')" >/dev/null
readback="$(psql "select bson_get_value_text(document, 'marker') from documentdb_api.collection('smoke_db','things') where bson_get_value_text(document,'_id')='1'" | tr -d '\r ')"
echo "  inserted marker=$marker  read back=$readback" >&2
[ "$readback" = "$marker" ] || fail "documentdb round-trip mismatch: wrote '$marker', read '$readback'"

log "PASS: cluster Ready, extensions present, documentdb round-trip equal"

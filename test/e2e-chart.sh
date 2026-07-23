#!/usr/bin/env bash
# Full ImageVolume-path e2e: helm install the documentdb-gw chart with cluster.create=true
# (CNPG ImageVolume cluster + managed gateway role + gateway Deployment), then drive a
# MongoDB insert+find round-trip through the gateway. Mirrors e2e-gateway.sh but exercises
# the chart and Path B instead of the baked-in engine image.
set -euo pipefail
log(){ echo "[e2e-chart] $*" >&2; }
fail(){ echo "[e2e-chart] FAIL: $*" >&2; exit 1; }
KC=documentdb-chart-e2e; NS=documentdb-chart-e2e; REL=ddbgw; CLUSTER=ddb-pg
EXT_IMAGE="${EXT_IMAGE:?set EXT_IMAGE (local extension image)}"
GW_IMAGE="${GW_IMAGE:?set GW_IMAGE (local gateway image)}"
BASE_IMAGE="${BASE_IMAGE:?set BASE_IMAGE (hardened base)}"
CNPG_MANIFEST="${CNPG_MANIFEST:-https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.1.yaml}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0}"
created=0
cleanup(){ local rc=$?
  if [ -n "${PF:-}" ]; then kill "$PF" 2>/dev/null || true; fi
  if [ "$created" = 1 ] && [ "${KIND_KEEP:-0}" != 1 ]; then
    kind delete cluster --name "$KC" >/dev/null 2>&1 || true
  fi
  exit "$rc"; }
trap cleanup EXIT
# 1. kind with the ImageVolume feature gate + CNPG
if ! kind get clusters 2>/dev/null | grep -qx "$KC"; then
  kind create cluster --name "$KC" --image "$KIND_NODE_IMAGE" --config - <<'EOF' >/dev/null
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates: { ImageVolume: true }
EOF
  created=1
fi
kubectl config use-context "kind-$KC" >/dev/null
kubectl get deploy -n cnpg-system cnpg-controller-manager >/dev/null 2>&1 || kubectl apply --server-side -f "$CNPG_MANIFEST" >/dev/null
kubectl wait --for=condition=Available deploy/cnpg-controller-manager -n cnpg-system --timeout=240s || fail "CNPG not available"
# 2. load images
kind load docker-image "$EXT_IMAGE" --name "$KC"
kind load docker-image "$GW_IMAGE" --name "$KC"
kind load docker-image "$BASE_IMAGE" --name "$KC" 2>/dev/null || true
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# 3. helm install: shipped enableSuperuserAccess default (false); local images; pullPolicy Never
helm install "$REL" charts/documentdb-gw -n "$NS" \
  --set image.repository="${GW_IMAGE%:*}" --set image.tag="${GW_IMAGE##*:}" --set image.pullPolicy=Never \
  --set cluster.create=true --set cluster.name="$CLUSTER" \
  --set cluster.imageName="$BASE_IMAGE" --set cluster.extensionImage="$EXT_IMAGE" --set cluster.extensionPullPolicy=Never \
  --set gateway.replicas=1 --set gateway.listenerTLS.mode=generate
kubectl wait --for=condition=Ready "cluster/$CLUSTER" -n "$NS" --timeout=360s \
  || { kubectl get pods -n "$NS" -o wide >&2; \
       kubectl describe "cluster/$CLUSTER" -n "$NS" 2>&1 | tail -40 >&2; \
       kubectl logs -n "$NS" -l "cnpg.io/cluster=$CLUSTER" --all-containers --tail=60 >&2 2>&1 || true; \
       fail "cluster not Ready"; }
kubectl rollout status deploy/"$REL"-documentdb-gw -n "$NS" --timeout=180s \
  || { kubectl logs -n "$NS" -l app.kubernetes.io/name=documentdb-gw --tail=40 >&2; fail "gateway did not roll out"; }
# 4. round-trip (read the chart-generated password)
pw="$(kubectl get secret -n "$NS" "$REL"-documentdb-gw-pg -o jsonpath='{.data.password}' | base64 -d)"
kubectl port-forward -n "$NS" deploy/"$REL"-documentdb-gw 10260:10260 >/dev/null 2>&1 & PF=$!; sleep 4
marker="chart-e2e-$(date +%s)"
out="$(mongosh "mongodb://gwuser:${pw}@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true" \
  --quiet --eval "const c=db.getSiblingDB('smoke').things; c.deleteMany({}); c.insertOne({_id:1,marker:'$marker'}); const g=c.findOne({_id:1}); print(g&&g.marker==='$marker'?'ROUNDTRIP_OK':'ROUNDTRIP_FAIL:'+(g?g.marker:'null'));" 2>&1)" || fail "mongosh: $out"
grep -q ROUNDTRIP_OK <<<"$out" || fail "round-trip: $out"
log "PASS: chart ImageVolume bring-up + MongoDB round-trip (marker=$marker)"

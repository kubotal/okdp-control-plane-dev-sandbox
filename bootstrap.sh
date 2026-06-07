#!/usr/bin/env bash
#
# OKDP sandbox — one-command bootstrap.
#
# Creates a local kind cluster, installs Flux + kubocd, then installs the
# whole OKDP sandbox (infrastructure + platform + in-cluster control plane)
# from the chart/ umbrella chart.
#
# Usage:
#   ./bootstrap.sh                 # create cluster + install everything
#   ./bootstrap.sh --no-cluster    # skip kind create (use current context)
#   CLUSTER_NAME=foo ./bootstrap.sh
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-okdp-dev}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$REPO_DIR/chart"
SKIP_CLUSTER=false
[[ "${1:-}" == "--no-cluster" ]] && SKIP_CLUSTER=true

KUBOCD_CTRL_VERSION="${KUBOCD_CTRL_VERSION:-= v0.3.1}"
PACKAGE_REPO="${PACKAGE_REPO:-quay.io/okdp/packages-dev}"

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

# ── 1. Cluster ────────────────────────────────────────────────
if [[ "$SKIP_CLUSTER" == "false" ]]; then
  say "Creating kind cluster '$CLUSTER_NAME'"
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 80
  - containerPort: 30443
    hostPort: 443
  - containerPort: 30053
    hostPort: 30053
    protocol: UDP
EOF
fi

# ── 2. Flux (CRDs + controllers used by kubocd) ───────────────
say "Installing FluxCD"
flux install

# ── 3. kubocd controller (installs the kubocd CRDs the umbrella needs) ──
say "Installing kubocd controller"
kubectl apply -f - <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: kubocd-controller
  namespace: flux-system
spec:
  interval: 1m
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    operation: copy
  url: oci://${PACKAGE_REPO}/kubocd-ctrl
  ref:
    semver: "${KUBOCD_CTRL_VERSION}"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kubocd-controller
  namespace: flux-system
spec:
  interval: 1m
  serviceAccountName: kustomize-controller
  targetNamespace: kubocd
  storageNamespace: flux-system
  releaseName: kubocd-ctrl
  timeout: 10m
  install:
    createNamespace: true
    remediation: { retries: 30, remediateLastFailure: true }
  upgrade:
    remediation: { retries: 30, remediateLastFailure: true }
  chartRef:
    kind: OCIRepository
    name: kubocd-controller
    namespace: flux-system
  values:
    image:
      repository: ${PACKAGE_REPO}/kubocd
      pullPolicy: IfNotPresent
    extraNamespaces:
      - name: kubocd-system
    config:
      clusterRoles: [storage]
      defaultContexts:
        - name: default
          namespace: kubocd-system
    controller:
      enabled: true
      replicaCount: 1
      logger: { mode: dev, level: info }
      metrics: { enabled: false, secured: false }
EOF

say "Waiting for kubocd CRDs to be established"
for crd in releases.kubocd.kubotal.io contexts.kubocd.kubotal.io; do
  until kubectl get crd "$crd" >/dev/null 2>&1; do sleep 3; done
  kubectl wait --for=condition=established --timeout=120s "crd/$crd"
done

# ── 4. Install the whole sandbox from the umbrella chart ──────
say "Installing OKDP sandbox (umbrella chart)"
kubectl create namespace okdp-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install okdp-sandbox "$CHART_DIR" --wait=false

# ── 5. Wait for everything to be READY ───────────────────────
say "Waiting for all Releases to become READY (this can take a few minutes)"
sleep 10
deadline=$(( $(date +%s) + 600 ))
while :; do
  notready=$(kubectl get release -A --no-headers 2>/dev/null | awk '$5!="READY"{c++} END{print c+0}')
  total=$(kubectl get release -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf '   %s/%s releases READY\n' "$(( total - notready ))" "$total"
  [[ "$notready" == "0" && "$total" -gt 0 ]] && break
  [[ "$(date +%s)" -gt "$deadline" ]] && { echo "Timeout waiting for releases"; kubectl get release -A; exit 1; }
  sleep 15
done

# ── 6. Done ──────────────────────────────────────────────────
SUFFIX=$(helm get values okdp-sandbox -a -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ingressSuffix","okdp.dev-sandbox"))' 2>/dev/null || echo okdp.dev-sandbox)
CONSOLE=$(helm get values okdp-sandbox -a -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("consoleHost","console"))' 2>/dev/null || echo console)
cat <<EOF

✅ OKDP sandbox is up.

   Console : https://${CONSOLE}.${SUFFIX}
   Login   : useradmin / password

   DNS (once): create /etc/resolver/${SUFFIX} with
     nameserver 127.0.0.1
     port 30053

   Trust the CA (once):
     kubectl get secret default-issuer -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > okdp-dev-ca.crt
     # then add okdp-dev-ca.crt to your system / browser trust store

EOF

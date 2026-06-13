# OKDP Dev Sandbox (Minimalist)

A minimalist development environment for OKDP (Open Kubernetes Data Platform).
This sandbox spins up a local Kubernetes (Kind) cluster with the essential components (Flux, Kubocd, Kubauth) needed to develop the platform's frontends and backends.

## 1. Prerequisites

*   [Docker](https://docs.docker.com/get-docker/) (Runtime)
*   [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker)
    *   *Tested with: `v0.27.0`*
*   [Kubectl](https://kubernetes.io/docs/tasks/tools/)
    *   *Tested with: `v1.32.2`*
*   [Flux CLI](https://fluxcd.io/flux/installation/)
    *   *Tested with: `v2.6.1`*
*   `kubocd` CLI (Optional, for building packages)

## 2. Quick Start

### A. Create the Cluster

1.  Create and start the cluster:

    ```bash
    cat <<EOF | kind create cluster --name okdp-dev --config=-
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
    ```

    To prevent the cluster from restarting automatically:

    ```bash
    docker update --restart=no okdp-dev-control-plane
    ```

### B. Install the Infrastructure (Flux & Kubocd)

1.  Install **FluxCD** (standalone mode):

    ```bash
    flux install
    ```

2.  Install **Kubocd** (Controller & CRDs):

    ```bash
    kubectl apply -f clusters/dev/flux/kubocd.yaml
    ```

3.  Apply the **Context** and the **Releases**:

    ```bash
    # Apply the context
    kubectl apply -f clusters/dev/default-context.yaml
    ```

    ```bash
    # Deploy the system dependencies (Ingress, Cert-Manager, DNS-Server, Vault, External Secrets)
    kubectl apply -f manifests/infrastructure
    #
    # Then wait for the system dependencies to become ready (includes coredns-patch for internal DNS resolution
    # and metrics-server, which powers `kubectl top` and the Resource usage panel in the Console)
    kubectl wait --for=jsonpath='{.status.phase}'=READY release/cert-manager release/ingress-nginx release/dns-server release/vault release/external-secrets release/coredns-patch release/metrics-server -n kubocd-system --timeout=240s
    ```

    ```bash
    # Create the okdp system namespace
    kubectl create namespace okdp-system
    ```

    ```bash
    # Deploy Kubauth
    kubectl apply -f manifests/platform/kubauth.yaml
    #
    # Then wait for Kubauth to become ready (Release & CRDs)
    kubectl wait --for=jsonpath='{.status.phase}'=READY release/kubauth -n okdp-system --timeout=120s
    kubectl wait --for=condition=established --timeout=60s crd/oidcclients.kubauth.kubotal.io
    ```

    ```bash
    # Deploy the Spark Operator (cluster-wide, watches every namespace)
    kubectl apply -f manifests/platform/spark-operator.yaml
    kubectl wait --for=jsonpath='{.status.phase}'=READY release/spark-operator -n okdp-system --timeout=180s
    ```

    ```bash
    # Create the OIDC clients
    kubectl apply -f manifests/platform/oidc-client.yaml
    kubectl apply -f manifests/platform/oidc-client-spark.yaml
    ```

### C. Initialize Identity (Admin User)

Once Kubauth is up, create the admin user and its group:

1.  Create the `useradmin` user and the `admins` group:

    ```bash
    kubectl apply -f manifests/platform/user-admin.yaml
    ```

2.  **Default credentials:**

    *   **User**: `useradmin`
    *   **Password**: `password`

    > ⚠️ **Note:** The password is hashed in the manifest (`passwordHash`).

## 3. Local Access

The cluster exposes the Ingress Controller on host ports `80` and `443` (mapped from the Kind container's NodePorts `30080` and `30443`).

### DNS Configuration


The cluster exposes a development DNS server on NodePort `30053` (UDP).

To configure your local resolver (recommended so you don't have to touch `/etc/hosts`), follow the guide:

👉 **[See the DNS documentation](./docs/dns-configuration.md)**

### SSL Certificates

To avoid security warnings (and the blocking errors in the UI), you can trust the sandbox's certificate authority.

**Option 1: Install the CA certificate (Recommended)**

Fetch the CA certificate and add it to your system or browser trust store:

```bash
kubectl get secret default-issuer -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > okdp-dev-ca.crt
```

**Option 2: Ignore the warnings**
Open `https://kubauth.okdp.dev-sandbox` manually and accept the risk (required if you skip the certificate install).

### Vault (Secrets Management)

Vault ships with an Ingress and is available at:

*   **URL**: `https://vault.okdp.dev-sandbox`
*   **Mode**: Dev (default root token)

## 4. Control Plane (server + console)

The backend and the console run **in-cluster**, deployed from the images published by
CI with their Helm charts (`chart/` in each repo). Clone each repo, then deploy its chart:

*   **Backend (`okdp-control-plane-server`)** — from the repo root:

    ```bash
    helm install okdp-server ./chart -n okdp-system \
      --set image.repository=quay.io/kubotal/images/okdp-server --set image.tag=0.1.0
    ```

*   **Console (`okdp-control-plane-ui`)** — from the repo root (nginx serves the build and proxies `/api`, exposed via ingress):

    ```bash
    helm install okdp-ui ./chart -n okdp-system \
      --set image.repository=quay.io/kubotal/images/okdp-ui --set image.tag=0.1.0 \
      --set ingress.host=console.okdp.dev-sandbox
    ```

Console: `https://console.okdp.dev-sandbox` — login `useradmin` / `password` (created in step 2.C).

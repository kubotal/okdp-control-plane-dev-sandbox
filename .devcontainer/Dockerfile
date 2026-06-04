# syntax=docker/dockerfile:1
#
# Devcontainer image for okdp-control-plane-dev-sandbox.
# The sandbox spins up a local Kind cluster, so — like kubocd — it needs Docker
# (provided by the docker-in-docker feature) and runs as root.
#
# Tool integrity is verified at build time:
#   - kubectl : upstream .sha256
#   - flux    : release checksums.txt
#   - kind    : built via `go install` (Go module checksum database)
# Versions match those the sandbox README is tested against.

FROM golang:1.25-bookworm

ARG KUBECTL_VERSION=v1.32.2
ARG KIND_VERSION=v0.27.0
ARG FLUX_VERSION=2.6.1

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git make jq procps \
    && rm -rf /var/lib/apt/lists/*

# --- kubectl (verified against upstream .sha256) ---------------------------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"; \
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl.sha256"; \
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -; \
    install -m 0755 kubectl /usr/local/bin/kubectl; \
    rm kubectl kubectl.sha256; \
    kubectl version --client

# --- Flux CLI (verified against release checksums.txt) ---------------------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    base="https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}"; \
    tarball="flux_${FLUX_VERSION}_linux_${arch}.tar.gz"; \
    curl -fsSLO "${base}/${tarball}"; \
    curl -fsSLO "${base}/flux_${FLUX_VERSION}_checksums.txt"; \
    grep " ${tarball}\$" "flux_${FLUX_VERSION}_checksums.txt" | sha256sum -c -; \
    tar -xzf "${tarball}" flux; \
    install -m 0755 flux /usr/local/bin/flux; \
    rm flux "${tarball}" "flux_${FLUX_VERSION}_checksums.txt"; \
    flux --version

# --- Kind (built via Go module checksum database) --------------------------
RUN GOBIN=/usr/local/bin go install "sigs.k8s.io/kind@${KIND_VERSION}" \
    && kind --version

WORKDIR /workspaces/okdp-control-plane-dev-sandbox

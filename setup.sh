#!/usr/bin/env bash
# Bootstrap a local kind cluster, install Crossplane v1.20.7, apply all
# upgrade-check test fixtures, and enable the alpha feature flag that the
# feature-flags check looks for. Idempotent — safe to rerun.
#
# Prerequisites: kind, kubectl, helm.
#
# Usage:
#   ./setup.sh
#
# Overrides (env vars):
#   CLUSTER_NAME        Name of the kind cluster (default: crossplane-upgrade-check)
#   CROSSPLANE_VERSION  Crossplane chart version, no "v" prefix (default: 1.20.7)
#
# After this completes, run:
#   crossplane beta upgrade check
#
# To tear down the test cluster:
#   kind delete cluster --name <CLUSTER_NAME>
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-crossplane-upgrade-check}"
CROSSPLANE_VERSION="${CROSSPLANE_VERSION:-1.20.7}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required tool '$1' not found in PATH." >&2
        exit 1
    fi
}

require kind
require kubectl
require helm

echo "==> Ensuring kind cluster '$CLUSTER_NAME' exists..."
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "    Cluster '$CLUSTER_NAME' already exists; reusing it."
else
    kind create cluster --name "$CLUSTER_NAME"
fi

kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

echo "==> Waiting for cluster nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "==> Installing Crossplane v${CROSSPLANE_VERSION} via Helm..."
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace \
    --version "$CROSSPLANE_VERSION" \
    --wait --timeout 5m

echo "==> Verifying Crossplane deployment..."
kubectl wait --for=condition=Available --timeout=120s deployment/crossplane -n crossplane-system
INSTALLED_IMAGE=$(kubectl get deployment crossplane -n crossplane-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "    Crossplane image: $INSTALLED_IMAGE"
EXPECTED_TAG="v${CROSSPLANE_VERSION}"
if [[ "$INSTALLED_IMAGE" != *":${EXPECTED_TAG}" ]]; then
    echo "ERROR: expected Crossplane image tag '${EXPECTED_TAG}', got '$INSTALLED_IMAGE'." >&2
    exit 1
fi

echo "==> Applying provider-nop..."
kubectl apply -f "$DIR/00-setup.yaml"

echo "==> Waiting for provider-nop to install (timeout 120s)..."
kubectl wait --for=condition=Healthy --timeout=120s provider/provider-nop || {
    echo "WARN: provider-nop did not become Healthy in time. Continuing anyway —"
    echo "      the upgrade-check tool only reads spec, not status."
}

# XRDs and their XR/Claim instances live in the same file; kubectl apply can't
# create instances before the XRD-generated CRDs are established. The first
# pass tolerates failures on tests 03 and 04, then the second pass after a
# brief wait creates the XR/Claim instances.
echo "==> Applying check fixtures (first pass; XR/Claim instances may fail)..."
kubectl apply -f "$DIR/01-native-patch-and-transform.yaml"
kubectl apply -f "$DIR/02-controller-config.yaml"
kubectl apply -f "$DIR/03-external-secret-stores.yaml" || true
kubectl apply -f "$DIR/04-composite-connection-details.yaml" || true
kubectl apply -f "$DIR/05-unqualified-package-sources.yaml"

echo "==> Waiting 15s for XRD-generated CRDs to be established..."
sleep 15

echo "==> Applying XR/Claim instances (second pass)..."
kubectl apply -f "$DIR/03-external-secret-stores.yaml"
kubectl apply -f "$DIR/04-composite-connection-details.yaml"

echo "==> Patching Crossplane Deployment to enable removed alpha feature flag..."
"$DIR/06-patch-feature-flags.sh"

# Verify the fixtures landed in a healthy state. Each wait is best-effort —
# a timeout warns but doesn't abort, since the upgrade-check tool only reads
# spec and works fine even if some resources haven't fully reconciled.
verify_condition() {
    local description="$1"; shift
    local condition="$1"; shift
    local kind="$1"; shift
    # Remaining args are passed through to kubectl wait (e.g. -n default).

    echo "==> Waiting for $description ($condition)..."
    if kubectl wait --for=condition="$condition" --timeout=180s "$kind" --all "$@" 2>&1 \
        | sed 's/^/    /'; then
        :
    else
        echo "    WARN: not all $kind reached $condition within 180s."
    fi
}

verify_condition "Providers Healthy"       Healthy     providers
verify_condition "Functions Healthy"       Healthy     functions
verify_condition "XRDs Established"        Established compositeresourcedefinitions

# XRs derived from Claims (and ClusterNopResources composed from XRs) are
# created asynchronously by Crossplane's controllers. Give them a moment so
# the wait commands below have something to wait on.
echo "==> Letting XR/Claim controllers reconcile..."
sleep 15

verify_condition "External-secret-stores XRs Synced"   Synced xextsecretstores.upgradetest.crossplane.io
verify_condition "Composite-connection-details XRs Synced" Synced xconndetails.upgradetest.crossplane.io
verify_condition "External-secret-stores Claims Synced"    Synced extsecretstores.upgradetest.crossplane.io -n default
verify_condition "Composite-connection-details Claims Synced" Synced conndetails.upgradetest.crossplane.io -n default
verify_condition "Composed NopResources Synced" Synced nopresources.nop.crossplane.io

echo
echo "Setup complete. Run the checker against this cluster:"
echo "  crossplane beta upgrade check"
echo
echo "To tear down the test cluster:"
echo "  kind delete cluster --name $CLUSTER_NAME"

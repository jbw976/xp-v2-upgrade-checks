#!/usr/bin/env bash
# Bootstrap a kind cluster, install Crossplane v1, apply the upgrade-check
# fixtures, and enable the alpha feature flag. Idempotent.
#
# Overrides: CLUSTER_NAME (default crossplane-upgrade-check),
#            CROSSPLANE_VERSION (default 1.20.7, no "v" prefix).
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

# Files 03 and 04 contain both an XRD and instances of it. kubectl apply can't
# create the instances before the XRD's derived CRD is established, so we
# apply twice with an XRD-Established wait in between.
echo "==> Applying check fixtures (first pass; XR/Claim instances may fail)..."
kubectl apply -f "$DIR/01-native-patch-and-transform.yaml"
kubectl apply -f "$DIR/02-controller-config.yaml"
kubectl apply -f "$DIR/03-external-secret-stores.yaml" || true
kubectl apply -f "$DIR/04-composite-connection-details.yaml" || true
kubectl apply -f "$DIR/05-unqualified-package-sources.yaml"

echo "==> Waiting for XRDs to become Established (derived CRDs registered)..."
kubectl wait --for=condition=Established compositeresourcedefinitions --all --timeout=60s

echo "==> Applying XR/Claim instances (second pass)..."
kubectl apply -f "$DIR/03-external-secret-stores.yaml"
kubectl apply -f "$DIR/04-composite-connection-details.yaml"

echo "==> Patching Crossplane Deployment to enable removed alpha feature flag..."
"$DIR/06-patch-feature-flags.sh"

# Best-effort verification: a timeout warns but doesn't abort. The checker
# only reads spec, so unreconciled resources don't break it.
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

# Cascade Claim -> XR to dodge the kubectl-wait-zero-matches race: waiting
# on Claims first ensures the Claim-derived XRs exist by the time the XR
# --all wait runs.
#
# Composed NopResources are intentionally skipped: the ESS fixture's MRs
# stay Synced=False by design (see 03-external-secret-stores.yaml).
verify_condition "External-secret-stores Claims Synced"    Synced extsecretstores.upgradetest.crossplane.io -n default
verify_condition "Composite-connection-details Claims Synced" Synced conndetails.upgradetest.crossplane.io -n default
verify_condition "External-secret-stores XRs Synced"       Synced xextsecretstores.upgradetest.crossplane.io
verify_condition "Composite-connection-details XRs Synced" Synced xconndetails.upgradetest.crossplane.io

echo
echo "Setup complete. Run the checker against this cluster:"
echo "  crossplane beta upgrade check"
echo
echo "To tear down the test cluster:"
echo "  kind delete cluster --name $CLUSTER_NAME"

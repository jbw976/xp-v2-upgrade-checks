#!/usr/bin/env bash
# Patch the Crossplane Deployment to enable an alpha feature flag whose
# functionality is removed in v2. The external-secret-stores check flags the
# --enable-external-secret-stores flag on the Crossplane Deployment.
#
# To revert:
#   kubectl -n "${NAMESPACE:-crossplane-system}" rollout undo deployment/"${DEPLOYMENT:-crossplane}"
set -euo pipefail

NAMESPACE="${NAMESPACE:-crossplane-system}"
DEPLOYMENT="${DEPLOYMENT:-crossplane}"

if ! kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null 2>&1; then
    echo "ERROR: deployment/$DEPLOYMENT not found in namespace $NAMESPACE." >&2
    echo "       Override with NAMESPACE=... DEPLOYMENT=... $0" >&2
    exit 1
fi

if kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--enable-external-secret-stores'; then
    echo "Flag --enable-external-secret-stores already present on $NAMESPACE/$DEPLOYMENT."
    exit 0
fi

kubectl -n "$NAMESPACE" patch deployment "$DEPLOYMENT" --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--enable-external-secret-stores"
  }
]'

echo "Patched $NAMESPACE/$DEPLOYMENT to enable --enable-external-secret-stores."
echo "Wait a few seconds for the rollout to complete, then run:"
echo "  crossplane beta upgrade check"

#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "=== Refreshing OSAC after snapshot boot ==="
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

echo "[1/8] Patching stale routes with new domain..."
OLD_DOMAIN=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null | sed "s/^osac-aap-${INSTALLER_NAMESPACE}\.//")
echo "  Old domain: ${OLD_DOMAIN}"
echo "  New domain: ${CLUSTER_DOMAIN}"
for route in $(oc get routes -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
    OLD_HOST=$(oc get route "${route}" -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
    NEW_HOST=$(echo "${OLD_HOST}" | sed "s/${OLD_DOMAIN}/${CLUSTER_DOMAIN}/")
    oc patch route "${route}" -n "${INSTALLER_NAMESPACE}" --type=merge -p "{\"spec\":{\"host\":\"${NEW_HOST}\"}}"
done

echo "[2/8] Applying kustomize overlay..."
oc delete job -n "${INSTALLER_NAMESPACE}" --all --ignore-not-found
oc apply -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}"

echo "[3/8] Applying AAP configuration..."
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
    ./scripts/aap-configuration.sh

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

echo "[4/8] Waiting for AAP controller..."
retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
    echo "Timed out waiting for AAP controller to be Running"
    exit 1
}
AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
retry_until 120 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
    echo "Timed out waiting for AAP gateway API to respond"
    exit 1
}

echo "[5/8] Configuring AAP access..."
./scripts/prepare-aap.sh

echo "[6/8] Configuring fulfillment service..."
./scripts/prepare-fulfillment-service.sh

echo "[7/8] Restarting fulfillment pods..."
oc rollout restart deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-grpc-server -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-rest-gateway -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}"
oc rollout status deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-grpc-server -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-rest-gateway -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}" --timeout=120s

echo "[8/8] Configuring tenant..."
./scripts/prepare-tenant.sh

echo ""
echo "=== Refresh complete ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Namespace: ${INSTALLER_NAMESPACE}"

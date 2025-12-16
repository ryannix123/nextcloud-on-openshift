#!/bin/bash
# =============================================================================
# Nextcloud Deployment Script for Red Hat Developer Sandbox
# Uses Helm chart with OpenShift-compatible values
# =============================================================================
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check prerequisites
command -v oc >/dev/null 2>&1 || error "oc CLI not found. Install it from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
command -v helm >/dev/null 2>&1 || error "Helm not found. Install it from https://helm.sh/docs/intro/install/"

# Get current namespace
NAMESPACE=$(oc project -q 2>/dev/null) || error "Not logged into OpenShift. Run: oc login"
log "Using namespace: ${NAMESPACE}"

# Detect cluster domain for route
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "apps.example.com")
NEXTCLOUD_HOST="nextcloud-${NAMESPACE}.${CLUSTER_DOMAIN}"
log "Nextcloud will be available at: https://${NEXTCLOUD_HOST}"

# Generate passwords
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
REDIS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

# Add Helm repo
log "Adding Nextcloud Helm repository..."
helm repo add nextcloud https://nextcloud.github.io/helm/ 2>/dev/null || true
helm repo update

# Check if values file exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/openshift-values.yaml"
if [ ! -f "$VALUES_FILE" ]; then
    error "openshift-values.yaml not found in ${SCRIPT_DIR}"
fi

# Deploy Nextcloud
log "Deploying Nextcloud via Helm..."
helm upgrade --install nextcloud nextcloud/nextcloud \
    -f "$VALUES_FILE" \
    --set nextcloud.host="${NEXTCLOUD_HOST}" \
    --set nextcloud.password="${ADMIN_PASS}" \
    --set externalDatabase.password="${DB_PASS}" \
    --set mariadb.auth.rootPassword="${DB_PASS}" \
    --set mariadb.auth.password="${DB_PASS}" \
    --set redis.auth.password="${REDIS_PASS}" \
    --timeout 10m \
    --wait

# Create OpenShift Route
log "Creating OpenShift Route..."
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: nextcloud
  annotations:
    haproxy.router.openshift.io/timeout: 3600s
spec:
  host: ${NEXTCLOUD_HOST}
  to:
    kind: Service
    name: nextcloud
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Wait for pods to be ready
log "Waiting for pods to be ready..."
oc wait --for=condition=ready pod -l app.kubernetes.io/name=nextcloud --timeout=300s || warn "Pods taking longer than expected..."

# Fix health probe ports (Helm chart defaults to wrong port)
log "Patching health probe ports..."
oc patch deploy nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/readinessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/livenessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/startupProbe/httpGet/port", "value": 8080}
]' 2>/dev/null || warn "Could not patch probes (may already be correct)"

# Wait for rollout
oc rollout status deploy/nextcloud --timeout=300s || true

# Configure trusted domains
log "Configuring trusted domains..."
sleep 10  # Wait for pod to stabilize
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 0 --value="localhost" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 1 --value="${NEXTCLOUD_HOST}" 2>/dev/null || true

# Disable permission check (false positive on OpenShift)
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set check_data_directory_permissions --value="false" --type=boolean 2>/dev/null || true

# Print success message
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  Nextcloud Deployment Complete!${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo -e "URL:      ${BLUE}https://${NEXTCLOUD_HOST}${NC}"
echo ""
echo -e "Admin credentials:"
echo -e "  Username: ${BLUE}admin${NC}"
echo -e "  Password: ${BLUE}${ADMIN_PASS}${NC}"
echo ""
echo -e "${YELLOW}Save these credentials - they won't be shown again!${NC}"
echo ""
echo "Useful commands:"
echo "  oc logs deploy/nextcloud -c nextcloud     # View Nextcloud logs"
echo "  oc logs deploy/nextcloud -c nextcloud-nginx  # View nginx logs"
echo "  oc exec deploy/nextcloud -c nextcloud -- php occ status  # Check status"
echo ""

# Verify SCC
SCC=$(oc get pod -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}' 2>/dev/null || echo "unknown")
if [[ "$SCC" == "restricted"* ]]; then
    echo -e "${GREEN}✓ Running under restricted SCC (no elevated privileges)${NC}"
else
    echo -e "${YELLOW}⚠ Running under SCC: ${SCC}${NC}"
fi

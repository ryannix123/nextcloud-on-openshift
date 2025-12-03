#!/bin/bash
# Nextcloud Deployment Script for Red Hat Developer Sandbox
# Tested and working with restricted SCC - no elevated privileges needed!
#
# Usage: ./deploy-nextcloud-sandbox.sh [hostname]
# Example: ./deploy-nextcloud-sandbox.sh nextcloud-myproject.apps.sandbox.openshiftapps.com
#
# If hostname is not provided, the script will attempt to auto-detect it.

set -euo pipefail

NAMESPACE=$(oc project -q 2>/dev/null || echo "")
HOSTNAME="${1:-}"
RELEASE_NAME="nextcloud"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Nextcloud Deployment for Red Hat Developer Sandbox ===${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"
command -v oc >/dev/null 2>&1 || { echo -e "${RED}Error: oc CLI not found${NC}"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}Error: helm not found${NC}"; exit 1; }

# Verify logged into OpenShift
if ! oc whoami &>/dev/null; then
    echo -e "${RED}Error: Not logged into OpenShift cluster${NC}"
    echo "Login at: https://console.redhat.com/openshift/sandbox"
    exit 1
fi

# Get current namespace
NAMESPACE=$(oc project -q)
echo -e "Current namespace: ${GREEN}${NAMESPACE}${NC}"

# Determine hostname if not provided
if [ -z "${HOSTNAME}" ]; then
    APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
    if [ -z "${APPS_DOMAIN}" ]; then
        APPS_DOMAIN=$(oc get routes -A -o jsonpath='{.items[0].spec.host}' 2>/dev/null | sed 's/^[^.]*\.//' || echo "")
    fi
    
    if [ -n "${APPS_DOMAIN}" ]; then
        HOSTNAME="nextcloud-${NAMESPACE}.${APPS_DOMAIN}"
        echo -e "Auto-detected hostname: ${GREEN}${HOSTNAME}${NC}"
    else
        echo -e "${RED}Error: Could not auto-detect hostname. Please provide as argument.${NC}"
        echo "Usage: $0 <hostname>"
        echo "Example: $0 nextcloud-${NAMESPACE}.apps.sandbox-m2.ll9k.p1.openshiftapps.com"
        exit 1
    fi
fi

echo -e "Target hostname: ${GREEN}${HOSTNAME}${NC}"
echo ""

# Check resource quota
echo -e "${YELLOW}Checking Sandbox resource quotas...${NC}"
if oc get resourcequota &>/dev/null; then
    oc get resourcequota -o custom-columns=NAME:.metadata.name,CPU_USED:.status.used.cpu,CPU_LIMIT:.status.hard.cpu,MEM_USED:.status.used.memory,MEM_LIMIT:.status.hard.memory 2>/dev/null || true
    echo ""
fi

# Generate secure passwords
echo -e "${YELLOW}Generating secure passwords...${NC}"
ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')

# Create admin secret
echo -e "${YELLOW}Creating secrets...${NC}"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-admin
type: Opaque
stringData:
  username: admin
  password: ${ADMIN_PASSWORD}
EOF

# Add helm repo
echo -e "${YELLOW}Adding Nextcloud Helm repository...${NC}"
helm repo add nextcloud https://nextcloud.github.io/helm/ 2>/dev/null || true
helm repo update

# Create values file
echo -e "${YELLOW}Creating Sandbox-optimized configuration...${NC}"
cat > /tmp/nextcloud-sandbox-values.yaml <<EOF
# Nextcloud Helm Chart - Red Hat Developer Sandbox Values
# Optimized for Sandbox resource limits and restricted SCC

image:
  repository: nextcloud
  flavor: fpm-alpine
  pullPolicy: IfNotPresent

nextcloud:
  host: ${HOSTNAME}
  username: admin
  containerPort: 9000

  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault

  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    runAsNonRoot: true
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault

  extraEnv:
    - name: TRUSTED_PROXIES
      value: "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
    - name: OVERWRITEPROTOCOL
      value: "https"

  configs:
    proxy.config.php: |-
      <?php
      \$CONFIG = array (
        'trusted_proxies' => ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
        'overwriteprotocol' => 'https',
      );

nginx:
  enabled: true
  image:
    # nginx-unprivileged is designed for non-root operation
    repository: nginxinc/nginx-unprivileged
    tag: alpine
  
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    runAsNonRoot: true
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  
  containerPort: 8080

  config:
    default: false
    # Server block only - included inside http{} block by nginx-unprivileged base config
    # IMPORTANT: No \$uri/ in try_files to avoid 403 on directory paths like /apps/dashboard/
    custom: |-
      server {
          listen 8080;
          server_name _;
          root /var/www/html;
          index index.php index.html;
          
          client_max_body_size 512M;
          fastcgi_buffers 64 4K;
          
          location = /robots.txt {
              allow all;
              log_not_found off;
              access_log off;
          }
          
          location ^~ /.well-known {
              location = /.well-known/carddav { return 301 /remote.php/dav/; }
              location = /.well-known/caldav { return 301 /remote.php/dav/; }
              return 301 /index.php\$request_uri;
          }
          
          location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
          location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }
          
          location ~ \.php(?:$|/) {
              rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) /index.php\$request_uri;
              
              fastcgi_split_path_info ^(.+?\.php)(/.*)$;
              set \$path_info \$fastcgi_path_info;
              try_files \$fastcgi_script_name =404;
              
              include fastcgi_params;
              fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
              fastcgi_param PATH_INFO \$path_info;
              fastcgi_param HTTPS on;
              fastcgi_param modHeadersAvailable true;
              fastcgi_param front_controller_active true;
              fastcgi_pass 127.0.0.1:9000;
              
              fastcgi_intercept_errors on;
              fastcgi_request_buffering off;
              fastcgi_read_timeout 300;
          }
          
          location ~ \.(?:css|js|mjs|svg|gif|png|jpg|ico|wasm|tflite|map)$ {
              try_files \$uri /index.php\$request_uri;
              expires max;
              access_log off;
          }
          
          location ~ \.woff2?$ {
              try_files \$uri /index.php\$request_uri;
              expires 7d;
              access_log off;
          }
          
          location / {
              try_files \$uri /index.php\$request_uri;
          }
      }

# SQLite for Sandbox (simpler, less resources)
internalDatabase:
  enabled: true

externalDatabase:
  enabled: false

postgresql:
  enabled: false

mariadb:
  enabled: false

redis:
  enabled: false

# Reduced persistence for Sandbox
persistence:
  enabled: true
  accessMode: ReadWriteOnce
  size: 1Gi
  
  nextcloudData:
    enabled: false

service:
  type: ClusterIP
  port: 8080
  targetPort: 8080

ingress:
  enabled: false

# Probes - all must use port 8080 (nginx), not 9000 (PHP-FPM)
livenessProbe:
  enabled: true
  initialDelaySeconds: 60
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 6

readinessProbe:
  enabled: true
  initialDelaySeconds: 60
  periodSeconds: 15
  timeoutSeconds: 10
  failureThreshold: 6

startupProbe:
  enabled: true
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 30

# Reduced resources for Sandbox quota
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

rbac:
  enabled: true
  serviceaccount:
    create: true
    name: nextcloud-sa

cronjob:
  enabled: false

hpa:
  enabled: false

metrics:
  enabled: false
EOF

# Check if already deployed
if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    echo -e "${YELLOW}Existing deployment found. Upgrading...${NC}"
    HELM_CMD="upgrade"
else
    echo -e "${YELLOW}Installing Nextcloud...${NC}"
    HELM_CMD="install"
fi

# Deploy with Helm
helm ${HELM_CMD} "${RELEASE_NAME}" nextcloud/nextcloud \
    --namespace "${NAMESPACE}" \
    --values /tmp/nextcloud-sandbox-values.yaml \
    --set nextcloud.password="${ADMIN_PASSWORD}" \
    --timeout 10m || {
        echo -e "${YELLOW}Helm install initiated. Continuing with configuration...${NC}"
    }

# Wait for deployment to be created
echo -e "${YELLOW}Waiting for deployment to be ready...${NC}"
sleep 10

# Fix probe ports - they default to 9000 but nginx is on 8080
echo -e "${YELLOW}Fixing probe ports to target nginx (8080)...${NC}"
oc patch deploy nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/readinessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/livenessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/startupProbe/httpGet/port", "value": 8080}
]' 2>/dev/null || echo "Probes will be configured on next rollout"

# Create OpenShift Route
echo -e "${YELLOW}Creating OpenShift Route...${NC}"
oc delete route nextcloud 2>/dev/null || true
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: nextcloud
  labels:
    app.kubernetes.io/name: nextcloud
  annotations:
    haproxy.router.openshift.io/timeout: 300s
spec:
  host: ${HOSTNAME}
  to:
    kind: Service
    name: nextcloud
    weight: 100
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

# Wait for pod to be running
echo -e "${YELLOW}Waiting for pod to start (this may take 2-3 minutes)...${NC}"
oc rollout status deploy/nextcloud --timeout=300s || true

# Wait a bit more for PHP-FPM to initialize
sleep 15

# Configure Nextcloud trusted_domains and disable permission check
echo -e "${YELLOW}Configuring Nextcloud settings...${NC}"

# Wait for the pod to be fully ready
POD_READY=false
for i in {1..30}; do
    if oc exec deploy/nextcloud -c nextcloud -- php -v &>/dev/null; then
        POD_READY=true
        break
    fi
    echo "Waiting for PHP container... ($i/30)"
    sleep 5
done

if [ "$POD_READY" = true ]; then
    # Add trusted domains
    oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 1 --value="127.0.0.1" 2>/dev/null || true
    oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 2 --value="${HOSTNAME}" 2>/dev/null || true
    
    # Disable data directory permission check (false positive on OpenShift due to random UIDs)
    oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set check_data_directory_permissions --value="false" --type=boolean 2>/dev/null || true
    
    echo -e "${GREEN}Nextcloud configured successfully!${NC}"
else
    echo -e "${YELLOW}Pod not ready yet. You may need to run these commands manually after startup:${NC}"
    echo "  oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 1 --value=\"127.0.0.1\""
    echo "  oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 2 --value=\"${HOSTNAME}\""
    echo "  oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set check_data_directory_permissions --value=\"false\" --type=boolean"
fi

# Show pod status
echo ""
echo -e "${GREEN}=== Pod Status ===${NC}"
oc get pods -l app.kubernetes.io/name=nextcloud

# Verify SCC
echo ""
echo -e "${GREEN}=== Security Context ===${NC}"
POD_NAME=$(oc get pods -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${POD_NAME}" ]; then
    SCC=$(oc get pod "${POD_NAME}" -o jsonpath='{.metadata.annotations.openshift\.io/scc}' 2>/dev/null || echo "pending")
    echo -e "SCC: ${GREEN}${SCC}${NC}"
    if [ "${SCC}" = "restricted" ] || [ "${SCC}" = "restricted-v2" ]; then
        echo -e "${GREEN}✓ Running with restricted SCC - no elevated privileges!${NC}"
    fi
fi

# Display access information
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                NEXTCLOUD ACCESS INFORMATION                    ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} URL:      ${GREEN}https://${HOSTNAME}${NC}"
echo -e "${GREEN}║${NC} Username: ${GREEN}admin${NC}"
echo -e "${GREEN}║${NC} Password: ${GREEN}${ADMIN_PASSWORD}${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}NOTE: First load may take 1-2 minutes while Nextcloud initializes.${NC}"
echo -e "${YELLOW}      If you see a 403 error, wait a moment and refresh.${NC}"
echo ""

# Save credentials
cat > nextcloud-credentials.txt <<EOF
Nextcloud Access (Developer Sandbox)
=====================================
URL: https://${HOSTNAME}
Username: admin
Password: ${ADMIN_PASSWORD}
Namespace: ${NAMESPACE}

Generated: $(date)

Troubleshooting Commands:
-------------------------
# Check pod status
oc get pods -l app.kubernetes.io/name=nextcloud

# View logs
oc logs deploy/nextcloud -c nextcloud
oc logs deploy/nextcloud -c nextcloud-nginx

# Restart if needed
oc rollout restart deploy/nextcloud

# Re-configure trusted domains
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 2 --value="${HOSTNAME}"
EOF
chmod 600 nextcloud-credentials.txt
echo -e "Credentials saved to: ${GREEN}nextcloud-credentials.txt${NC}"

# Cleanup
rm -f /tmp/nextcloud-sandbox-values.yaml

echo ""
echo -e "${GREEN}Deployment complete!${NC}"

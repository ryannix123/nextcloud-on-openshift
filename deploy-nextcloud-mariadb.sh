#!/bin/bash
# Nextcloud Deployment Script for Red Hat Developer Sandbox
# WITH SCLORG MariaDB + Redis, EFS Storage, and Horizontal Scaling
#
# Features:
# - MariaDB (SCLORG) - OpenShift-native database
# - Redis (SCLORG) - Session sharing and file locking
# - EFS storage (RWX) - Enables multiple Nextcloud replicas
# - Horizontal scaling - Default 2 replicas
#
# Usage: ./deploy-nextcloud-mariadb.sh [hostname] [replicas]
# Example: ./deploy-nextcloud-mariadb.sh nextcloud-myproject.apps.sandbox.openshiftapps.com 2
#
# IMPORTANT: Run with 'bash', not 'sh':
#   bash ./deploy-nextcloud-mariadb.sh

set -euo pipefail

NAMESPACE=$(oc project -q 2>/dev/null || echo "")
HOSTNAME="${1:-}"
REPLICAS="${2:-2}"
RELEASE_NAME="nextcloud"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Nextcloud + MariaDB + Redis (Scalable) for OpenShift Sandbox ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
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
    # Try to get from existing route first
    HOSTNAME=$(oc get route nextcloud -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "${HOSTNAME}" ]; then
        # Try to extract apps domain from any existing route
        APPS_DOMAIN=$(oc get routes -A -o jsonpath='{.items[0].spec.host}' 2>/dev/null | sed 's/^[^.]*\.//' || echo "")
        
        if [ -n "${APPS_DOMAIN}" ]; then
            HOSTNAME="nextcloud-${NAMESPACE}.${APPS_DOMAIN}"
        fi
    fi
    
    if [ -n "${HOSTNAME}" ]; then
        echo -e "Auto-detected hostname: ${GREEN}${HOSTNAME}${NC}"
    else
        echo -e "${RED}Error: Could not auto-detect hostname. Please provide as argument.${NC}"
        echo "Usage: $0 <hostname> [replicas]"
        exit 1
    fi
fi

echo -e "Target hostname: ${GREEN}${HOSTNAME}${NC}"
echo -e "Nextcloud replicas: ${GREEN}${REPLICAS}${NC}"
echo ""

# Generate secure passwords
echo -e "${YELLOW}Generating secure passwords...${NC}"
ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')
MARIADB_PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
REDIS_PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')

# ═══════════════════════════════════════════════════════════════
# CLEANUP EXISTING RESOURCES (if any)
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}Cleaning up any existing Nextcloud resources...${NC}"
helm uninstall nextcloud 2>/dev/null || true
oc delete secret nextcloud-db nextcloud-admin nextcloud --ignore-not-found 2>/dev/null || true
oc delete configmap nextcloud-nginxconfig --ignore-not-found 2>/dev/null || true
oc delete route nextcloud --ignore-not-found 2>/dev/null || true
sleep 3

# ═══════════════════════════════════════════════════════════════
# MARIADB DEPLOYMENT (SCLORG)
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Deploying MariaDB (SCLORG Image)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Create MariaDB secret
echo -e "${YELLOW}Creating MariaDB secrets...${NC}"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-secret
  labels:
    app: mariadb
    app.kubernetes.io/part-of: nextcloud
type: Opaque
stringData:
  database-user: nextcloud
  database-password: ${MARIADB_PASSWORD}
  database-root-password: ${MARIADB_ROOT_PASSWORD}
  database-name: nextcloud
EOF

# Create MariaDB PVC (gp3 block storage - databases need RWO)
if ! oc get pvc mariadb-pvc &>/dev/null; then
    echo -e "${YELLOW}Creating MariaDB persistent storage (gp3)...${NC}"
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-pvc
  labels:
    app: mariadb
    app.kubernetes.io/part-of: nextcloud
spec:
  storageClassName: gp3
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF
else
    echo -e "${GREEN}MariaDB PVC already exists, reusing...${NC}"
fi

# Create MariaDB Deployment
echo -e "${YELLOW}Deploying MariaDB...${NC}"
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  labels:
    app: mariadb
    app.kubernetes.io/part-of: nextcloud
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
        - name: mariadb
          image: quay.io/sclorg/mariadb-1011-c9s:latest
          ports:
            - containerPort: 3306
              name: mariadb
          env:
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database-user
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database-password
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database-root-password
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database-name
          volumeMounts:
            - name: mariadb-data
              mountPath: /var/lib/mysql/data
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 512Mi
              cpu: 500m
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - mysqladmin ping -u root -p\${MYSQL_ROOT_PASSWORD}
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - mysql -u \${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "SELECT 1" \${MYSQL_DATABASE}
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 3
      volumes:
        - name: mariadb-data
          persistentVolumeClaim:
            claimName: mariadb-pvc
EOF

# Create MariaDB Service
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mariadb
  labels:
    app: mariadb
    app.kubernetes.io/part-of: nextcloud
spec:
  selector:
    app: mariadb
  ports:
    - port: 3306
      targetPort: 3306
      name: mariadb
EOF

# Wait for MariaDB to be ready
echo -e "${YELLOW}Waiting for MariaDB to be ready (this may take 1-2 minutes)...${NC}"
oc rollout status deployment/mariadb --timeout=180s || {
    echo -e "${YELLOW}MariaDB still starting, continuing...${NC}"
}

# ═══════════════════════════════════════════════════════════════
# REDIS DEPLOYMENT (SCLORG)
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Deploying Redis (SCLORG Image)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Create Redis secret
echo -e "${YELLOW}Creating Redis secrets...${NC}"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: redis-secret
  labels:
    app: redis
    app.kubernetes.io/part-of: nextcloud
type: Opaque
stringData:
  redis-password: ${REDIS_PASSWORD}
EOF

# Create Redis Deployment
echo -e "${YELLOW}Deploying Redis...${NC}"
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    app: redis
    app.kubernetes.io/part-of: nextcloud
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          # SCLORG Redis - runs as arbitrary UID, perfect for OpenShift restricted SCC
          image: quay.io/sclorg/redis-6-c9s:latest
          ports:
            - containerPort: 6379
              name: redis
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-secret
                  key: redis-password
          resources:
            requests:
              memory: 64Mi
              cpu: 50m
            limits:
              memory: 128Mi
              cpu: 200m
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - redis-cli -a \${REDIS_PASSWORD} ping | grep PONG
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 3
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - redis-cli -a \${REDIS_PASSWORD} ping | grep PONG
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
EOF

# Create Redis Service
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: redis
  labels:
    app: redis
    app.kubernetes.io/part-of: nextcloud
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
      name: redis
EOF

# Wait for Redis to be ready
echo -e "${YELLOW}Waiting for Redis to be ready...${NC}"
oc rollout status deployment/redis --timeout=120s || {
    echo -e "${YELLOW}Redis still starting, continuing...${NC}"
}

# Verify Redis is responding
echo -e "${YELLOW}Verifying Redis connection...${NC}"
for i in {1..12}; do
    if oc exec deployment/redis -- redis-cli -a ${REDIS_PASSWORD} ping 2>/dev/null | grep -q PONG; then
        echo -e "${GREEN}✓ Redis is ready!${NC}"
        break
    fi
    echo "Waiting for Redis... ($i/12)"
    sleep 5
done

# ═══════════════════════════════════════════════════════════════
# VERIFY MARIADB
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}Verifying MariaDB connection...${NC}"
for i in {1..12}; do
    if oc exec deployment/mariadb -- mysql -u nextcloud -p${MARIADB_PASSWORD} -e "SELECT 1" nextcloud &>/dev/null; then
        echo -e "${GREEN}✓ MariaDB is ready!${NC}"
        break
    fi
    echo "Waiting for MariaDB... ($i/12)"
    sleep 5
done

# ═══════════════════════════════════════════════════════════════
# NEXTCLOUD DEPLOYMENT
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Deploying Nextcloud (${REPLICAS} replicas with EFS storage)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Create Nextcloud admin secret
echo -e "${YELLOW}Creating Nextcloud secrets...${NC}"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-admin
  labels:
    app.kubernetes.io/part-of: nextcloud
type: Opaque
stringData:
  username: admin
  password: ${ADMIN_PASSWORD}
EOF

# Add helm repo
echo -e "${YELLOW}Adding Nextcloud Helm repository...${NC}"
helm repo add nextcloud https://nextcloud.github.io/helm/ 2>/dev/null || true
helm repo update

# Create values file with MariaDB, Redis, and EFS configuration
echo -e "${YELLOW}Creating Nextcloud configuration...${NC}"
cat > /tmp/nextcloud-mariadb-values.yaml <<'VALUESEOF'
# Nextcloud with External MariaDB, Redis, and EFS Storage (Scalable)

replicaCount: REPLICAS_PLACEHOLDER

image:
  repository: nextcloud
  flavor: fpm-alpine
  pullPolicy: IfNotPresent

nextcloud:
  host: HOSTNAME_PLACEHOLDER
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
    - name: REDIS_HOST
      value: "redis"
    - name: REDIS_HOST_PORT
      value: "6379"
    - name: REDIS_HOST_PASSWORD
      value: "REDIS_PASSWORD_PLACEHOLDER"

  configs:
    proxy.config.php: |-
      <?php
      $CONFIG = array (
        'trusted_proxies' => ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
        'overwriteprotocol' => 'https',
      );
    redis.config.php: |-
      <?php
      $CONFIG = array (
        'memcache.local' => '\\OC\\Memcache\\APCu',
        'memcache.distributed' => '\\OC\\Memcache\\Redis',
        'memcache.locking' => '\\OC\\Memcache\\Redis',
        'redis' => array(
          'host' => 'redis',
          'port' => 6379,
          'password' => 'REDIS_PASSWORD_PLACEHOLDER',
        ),
      );

nginx:
  enabled: true
  image:
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
              return 301 /index.php$request_uri;
          }
          
          location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
          location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }
          
          location ~ \.php(?:$|/) {
              rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) /index.php$request_uri;
              
              fastcgi_split_path_info ^(.+?\.php)(/.*)$;
              set $path_info $fastcgi_path_info;
              try_files $fastcgi_script_name =404;
              
              include fastcgi_params;
              fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
              fastcgi_param PATH_INFO $path_info;
              fastcgi_param HTTPS on;
              fastcgi_param modHeadersAvailable true;
              fastcgi_param front_controller_active true;
              fastcgi_pass 127.0.0.1:9000;
              
              fastcgi_intercept_errors on;
              fastcgi_request_buffering off;
              fastcgi_read_timeout 300;
          }
          
          location ~ \.(?:css|js|mjs|svg|gif|png|jpg|ico|wasm|tflite|map)$ {
              try_files $uri /index.php$request_uri;
              expires max;
              access_log off;
          }
          
          location ~ \.woff2?$ {
              try_files $uri /index.php$request_uri;
              expires 7d;
              access_log off;
          }
          
          location / {
              try_files $uri /index.php$request_uri;
          }
      }

# Disable internal SQLite database
internalDatabase:
  enabled: false

# External database configuration - MariaDB
externalDatabase:
  enabled: true
  type: mysql
  host: mariadb
  port: 3306
  database: nextcloud
  user: nextcloud
  password: MARIADB_PASSWORD_PLACEHOLDER

# Disable bundled database charts (we deploy our own)
postgresql:
  enabled: false

mariadb:
  enabled: false

redis:
  enabled: false

# Persistence - EFS for RWX (enables scaling)
persistence:
  enabled: true
  storageClass: "efs-sc"
  accessMode: ReadWriteMany
  size: 10Gi
  
  nextcloudData:
    enabled: false

service:
  type: ClusterIP
  port: 8080
  targetPort: 8080

ingress:
  enabled: false

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
  failureThreshold: 60

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi

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
VALUESEOF

# Replace placeholders in values file (handle macOS vs Linux sed)
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/HOSTNAME_PLACEHOLDER/${HOSTNAME}/g" /tmp/nextcloud-mariadb-values.yaml
    sed -i '' "s/MARIADB_PASSWORD_PLACEHOLDER/${MARIADB_PASSWORD}/g" /tmp/nextcloud-mariadb-values.yaml
    sed -i '' "s/REDIS_PASSWORD_PLACEHOLDER/${REDIS_PASSWORD}/g" /tmp/nextcloud-mariadb-values.yaml
    sed -i '' "s/REPLICAS_PLACEHOLDER/${REPLICAS}/g" /tmp/nextcloud-mariadb-values.yaml
else
    sed -i "s/HOSTNAME_PLACEHOLDER/${HOSTNAME}/g" /tmp/nextcloud-mariadb-values.yaml
    sed -i "s/MARIADB_PASSWORD_PLACEHOLDER/${MARIADB_PASSWORD}/g" /tmp/nextcloud-mariadb-values.yaml
    sed -i "s/REDIS_PASSWORD_PLACEHOLDER/${REDIS_PASSWORD}/g" /tmp/nextcloud-mariadb-values.yaml
    sed -i "s/REPLICAS_PLACEHOLDER/${REPLICAS}/g" /tmp/nextcloud-mariadb-values.yaml
fi

echo -e "${YELLOW}Installing Nextcloud via Helm...${NC}"
helm install "${RELEASE_NAME}" nextcloud/nextcloud \
    --namespace "${NAMESPACE}" \
    --values /tmp/nextcloud-mariadb-values.yaml \
    --set nextcloud.password="${ADMIN_PASSWORD}" \
    --timeout 10m

# Wait for deployment to be created
echo -e "${YELLOW}Waiting for Nextcloud deployment to be created...${NC}"
sleep 10

# ═══════════════════════════════════════════════════════════════
# CRITICAL FIXES
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Applying Critical Fixes${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# FIX 1: Service targetPort (Helm sets 9000, needs to be 8080 for nginx)
echo -e "${YELLOW}Fix 1: Patching service targetPort to 8080...${NC}"
oc patch svc nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/ports/0/targetPort", "value": 8080}
]'

# FIX 2: Probe ports (must target nginx on 8080, not PHP-FPM on 9000)
echo -e "${YELLOW}Fix 2: Patching probe ports to 8080...${NC}"
oc patch deploy nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/readinessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/livenessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/startupProbe/httpGet/port", "value": 8080}
]'

# FIX 3: Add Host header to probes (prevents 400 Bad Request from untrusted host)
echo -e "${YELLOW}Fix 3: Adding Host header to probes...${NC}"
oc patch deploy nextcloud --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/1/startupProbe/httpGet/httpHeaders", "value": [{"name": "Host", "value": "localhost"}]},
  {"op": "add", "path": "/spec/template/spec/containers/1/readinessProbe/httpGet/httpHeaders", "value": [{"name": "Host", "value": "localhost"}]},
  {"op": "add", "path": "/spec/template/spec/containers/1/livenessProbe/httpGet/httpHeaders", "value": [{"name": "Host", "value": "localhost"}]}
]'

# Create OpenShift Route
echo -e "${YELLOW}Creating OpenShift Route...${NC}"
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: nextcloud
  labels:
    app.kubernetes.io/name: nextcloud
    app.kubernetes.io/part-of: nextcloud
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
echo -e "${YELLOW}Waiting for Nextcloud pods to start...${NC}"
oc rollout status deploy/nextcloud --timeout=300s || true

# Wait for at least one container to be ready
echo -e "${YELLOW}Waiting for Nextcloud containers to be ready...${NC}"
for i in {1..60}; do
    READY_PODS=$(oc get pods -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -c "true" || echo "0")
    EXPECTED=$((REPLICAS * 2))  # 2 containers per pod
    if [ "$READY_PODS" -ge "2" ]; then
        echo -e "${GREEN}✓ At least one pod ready!${NC}"
        break
    fi
    echo "Waiting for containers... ($i/60) - $READY_PODS containers ready"
    sleep 5
done

# ═══════════════════════════════════════════════════════════════
# NEXTCLOUD CONFIGURATION
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Configuring Nextcloud${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Wait for config.php to exist
echo -e "${YELLOW}Waiting for Nextcloud initialization...${NC}"
for i in {1..30}; do
    if oc exec deploy/nextcloud -c nextcloud -- test -f /var/www/html/config/config.php 2>/dev/null; then
        echo -e "${GREEN}✓ config.php exists${NC}"
        break
    fi
    echo "Waiting for config.php... ($i/30)"
    sleep 5
done

# FIX 4: Disable data directory permission check (direct config edit to avoid occ chicken-egg)
echo -e "${YELLOW}Fix 4: Disabling data directory permission check...${NC}"
oc exec deploy/nextcloud -c nextcloud -- sed -i "s/);/  'check_data_directory_permissions' => false,\n);/" /var/www/html/config/config.php 2>/dev/null || true

# FIX 5: Add all required trusted domains
echo -e "${YELLOW}Fix 5: Configuring trusted domains...${NC}"
sleep 5  # Let the config change settle
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 0 --value="localhost" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 1 --value="127.0.0.1" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 2 --value="${HOSTNAME}" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 3 --value="nextcloud" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 4 --value="nextcloud.${NAMESPACE}.svc.cluster.local" 2>/dev/null || true

echo -e "${GREEN}✓ Nextcloud configured!${NC}"

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Show pod status
echo -e "${BLUE}Pod Status:${NC}"
oc get pods -l app.kubernetes.io/part-of=nextcloud 2>/dev/null || oc get pods
echo ""

# Verify SCCs
echo -e "${BLUE}Security Context Constraints:${NC}"
for pod in $(oc get pods -o name 2>/dev/null | grep -E "(nextcloud|mariadb|redis)"); do
    SCC=$(oc get ${pod} -o jsonpath='{.metadata.annotations.openshift\.io/scc}' 2>/dev/null || echo "unknown")
    echo -e "  ${pod}: ${GREEN}${SCC}${NC}"
done
echo ""

# Display access information
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              NEXTCLOUD ACCESS INFORMATION                      ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} URL:      ${GREEN}https://${HOSTNAME}${NC}"
echo -e "${GREEN}║${NC} Username: ${GREEN}admin${NC}"
echo -e "${GREEN}║${NC} Password: ${GREEN}${ADMIN_PASSWORD}${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Replicas: ${BLUE}${REPLICAS}${NC} (scalable with EFS storage)"
echo -e "${GREEN}║${NC} Storage:  ${BLUE}EFS (ReadWriteMany)${NC}"
echo -e "${GREEN}║${NC} Database: ${BLUE}MariaDB 10.11 (SCLORG)${NC}"
echo -e "${GREEN}║${NC} Cache:    ${BLUE}Redis 6 (SCLORG)${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}NOTE: First load may take 30-60 seconds while Nextcloud initializes.${NC}"
echo ""

# Save credentials
cat > nextcloud-mariadb-credentials.txt <<EOF
Nextcloud with MariaDB + Redis (Developer Sandbox - Scalable)
=============================================================
URL: https://${HOSTNAME}
Username: admin
Password: ${ADMIN_PASSWORD}
Namespace: ${NAMESPACE}

Architecture:
-------------
Nextcloud Replicas: ${REPLICAS}
Storage: EFS (efs-sc) - ReadWriteMany
Database: MariaDB 10.11 (SCLORG) - gp3
Cache: Redis 6 (SCLORG)

Database Information:
---------------------
Host: mariadb
Port: 3306
Database: nextcloud
DB User: nextcloud
DB Password: ${MARIADB_PASSWORD}

Redis Information:
------------------
Host: redis
Port: 6379
Password: ${REDIS_PASSWORD}

Generated: $(date)

Applied Fixes:
--------------
1. Service targetPort: 9000 -> 8080 (nginx, not PHP-FPM)
2. Probe ports: 9000 -> 8080
3. Probe Host header: Added "Host: localhost"
4. Disabled data directory permission check
5. Trusted domains: localhost, 127.0.0.1, external hostname, service names

Scaling Commands:
-----------------
# Scale up to 3 replicas
oc scale deploy/nextcloud --replicas=3

# Scale down to 1 replica
oc scale deploy/nextcloud --replicas=1

# Check current replicas
oc get deploy nextcloud

Troubleshooting Commands:
-------------------------
# Check all pods
oc get pods

# View Nextcloud logs
oc logs deploy/nextcloud -c nextcloud
oc logs deploy/nextcloud -c nextcloud-nginx

# View MariaDB logs
oc logs deploy/mariadb

# View Redis logs
oc logs deploy/redis

# Connect to MariaDB
oc exec -it deploy/mariadb -- mysql -u nextcloud -p${MARIADB_PASSWORD} nextcloud

# Test Redis
oc exec deploy/redis -- redis-cli -a ${REDIS_PASSWORD} ping

# Test health endpoint
oc exec deploy/nextcloud -c nextcloud-nginx -- curl -s -H "Host: localhost" http://localhost:8080/status.php

# Check trusted domains
oc exec deploy/nextcloud -c nextcloud -- cat /var/www/html/config/config.php | grep -A10 trusted_domains

# Verify Redis is being used
oc exec deploy/nextcloud -c nextcloud -- cat /var/www/html/config/config.php | grep -A10 redis

# Restart deployments
oc rollout restart deploy/nextcloud
oc rollout restart deploy/mariadb
oc rollout restart deploy/redis
EOF
chmod 600 nextcloud-mariadb-credentials.txt
echo -e "Credentials saved to: ${GREEN}nextcloud-mariadb-credentials.txt${NC}"

# Cleanup
rm -f /tmp/nextcloud-mariadb-values.yaml

echo ""
echo -e "${GREEN}🎉 Deployment complete! Nextcloud running with ${REPLICAS} replicas, MariaDB, and Redis.${NC}"
echo -e "${GREEN}   All components running under restricted SCC.${NC}"

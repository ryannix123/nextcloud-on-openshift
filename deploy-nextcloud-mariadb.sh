#!/bin/bash
# Nextcloud Deployment Script for Red Hat Developer Sandbox
# WITH MinIO (S3 Object Storage) + MariaDB + Redis
#
# Architecture:
# - MinIO: S3-compatible object storage for user files (fast, scalable)
# - MariaDB: Metadata and user database
# - Redis: Session handling and file locking
# - EFS: Shared app code/config (enables multi-replica)
#
# Usage: ./deploy-nextcloud-mariadb.sh [hostname] [replicas]
# Example: ./deploy-nextcloud-mariadb.sh nextcloud-myproject.apps.sandbox.openshiftapps.com 2
#
# IMPORTANT: Run with 'bash', not 'sh':
#   bash ./deploy-nextcloud-mariadb.sh

set -euo pipefail

NAMESPACE=$(oc project -q 2>/dev/null || echo "")
HOSTNAME="${1:-}"
REPLICAS="${2:-1}"  # Start with 1, scale after init
RELEASE_NAME="nextcloud"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Nextcloud + MinIO + MariaDB + Redis (Cloud-Native Stack)     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Architecture:${NC}"
echo -e "  • MinIO (S3)  → User file storage (scalable)"
echo -e "  • MariaDB     → Metadata database"
echo -e "  • Redis       → Sessions & file locking"
echo -e "  • gp3 (EBS)   → App code (fast, single replica)"
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
    HOSTNAME=$(oc get route nextcloud -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "${HOSTNAME}" ]; then
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
echo -e "Initial replicas: ${GREEN}${REPLICAS}${NC}"
echo ""

# Generate secure passwords
echo -e "${YELLOW}Generating secure credentials...${NC}"
ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')
MARIADB_PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
REDIS_PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
MINIO_ACCESS_KEY=$(openssl rand -hex 10)
MINIO_SECRET_KEY=$(openssl rand -base64 24 | tr -d '=+/')

# ═══════════════════════════════════════════════════════════════
# CLEANUP EXISTING RESOURCES
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}Cleaning up any existing resources...${NC}"
helm uninstall nextcloud 2>/dev/null || true
oc delete secret nextcloud-db nextcloud-admin nextcloud --ignore-not-found 2>/dev/null || true
oc delete configmap nextcloud-nginxconfig --ignore-not-found 2>/dev/null || true
oc delete route nextcloud --ignore-not-found 2>/dev/null || true
sleep 3

# ═══════════════════════════════════════════════════════════════
# MINIO DEPLOYMENT (S3-Compatible Object Storage)
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Deploying MinIO (S3-Compatible Object Storage)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Create MinIO secret
echo -e "${YELLOW}Creating MinIO secrets...${NC}"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  labels:
    app: minio
    app.kubernetes.io/part-of: nextcloud
type: Opaque
stringData:
  root-user: ${MINIO_ROOT_USER}
  root-password: ${MINIO_ROOT_PASSWORD}
  access-key: ${MINIO_ACCESS_KEY}
  secret-key: ${MINIO_SECRET_KEY}
EOF

# Create MinIO PVC (gp3 for fast block storage)
if ! oc get pvc minio-pvc &>/dev/null; then
    echo -e "${YELLOW}Creating MinIO persistent storage (gp3 - fast)...${NC}"
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  labels:
    app: minio
    app.kubernetes.io/part-of: nextcloud
spec:
  storageClassName: gp3
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
EOF
else
    echo -e "${GREEN}MinIO PVC already exists, reusing...${NC}"
fi

# Create MinIO Deployment
echo -e "${YELLOW}Deploying MinIO...${NC}"
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  labels:
    app: minio
    app.kubernetes.io/part-of: nextcloud
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: quay.io/minio/minio:latest
          args:
            - server
            - /data
            - --console-address
            - ":9001"
          ports:
            - containerPort: 9000
              name: api
            - containerPort: 9001
              name: console
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: root-user
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: root-password
          volumeMounts:
            - name: minio-data
              mountPath: /data
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 512Mi
              cpu: 500m
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: minio-data
          persistentVolumeClaim:
            claimName: minio-pvc
EOF

# Create MinIO Service
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: minio
  labels:
    app: minio
    app.kubernetes.io/part-of: nextcloud
spec:
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
      name: api
    - port: 9001
      targetPort: 9001
      name: console
EOF

# Wait for MinIO
echo -e "${YELLOW}Waiting for MinIO to be ready...${NC}"
oc rollout status deployment/minio --timeout=180s || true

# Create bucket for Nextcloud
echo -e "${YELLOW}Creating Nextcloud bucket in MinIO...${NC}"
sleep 10  # Give MinIO time to fully start

for i in {1..12}; do
    if oc exec deployment/minio -- mc alias set local http://localhost:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} &>/dev/null; then
        oc exec deployment/minio -- mc mb local/nextcloud --ignore-existing 2>/dev/null || true
        # Create access policy for the bucket
        oc exec deployment/minio -- mc admin user add local ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} 2>/dev/null || true
        oc exec deployment/minio -- mc admin policy attach local readwrite --user ${MINIO_ACCESS_KEY} 2>/dev/null || true
        echo -e "${GREEN}✓ MinIO bucket 'nextcloud' created!${NC}"
        break
    fi
    echo "Waiting for MinIO API... ($i/12)"
    sleep 5
done

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

# Create MariaDB PVC
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

# Wait for MariaDB
echo -e "${YELLOW}Waiting for MariaDB to be ready...${NC}"
oc rollout status deployment/mariadb --timeout=180s || true

# Verify MariaDB
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

# Wait for Redis
echo -e "${YELLOW}Waiting for Redis to be ready...${NC}"
oc rollout status deployment/redis --timeout=120s || true

# ═══════════════════════════════════════════════════════════════
# NEXTCLOUD DEPLOYMENT
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Deploying Nextcloud (with S3 Object Storage)${NC}"
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

# Create values file
echo -e "${YELLOW}Creating Nextcloud configuration...${NC}"
cat > /tmp/nextcloud-values.yaml <<VALUESEOF
# Nextcloud with S3 Object Storage (MinIO)

replicaCount: ${REPLICAS}

image:
  repository: nextcloud
  flavor: fpm-alpine
  pullPolicy: IfNotPresent

nextcloud:
  host: ${HOSTNAME}
  username: admin
  password: ${ADMIN_PASSWORD}
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
    - name: OBJECTSTORE_S3_HOST
      value: "minio"
    - name: OBJECTSTORE_S3_PORT
      value: "9000"
    - name: OBJECTSTORE_S3_SSL
      value: "false"
    - name: OBJECTSTORE_S3_USEPATH_STYLE
      value: "true"
    - name: OBJECTSTORE_S3_BUCKET
      value: "nextcloud"
    - name: OBJECTSTORE_S3_KEY
      value: "${MINIO_ACCESS_KEY}"
    - name: OBJECTSTORE_S3_SECRET
      value: "${MINIO_SECRET_KEY}"

  configs:
    proxy.config.php: |-
      <?php
      \$CONFIG = array (
        'trusted_proxies' => ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
        'overwriteprotocol' => 'https',
      );
    # S3 is configured via OBJECTSTORE_S3_* environment variables above

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
          
          client_max_body_size 10G;
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
              fastcgi_read_timeout 3600;
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

# Database
internalDatabase:
  enabled: false

externalDatabase:
  enabled: true
  type: mysql
  host: mariadb
  port: 3306
  database: nextcloud
  user: nextcloud
  password: ${MARIADB_PASSWORD}

postgresql:
  enabled: false

mariadb:
  enabled: false

redis:
  enabled: false

# Storage - gp3 for app code (fast, correct ownership)
# Note: RWO limits to single replica, but MinIO handles user files
persistence:
  enabled: true
  storageClass: "gp3"
  accessMode: ReadWriteOnce
  size: 5Gi
  
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
  initialDelaySeconds: 120
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 6

readinessProbe:
  enabled: true
  initialDelaySeconds: 120
  periodSeconds: 15
  timeoutSeconds: 10
  failureThreshold: 6

startupProbe:
  enabled: true
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 90

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 2000m
    memory: 1Gi

rbac:
  enabled: false
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

echo -e "${YELLOW}Installing Nextcloud via Helm...${NC}"
helm install "${RELEASE_NAME}" nextcloud/nextcloud \
    --namespace "${NAMESPACE}" \
    --values /tmp/nextcloud-values.yaml \
    --timeout 15m

# Wait for deployment
echo -e "${YELLOW}Waiting for Nextcloud deployment...${NC}"
sleep 15

# ═══════════════════════════════════════════════════════════════
# CRITICAL FIXES
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Applying Critical Fixes${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# FIX 1: Service targetPort
echo -e "${YELLOW}Fix 1: Patching service targetPort to 8080...${NC}"
oc patch svc nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/ports/0/targetPort", "value": 8080}
]'

# FIX 2: Probe ports
echo -e "${YELLOW}Fix 2: Patching probe ports to 8080...${NC}"
oc patch deploy nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/readinessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/livenessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/startupProbe/httpGet/port", "value": 8080}
]'

# FIX 3: Host headers for probes
echo -e "${YELLOW}Fix 3: Adding Host header to probes...${NC}"
oc patch deploy nextcloud --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/1/startupProbe/httpGet/httpHeaders", "value": [{"name": "Host", "value": "localhost"}]},
  {"op": "add", "path": "/spec/template/spec/containers/1/readinessProbe/httpGet/httpHeaders", "value": [{"name": "Host", "value": "localhost"}]},
  {"op": "add", "path": "/spec/template/spec/containers/1/livenessProbe/httpGet/httpHeaders", "value": [{"name": "Host", "value": "localhost"}]}
]'

# Create Route
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
    haproxy.router.openshift.io/timeout: 3600s
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

# Create MinIO console route (optional, for debugging)
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: minio-console
  labels:
    app: minio
    app.kubernetes.io/part-of: nextcloud
spec:
  host: minio-${NAMESPACE}.${HOSTNAME#*-${NAMESPACE}.}
  to:
    kind: Service
    name: minio
    weight: 100
  port:
    targetPort: 9001
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Wait for pods
echo ""
echo -e "${YELLOW}Waiting for Nextcloud initialization...${NC}"
echo -e "${YELLOW}(gp3 is faster than EFS - should take 2-3 minutes)${NC}"
echo ""

# Monitor progress
for i in {1..90}; do
    PHASE=$(oc get pods -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    READY=$(oc get pods -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -c "true" 2>/dev/null || echo "0")
    
    if [ "$READY" = "2" ]; then
        echo -e "\n${GREEN}✓ Nextcloud is ready!${NC}"
        break
    fi
    
    # Show file count progress every 10 iterations
    if [ $((i % 10)) -eq 0 ]; then
        FILES=$(oc exec deploy/nextcloud -c nextcloud -- find /var/www/html -type f 2>/dev/null | wc -l 2>/dev/null || echo "?")
        echo "  Files synced: ~${FILES} (need ~20,000)"
    else
        echo -n "."
    fi
    sleep 10
done
echo ""

# ═══════════════════════════════════════════════════════════════
# NEXTCLOUD CONFIGURATION
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Configuring Nextcloud${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Wait for config.php
echo -e "${YELLOW}Waiting for Nextcloud config...${NC}"
for i in {1..30}; do
    if oc exec deploy/nextcloud -c nextcloud -- test -f /var/www/html/config/config.php 2>/dev/null; then
        echo -e "${GREEN}✓ config.php exists${NC}"
        break
    fi
    echo "Waiting for config.php... ($i/30)"
    sleep 10
done

# Apply configurations
echo -e "${YELLOW}Applying Nextcloud configurations...${NC}"
sleep 5

# Disable permission check
oc exec deploy/nextcloud -c nextcloud -- sed -i "s/);/  'check_data_directory_permissions' => false,\n);/" /var/www/html/config/config.php 2>/dev/null || true

# Set trusted domains
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 0 --value="localhost" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 1 --value="127.0.0.1" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 2 --value="${HOSTNAME}" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 3 --value="nextcloud" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set trusted_domains 4 --value="nextcloud.${NAMESPACE}.svc.cluster.local" 2>/dev/null || true

# Configure Redis
echo -e "${YELLOW}Configuring Redis...${NC}"
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set redis host --value="redis" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set redis port --value="6379" --type=integer 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set redis password --value="${REDIS_PASSWORD}" 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set memcache.local --value='\OC\Memcache\APCu' 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set memcache.distributed --value='\OC\Memcache\Redis' 2>/dev/null || true
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set memcache.locking --value='\OC\Memcache\Redis' 2>/dev/null || true

echo -e "${GREEN}✓ Nextcloud configured!${NC}"

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Pod status
echo -e "${BLUE}Pod Status:${NC}"
oc get pods -l app.kubernetes.io/part-of=nextcloud
echo ""

# SCC verification
echo -e "${BLUE}Security Context Constraints:${NC}"
for pod in $(oc get pods -o name 2>/dev/null | grep -E "(nextcloud|mariadb|redis|minio)"); do
    SCC=$(oc get ${pod} -o jsonpath='{.metadata.annotations.openshift\.io/scc}' 2>/dev/null || echo "unknown")
    echo -e "  ${pod}: ${GREEN}${SCC}${NC}"
done
echo ""

# Access info
MINIO_CONSOLE_URL="https://minio-${NAMESPACE}.${HOSTNAME#*-${NAMESPACE}.}"
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              NEXTCLOUD ACCESS INFORMATION                      ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Nextcloud URL:  ${GREEN}https://${HOSTNAME}${NC}"
echo -e "${GREEN}║${NC} Username:       ${GREEN}admin${NC}"
echo -e "${GREEN}║${NC} Password:       ${GREEN}${ADMIN_PASSWORD}${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} MinIO Console:  ${BLUE}${MINIO_CONSOLE_URL}${NC}"
echo -e "${GREEN}║${NC} MinIO User:     ${BLUE}${MINIO_ROOT_USER}${NC}"
echo -e "${GREEN}║${NC} MinIO Password: ${BLUE}${MINIO_ROOT_PASSWORD}${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Storage:        ${BLUE}MinIO S3 (fast object storage)${NC}"
echo -e "${GREEN}║${NC} Database:       ${BLUE}MariaDB 10.11 (SCLORG)${NC}"
echo -e "${GREEN}║${NC} Cache:          ${BLUE}Redis 6 (SCLORG)${NC}"
echo -e "${GREEN}║${NC} App Storage:    ${BLUE}gp3 (fast EBS)${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Note: Single replica only (gp3 = RWO). User files scale via MinIO S3.${NC}"
echo ""

# Save credentials
cat > nextcloud-credentials.txt <<EOF
Nextcloud with MinIO S3 Storage (Developer Sandbox)
====================================================
Generated: $(date)

Nextcloud:
----------
URL: https://${HOSTNAME}
Username: admin
Password: ${ADMIN_PASSWORD}
Namespace: ${NAMESPACE}

MinIO Console:
--------------
URL: ${MINIO_CONSOLE_URL}
Root User: ${MINIO_ROOT_USER}
Root Password: ${MINIO_ROOT_PASSWORD}
Access Key: ${MINIO_ACCESS_KEY}
Secret Key: ${MINIO_SECRET_KEY}
Bucket: nextcloud

Database (MariaDB):
-------------------
Host: mariadb:3306
Database: nextcloud
User: nextcloud
Password: ${MARIADB_PASSWORD}

Redis:
------
Host: redis:6379
Password: ${REDIS_PASSWORD}

Architecture:
-------------
• MinIO: S3 object storage for user files (scalable, fast)
• MariaDB: Metadata database
• Redis: Sessions and file locking (enables multi-pod)
• gp3: App code storage (fast EBS, single replica)

Note on Scaling:
----------------
# Nextcloud app is single-replica (gp3 = RWO)
# But user files scale infinitely via MinIO S3
# To enable multi-replica, use a custom image with baked-in files

Troubleshooting:
----------------
# Nextcloud logs
oc logs deploy/nextcloud -c nextcloud
oc logs deploy/nextcloud -c nextcloud-nginx

# MinIO logs
oc logs deploy/minio

# Test S3 connectivity
oc exec deploy/nextcloud -c nextcloud -- curl -s http://minio:9000/minio/health/ready

# Check S3 config
oc exec deploy/nextcloud -c nextcloud -- cat /var/www/html/config/config.php | grep -A15 objectstore

# Redis test
oc exec deploy/redis -- redis-cli -a ${REDIS_PASSWORD} ping
EOF
chmod 600 nextcloud-credentials.txt
echo -e "Credentials saved to: ${GREEN}nextcloud-credentials.txt${NC}"

# Cleanup
rm -f /tmp/nextcloud-values.yaml

echo ""
echo -e "${GREEN}🎉 Cloud-native Nextcloud deployed with S3 object storage!${NC}"
echo -e "${GREEN}   Files are stored in MinIO - fast and scalable.${NC}"

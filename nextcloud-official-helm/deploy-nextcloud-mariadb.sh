#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Nextcloud Deployment Script for OpenShift
# Cloud-Native Architecture: MinIO (S3) + MariaDB + Redis
# ═══════════════════════════════════════════════════════════════════════════════
#
# Architecture:
#   • MinIO:    S3-compatible object storage for user files
#   • MariaDB:  Metadata database (SCLORG image for OpenShift compatibility)
#   • Redis:    Session handling and file locking
#   • gp3 EBS:  Fast block storage for app code
#
# Usage:
#   ./deploy-nextcloud.sh [hostname] [storage-class]
#
# Examples:
#   ./deploy-nextcloud.sh nextcloud-myproject.apps.cluster.com
#   ./deploy-nextcloud.sh nextcloud-myproject.apps.cluster.com gp3-csi
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
RELEASE_NAME="nextcloud"
MINIO_STORAGE="20Gi"
MARIADB_STORAGE="2Gi"
NEXTCLOUD_STORAGE="5Gi"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║                                                                       ║"
echo "║   ███╗   ██╗███████╗██╗  ██╗████████╗ ██████╗██╗      ██████╗ ██╗   ██╗║"
echo "║   ████╗  ██║██╔════╝╚██╗██╔╝╚══██╔══╝██╔════╝██║     ██╔═══██╗██║   ██║║"
echo "║   ██╔██╗ ██║█████╗   ╚███╔╝    ██║   ██║     ██║     ██║   ██║██║   ██║║"
echo "║   ██║╚██╗██║██╔══╝   ██╔██╗    ██║   ██║     ██║     ██║   ██║██║   ██║║"
echo "║   ██║ ╚████║███████╗██╔╝ ██╗   ██║   ╚██████╗███████╗╚██████╔╝╚██████╔╝║"
echo "║   ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ║"
echo "║                                                                       ║"
echo "║            Cloud-Native Deployment for OpenShift                      ║"
echo "║            MinIO (S3) + MariaDB + Redis                               ║"
echo "║                                                                       ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites Check
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▸ Checking prerequisites...${NC}"

command -v oc >/dev/null 2>&1 || { echo -e "${RED}✗ Error: oc CLI not found${NC}"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}✗ Error: helm CLI not found${NC}"; exit 1; }

if ! oc whoami &>/dev/null; then
    echo -e "${RED}✗ Error: Not logged into OpenShift cluster${NC}"
    exit 1
fi

NAMESPACE=$(oc project -q)
echo -e "${GREEN}✓ Logged in to OpenShift${NC}"
echo -e "  Namespace: ${CYAN}${NAMESPACE}${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Parse Arguments
# ─────────────────────────────────────────────────────────────────────────────
HOSTNAME="${1:-}"
STORAGE_CLASS="${2:-gp3}"

# Auto-detect hostname if not provided
if [ -z "${HOSTNAME}" ]; then
    HOSTNAME=$(oc get route ${RELEASE_NAME} -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "${HOSTNAME}" ]; then
        APPS_DOMAIN=$(oc get routes -A -o jsonpath='{.items[0].spec.host}' 2>/dev/null | sed 's/^[^.]*\.//' || echo "")
        if [ -n "${APPS_DOMAIN}" ]; then
            HOSTNAME="${RELEASE_NAME}-${NAMESPACE}.${APPS_DOMAIN}"
        fi
    fi
    
    if [ -z "${HOSTNAME}" ]; then
        echo -e "${RED}✗ Error: Could not auto-detect hostname${NC}"
        echo "Usage: $0 <hostname> [storage-class]"
        exit 1
    fi
fi

echo -e "  Hostname: ${CYAN}${HOSTNAME}${NC}"
echo -e "  Storage Class: ${CYAN}${STORAGE_CLASS}${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Generate Credentials
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▸ Generating secure credentials...${NC}"

ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
MARIADB_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/')
REDIS_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/')

echo -e "${GREEN}✓ Credentials generated${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup Existing Resources
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▸ Cleaning up existing resources...${NC}"

helm uninstall ${RELEASE_NAME} 2>/dev/null || true
oc delete deployment minio mariadb redis --ignore-not-found 2>/dev/null || true
oc delete service minio mariadb redis --ignore-not-found 2>/dev/null || true
oc delete secret minio-secret mariadb-secret redis-secret nextcloud-admin --ignore-not-found 2>/dev/null || true
oc delete route ${RELEASE_NAME} --ignore-not-found 2>/dev/null || true
oc delete configmap nextcloud-config --ignore-not-found 2>/dev/null || true

# Wait for resources to be cleaned up
sleep 5
echo -e "${GREEN}✓ Cleanup complete${NC}"

# ═══════════════════════════════════════════════════════════════════════════════
# MINIO DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  MinIO (S3-Compatible Object Storage)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# MinIO Secret
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
  root-user: "${MINIO_ROOT_USER}"
  root-password: "${MINIO_ROOT_PASSWORD}"
EOF

# MinIO PVC
if ! oc get pvc minio-pvc &>/dev/null; then
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  labels:
    app: minio
    app.kubernetes.io/part-of: nextcloud
spec:
  storageClassName: ${STORAGE_CLASS}
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${MINIO_STORAGE}
EOF
fi

# MinIO Deployment
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
            - name: data
              mountPath: /data
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 1Gi
              cpu: 1000m
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: 9000
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
EOF

# MinIO Service
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

echo -e "${YELLOW}  Waiting for MinIO...${NC}"
oc rollout status deployment/minio --timeout=180s

# Create bucket
echo -e "${YELLOW}  Creating Nextcloud bucket...${NC}"
sleep 10
for i in {1..12}; do
    if oc exec deployment/minio -- mc alias set local http://localhost:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" &>/dev/null; then
        oc exec deployment/minio -- mc mb local/nextcloud --ignore-existing 2>/dev/null || true
        echo -e "${GREEN}✓ MinIO ready with 'nextcloud' bucket${NC}"
        break
    fi
    echo "  Waiting for MinIO API... ($i/12)"
    sleep 5
done

# ═══════════════════════════════════════════════════════════════════════════════
# MARIADB DEPLOYMENT (SCLORG)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  MariaDB (SCLORG Image for OpenShift)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# MariaDB Secret
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
  database-password: "${MARIADB_PASSWORD}"
  database-root-password: "${MARIADB_ROOT_PASSWORD}"
  database-name: nextcloud
EOF

# MariaDB PVC
if ! oc get pvc mariadb-pvc &>/dev/null; then
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-pvc
  labels:
    app: mariadb
    app.kubernetes.io/part-of: nextcloud
spec:
  storageClassName: ${STORAGE_CLASS}
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${MARIADB_STORAGE}
EOF
fi

# MariaDB Deployment (SCLORG image)
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
          image: registry.redhat.io/rhel9/mariadb-1011:latest
          ports:
            - containerPort: 3306
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
            - name: data
              mountPath: /var/lib/mysql/data
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 1Gi
              cpu: 1000m
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - mysqladmin ping -h localhost
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - mysql -h localhost -u\${MYSQL_USER} -p\${MYSQL_PASSWORD} -e "SELECT 1"
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: mariadb-pvc
EOF

# MariaDB Service
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
EOF

echo -e "${YELLOW}  Waiting for MariaDB...${NC}"
oc rollout status deployment/mariadb --timeout=180s
echo -e "${GREEN}✓ MariaDB ready${NC}"

# ═══════════════════════════════════════════════════════════════════════════════
# REDIS DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Redis (Session & Cache)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Redis Secret
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
  database-password: "${REDIS_PASSWORD}"
EOF

# Redis Deployment (in-memory, no persistence needed for cache)
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
          image: docker.io/redis:7-alpine
          command:
            - redis-server
            - --requirepass
            - \$(REDIS_PASSWORD)
            - --maxmemory
            - 256mb
            - --maxmemory-policy
            - allkeys-lru
          ports:
            - containerPort: 6379
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-secret
                  key: database-password
          resources:
            requests:
              memory: 64Mi
              cpu: 50m
            limits:
              memory: 512Mi
              cpu: 500m
          livenessProbe:
            exec:
              command: ["sh", "-c", "redis-cli -a \${REDIS_PASSWORD} ping | grep PONG"]
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["sh", "-c", "redis-cli -a \${REDIS_PASSWORD} ping | grep PONG"]
            initialDelaySeconds: 5
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
EOF

# Redis Service
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
EOF

echo -e "${YELLOW}  Waiting for Redis...${NC}"
oc rollout status deployment/redis --timeout=120s
echo -e "${GREEN}✓ Redis ready${NC}"

# ═══════════════════════════════════════════════════════════════════════════════
# NEXTCLOUD DEPLOYMENT (HELM)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Nextcloud (Helm Chart)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Add/update Helm repo
helm repo add nextcloud https://nextcloud.github.io/helm/ 2>/dev/null || true
helm repo update

# Create Nextcloud admin secret
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
  password: "${ADMIN_PASSWORD}"
EOF

# ─────────────────────────────────────────────────────────────────────────────
# CREATE VALUES FILE
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}  Creating Helm values file...${NC}"

cat > /tmp/nextcloud-values.yaml <<EOF
# ═══════════════════════════════════════════════════════════════════════════════
# Nextcloud Helm Values for OpenShift
# Cloud-Native Architecture: MinIO S3 + External MariaDB + External Redis
# ═══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# Image Configuration
# ─────────────────────────────────────────────────────────────────────────────
image:
  registry: docker.io
  repository: library/nextcloud
  tag: "32-fpm"
  pullPolicy: IfNotPresent

# ─────────────────────────────────────────────────────────────────────────────
# Nginx Sidecar (Required for FPM)
# ─────────────────────────────────────────────────────────────────────────────
nginx:
  enabled: true
  image:
    registry: docker.io
    repository: nginxinc/nginx-unprivileged
    tag: alpine
    pullPolicy: IfNotPresent
  
  containerPort: 8080
  
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    readOnlyRootFilesystem: false
    capabilities:
      drop: ["ALL"]
    seccompProfile:
      type: RuntimeDefault
  
  config:
    default: false
    custom: |-
      server {
          listen 8080;
          server_name _;
          root /var/www/html;
          index index.php index.html;
          
          client_max_body_size 10G;
          client_body_timeout 300s;
          fastcgi_buffers 64 4K;
          fastcgi_read_timeout 3600s;
          
          add_header Referrer-Policy "no-referrer" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header X-Permitted-Cross-Domain-Policies "none" always;
          add_header X-Robots-Tag "noindex, nofollow" always;
          add_header X-XSS-Protection "1; mode=block" always;
          
          location = /robots.txt {
              allow all;
              log_not_found off;
              access_log off;
          }
          
          location ^~ /.well-known {
              location = /.well-known/carddav { return 301 /remote.php/dav/; }
              location = /.well-known/caldav { return 301 /remote.php/dav/; }
              location = /.well-known/webfinger { return 301 /index.php/.well-known/webfinger; }
              location = /.well-known/nodeinfo { return 301 /index.php/.well-known/nodeinfo; }
              return 301 /index.php\$request_uri;
          }
          
          location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
          location ~ ^/(?:\\.|autotest|occ|issue|indie|db_|console) { return 404; }
          
          location ~ \\.php(?:$|/) {
              rewrite ^/(?!index|remote|public|cron|core\\/ajax\\/update|status|ocs\\/v[12]|updater\\/.+|oc[ms]-provider\\/.+|.+\\/richdocumentscode(_arm64)?\\/proxy) /index.php\$request_uri;
              
              fastcgi_split_path_info ^(.+?\\.php)(/.*)$;
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
          }
          
          location ~ \\.(?:css|js|mjs|svg|gif|png|jpg|ico|wasm|tflite|map|ogg|flac)$ {
              try_files \$uri /index.php\$request_uri;
              expires 6M;
              access_log off;
          }
          
          location ~ \\.woff2?$ {
              try_files \$uri /index.php\$request_uri;
              expires 7d;
              access_log off;
          }
          
          location /remote {
              return 301 /remote.php\$request_uri;
          }
          
          location / {
              try_files \$uri \$uri/ /index.php\$request_uri;
          }
      }

# ─────────────────────────────────────────────────────────────────────────────
# Nextcloud Configuration
# ─────────────────────────────────────────────────────────────────────────────
nextcloud:
  host: ${HOSTNAME}
  
  # Admin credentials from secret
  existingSecret:
    enabled: true
    secretName: nextcloud-admin
    usernameKey: username
    passwordKey: password
  
  # Container configuration
  containerPort: 9000
  datadir: /var/www/html/data
  
  # Trusted domains
  trustedDomains:
    - ${HOSTNAME}
    - localhost
  
  # ─────────────────────────────────────────────────────────────────────────
  # S3 Object Storage (MinIO)
  # ─────────────────────────────────────────────────────────────────────────
  objectStore:
    s3:
      enabled: true
      bucket: nextcloud
      host: minio
      port: "9000"
      ssl: false
      region: ""
      usePathStyle: true
      autoCreate: true
      legacyAuth: false
      # Reference MinIO credentials from secret
      existingSecret: minio-secret
      secretKeys:
        accessKey: root-user
        secretKey: root-password
  
  # ─────────────────────────────────────────────────────────────────────────
  # Security Context (OpenShift Restricted SCC)
  # ─────────────────────────────────────────────────────────────────────────
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    readOnlyRootFilesystem: false
    capabilities:
      drop: ["ALL"]
    seccompProfile:
      type: RuntimeDefault
  
  # ─────────────────────────────────────────────────────────────────────────
  # Environment Variables
  # ─────────────────────────────────────────────────────────────────────────
  extraEnv:
    - name: TRUSTED_PROXIES
      value: "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
    - name: OVERWRITEPROTOCOL
      value: "https"
    - name: NC_default_phone_region
      value: "US"
    - name: PHP_MEMORY_LIMIT
      value: "512M"
    - name: PHP_UPLOAD_LIMIT
      value: "10G"
  
  # ─────────────────────────────────────────────────────────────────────────
  # Additional Config Files
  # ─────────────────────────────────────────────────────────────────────────
  configs:
    proxy.config.php: |-
      <?php
      \$CONFIG = array (
        'trusted_proxies' => ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
        'overwriteprotocol' => 'https',
        'overwrite.cli.url' => 'https://${HOSTNAME}',
        'default_phone_region' => 'US',
      );
  
  # ─────────────────────────────────────────────────────────────────────────
  # Extra Volumes (OpenShift non-root compatibility)
  # ─────────────────────────────────────────────────────────────────────────
  extraVolumes:
    - name: php-conf
      emptyDir: {}
  
  extraVolumeMounts:
    - name: php-conf
      mountPath: /usr/local/etc/php/conf.d
  
  # Copy original PHP configs before emptyDir overwrites them
  extraInitContainers:
    - name: copy-php-config
      image: docker.io/library/nextcloud:32-fpm
      command:
        - sh
        - -c
        - cp -a /usr/local/etc/php/conf.d/. /php-conf/
      volumeMounts:
        - name: php-conf
          mountPath: /php-conf
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault

# ─────────────────────────────────────────────────────────────────────────────
# Database Configuration
# ─────────────────────────────────────────────────────────────────────────────
internalDatabase:
  enabled: false

externalDatabase:
  enabled: true
  type: mysql
  host: mariadb
  database: nextcloud
  existingSecret:
    enabled: true
    secretName: mariadb-secret
    usernameKey: database-user
    passwordKey: database-password

# Disable bundled databases
mariadb:
  enabled: false
postgresql:
  enabled: false

# ─────────────────────────────────────────────────────────────────────────────
# Redis Configuration
# ─────────────────────────────────────────────────────────────────────────────
externalRedis:
  enabled: true
  host: redis
  port: "6379"
  existingSecret:
    enabled: true
    secretName: redis-secret
    passwordKey: database-password

# Disable bundled Redis
redis:
  enabled: false

# ─────────────────────────────────────────────────────────────────────────────
# Persistence
# ─────────────────────────────────────────────────────────────────────────────
persistence:
  enabled: true
  storageClass: "${STORAGE_CLASS}"
  accessMode: ReadWriteOnce
  size: ${NEXTCLOUD_STORAGE}

# ─────────────────────────────────────────────────────────────────────────────
# Service
# ─────────────────────────────────────────────────────────────────────────────
service:
  type: ClusterIP
  port: 8080

# ─────────────────────────────────────────────────────────────────────────────
# Health Probes (target nginx on 8080, not PHP-FPM on 9000)
# ─────────────────────────────────────────────────────────────────────────────
livenessProbe:
  enabled: true
  port: 8080
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 10
  failureThreshold: 6
  successThreshold: 1

readinessProbe:
  enabled: true
  port: 8080
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 10
  failureThreshold: 6
  successThreshold: 1

startupProbe:
  enabled: true
  port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 30
  successThreshold: 1

# ─────────────────────────────────────────────────────────────────────────────
# Resources
# ─────────────────────────────────────────────────────────────────────────────
resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi

# ─────────────────────────────────────────────────────────────────────────────
# Cron Job
# ─────────────────────────────────────────────────────────────────────────────
cronjob:
  enabled: true
  type: sidecar

# ─────────────────────────────────────────────────────────────────────────────
# RBAC
# ─────────────────────────────────────────────────────────────────────────────
rbac:
  enabled: false
EOF

echo -e "${GREEN}✓ Values file created${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Deploy Nextcloud
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}  Installing Nextcloud via Helm...${NC}"

helm install ${RELEASE_NAME} nextcloud/nextcloud \
  --values /tmp/nextcloud-values.yaml \
  --timeout 10m \
  --wait

echo -e "${GREEN}✓ Helm release installed${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Create Route
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}  Creating OpenShift route...${NC}"

oc create route edge ${RELEASE_NAME} \
  --service=${RELEASE_NAME} \
  --port=8080 \
  --insecure-policy=Redirect \
  --hostname=${HOSTNAME} 2>/dev/null || \
oc patch route ${RELEASE_NAME} -p "{\"spec\":{\"host\":\"${HOSTNAME}\"}}" 2>/dev/null || true

# Set route timeout for large uploads
oc annotate route ${RELEASE_NAME} \
  haproxy.router.openshift.io/timeout=3600s \
  --overwrite

echo -e "${GREEN}✓ Route created${NC}"

# ═══════════════════════════════════════════════════════════════════════════════
# POST-INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}▸ Waiting for Nextcloud initialization...${NC}"
echo "  This may take 2-5 minutes on first deployment..."

# Wait for pod to be ready
sleep 30
oc rollout status deployment/${RELEASE_NAME}-nextcloud --timeout=300s || true

# Wait for Nextcloud to initialize
for i in {1..30}; do
    STATUS=$(oc exec deployment/${RELEASE_NAME}-nextcloud -c nextcloud -- \
        php occ status --output=json 2>/dev/null | grep -o '"installed":true' || echo "")
    if [ -n "${STATUS}" ]; then
        echo -e "${GREEN}✓ Nextcloud initialized${NC}"
        break
    fi
    echo "  Initializing... ($i/30)"
    sleep 10
done

# Configure trusted domains
echo -e "${YELLOW}  Configuring trusted domains...${NC}"
oc exec deployment/${RELEASE_NAME}-nextcloud -c nextcloud -- \
    php occ config:system:set trusted_domains 0 --value="${HOSTNAME}" 2>/dev/null || true
oc exec deployment/${RELEASE_NAME}-nextcloud -c nextcloud -- \
    php occ config:system:set trusted_domains 1 --value="localhost" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    DEPLOYMENT COMPLETE                                ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Access URL:${NC}"
echo -e "  https://${HOSTNAME}"
echo ""
echo -e "${CYAN}Admin Credentials:${NC}"
echo -e "  Username: ${GREEN}admin${NC}"
echo -e "  Password: ${GREEN}${ADMIN_PASSWORD}${NC}"
echo ""
echo -e "${CYAN}Components:${NC}"
echo -e "  • Nextcloud:  deployment/${RELEASE_NAME}-nextcloud"
echo -e "  • MinIO:      deployment/minio (S3 storage)"
echo -e "  • MariaDB:    deployment/mariadb (database)"
echo -e "  • Redis:      deployment/redis (cache)"
echo ""
echo -e "${CYAN}Useful Commands:${NC}"
echo -e "  # Check status"
echo -e "  oc get pods"
echo ""
echo -e "  # View Nextcloud logs"
echo -e "  oc logs deployment/${RELEASE_NAME}-nextcloud -c nextcloud -f"
echo ""
echo -e "  # Run Nextcloud occ commands"
echo -e "  oc exec deployment/${RELEASE_NAME}-nextcloud -c nextcloud -- php occ <command>"
echo ""
echo -e "  # Access MinIO console"
echo -e "  oc port-forward deployment/minio 9001:9001"
echo -e "  # Then open: http://localhost:9001"
echo -e "  # Login: ${MINIO_ROOT_USER} / ${MINIO_ROOT_PASSWORD}"
echo ""
echo -e "${CYAN}Values File:${NC}"
echo -e "  /tmp/nextcloud-values.yaml"
echo ""
echo -e "${YELLOW}Note:${NC} Save your credentials! They won't be shown again."
echo ""
EOF

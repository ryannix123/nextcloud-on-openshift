#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Nextcloud Custom Container - Build and Deploy for OpenShift
# ═══════════════════════════════════════════════════════════════════════════════
#
# Usage:
#   # Build and push (requires podman/docker login to registry)
#   ./deploy-nextcloud-custom.sh build quay.io/yourusername/nextcloud-openshift
#
#   # Deploy to OpenShift
#   ./deploy-nextcloud-custom.sh deploy quay.io/yourusername/nextcloud-openshift nextcloud.apps.example.com
#
#   # Full workflow
#   ./deploy-nextcloud-custom.sh all quay.io/yourusername/nextcloud-openshift nextcloud.apps.example.com
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:-help}"
IMAGE="${2:-}"
HOSTNAME="${3:-}"
STORAGE_CLASS="${4:-gp3}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}Nextcloud Custom Container for OpenShift${NC}"
    echo ""
    echo "Usage:"
    echo "  $0 build <image-url>                    Build and push container"
    echo "  $0 deploy <image-url> <hostname>        Deploy to OpenShift"
    echo "  $0 all <image-url> <hostname>           Build and deploy"
    echo "  $0 cleanup                              Remove all resources"
    echo ""
    echo "Examples:"
    echo "  $0 build quay.io/myuser/nextcloud-ocp"
    echo "  $0 deploy quay.io/myuser/nextcloud-ocp nextcloud.apps.cluster.com"
    echo ""
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────
build_container() {
    echo -e "${CYAN}Building Nextcloud container...${NC}"
    
    if [ -z "$IMAGE" ]; then
        echo -e "${RED}Error: Image URL required${NC}"
        exit 1
    fi
    
    cd "$SCRIPT_DIR"
    
    # Check for required files
    for file in Containerfile nginx.conf supervisord.conf entrypoint.sh; do
        if [ ! -f "$file" ]; then
            echo -e "${RED}Error: Missing $file${NC}"
            exit 1
        fi
    done
    
    # Build
    echo -e "${YELLOW}Building image (linux/amd64)...${NC}"
    # If IMAGE doesn't contain a tag, add :latest
    if [[ "$IMAGE" != *":"* ]]; then
        IMAGE="${IMAGE}:latest"
    fi
    podman build --platform linux/amd64 -t "${IMAGE}" -f Containerfile .
    
    # Push
    echo -e "${YELLOW}Pushing to registry...${NC}"
    podman push "${IMAGE}"
    
    echo -e "${GREEN}✓ Image pushed to ${IMAGE}${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Deploy
# ─────────────────────────────────────────────────────────────────────────────
deploy_to_openshift() {
    echo -e "${CYAN}Deploying Nextcloud to OpenShift...${NC}"
    
    if [ -z "$IMAGE" ] || [ -z "$HOSTNAME" ]; then
        echo -e "${RED}Error: Image URL and hostname required${NC}"
        exit 1
    fi
    
    # Check prerequisites
    command -v oc >/dev/null 2>&1 || { echo -e "${RED}Error: oc CLI not found${NC}"; exit 1; }
    oc whoami &>/dev/null || { echo -e "${RED}Error: Not logged into OpenShift${NC}"; exit 1; }
    
    NAMESPACE=$(oc project -q)
    echo -e "Namespace: ${GREEN}${NAMESPACE}${NC}"
    echo -e "Hostname: ${GREEN}${HOSTNAME}${NC}"
    echo -e "Image: ${GREEN}${IMAGE}${NC}"
    
    # Generate credentials
    ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
    MARIADB_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
    MARIADB_ROOT_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/')
    REDIS_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
    MINIO_ROOT_USER="minioadmin"
    MINIO_ROOT_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/')
    
    # ─────────────────────────────────────────────────────────────────────────
    # Cleanup
    # ─────────────────────────────────────────────────────────────────────────
    echo -e "${YELLOW}Cleaning up existing resources...${NC}"
    oc delete deployment nextcloud minio mariadb redis --ignore-not-found 2>/dev/null || true
    oc delete service nextcloud minio mariadb redis --ignore-not-found 2>/dev/null || true
    oc delete secret nextcloud-secret minio-secret mariadb-secret redis-secret --ignore-not-found 2>/dev/null || true
    oc delete route nextcloud --ignore-not-found 2>/dev/null || true
    oc delete configmap nextcloud-config --ignore-not-found 2>/dev/null || true
    sleep 3
    
    # ─────────────────────────────────────────────────────────────────────────
    # MinIO
    # ─────────────────────────────────────────────────────────────────────────
    echo -e "${BLUE}Deploying MinIO...${NC}"
    
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
type: Opaque
stringData:
  root-user: "${MINIO_ROOT_USER}"
  root-password: "${MINIO_ROOT_PASSWORD}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
spec:
  storageClassName: ${STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
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
          args: ["server", "/data", "--console-address", ":9001"]
          ports:
            - containerPort: 9000
            - containerPort: 9001
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
            requests: { memory: 256Mi, cpu: 100m }
            limits: { memory: 1Gi, cpu: 1000m }
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
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

    oc rollout status deployment/minio --timeout=180s
    
    # Create bucket
    echo -e "${YELLOW}Creating MinIO bucket...${NC}"
    sleep 10
    for i in {1..12}; do
        if oc exec deployment/minio -- mc alias set local http://localhost:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" &>/dev/null; then
            oc exec deployment/minio -- mc mb local/nextcloud --ignore-existing 2>/dev/null || true
            break
        fi
        sleep 5
    done
    
    # ─────────────────────────────────────────────────────────────────────────
    # MariaDB
    # ─────────────────────────────────────────────────────────────────────────
    echo -e "${BLUE}Deploying MariaDB...${NC}"
    
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-secret
type: Opaque
stringData:
  database-user: nextcloud
  database-password: "${MARIADB_PASSWORD}"
  database-root-password: "${MARIADB_ROOT_PASSWORD}"
  database-name: nextcloud
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-pvc
spec:
  storageClassName: ${STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
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
            requests: { memory: 256Mi, cpu: 100m }
            limits: { memory: 1Gi, cpu: 1000m }
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: mariadb-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb
spec:
  selector:
    app: mariadb
  ports:
    - port: 3306
      targetPort: 3306
EOF

    oc rollout status deployment/mariadb --timeout=180s
    
    # ─────────────────────────────────────────────────────────────────────────
    # Redis
    # ─────────────────────────────────────────────────────────────────────────
    echo -e "${BLUE}Deploying Redis...${NC}"
    
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: redis-secret
type: Opaque
stringData:
  password: "${REDIS_PASSWORD}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
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
          command: ["redis-server", "--requirepass", "\$(REDIS_PASSWORD)"]
          ports:
            - containerPort: 6379
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-secret
                  key: password
          resources:
            requests: { memory: 64Mi, cpu: 50m }
            limits: { memory: 256Mi, cpu: 500m }
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
EOF

    oc rollout status deployment/redis --timeout=120s
    
    # ─────────────────────────────────────────────────────────────────────────
    # Nextcloud
    # ─────────────────────────────────────────────────────────────────────────
    echo -e "${BLUE}Deploying Nextcloud...${NC}"
    
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-secret
type: Opaque
stringData:
  admin-user: admin
  admin-password: "${ADMIN_PASSWORD}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nextcloud
  labels:
    app: nextcloud
    app.kubernetes.io/part-of: nextcloud
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nextcloud
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: nextcloud
    spec:
      containers:
        - name: nextcloud
          image: ${IMAGE}
          ports:
            - containerPort: 8080
          env:
            # Database
            - name: NC_MYSQL_HOST
              value: mariadb
            - name: NC_MYSQL_PORT
              value: "3306"
            - name: NC_MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database-name
            - name: NC_MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database-user
            - name: NC_MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database-password
            # Redis
            - name: NC_REDIS_HOST
              value: redis
            - name: NC_REDIS_PORT
              value: "6379"
            - name: NC_REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-secret
                  key: password
            # S3
            - name: S3_HOST
              value: minio
            - name: S3_PORT
              value: "9000"
            - name: S3_BUCKET
              value: nextcloud
            - name: S3_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: root-user
            - name: S3_SECRET
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: root-password
            - name: S3_SSL
              value: "false"
            - name: S3_PATH_STYLE
              value: "true"
            # Admin
            - name: NEXTCLOUD_ADMIN_USER
              valueFrom:
                secretKeyRef:
                  name: nextcloud-secret
                  key: admin-user
            - name: NEXTCLOUD_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: nextcloud-secret
                  key: admin-password
            - name: NEXTCLOUD_TRUSTED_DOMAINS
              value: "${HOSTNAME},localhost"
          volumeMounts:
            - name: config
              mountPath: /var/www/html/config
            - name: custom-apps
              mountPath: /var/www/html/custom_apps
          resources:
            requests: { memory: 512Mi, cpu: 200m }
            limits: { memory: 2Gi, cpu: 2000m }
          livenessProbe:
            httpGet:
              path: /status.php
              port: 8080
            initialDelaySeconds: 120
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /status.php
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: config
          emptyDir: {}
        - name: custom-apps
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: nextcloud
spec:
  selector:
    app: nextcloud
  ports:
    - port: 8080
      targetPort: 8080
EOF

    echo -e "${YELLOW}Waiting for Nextcloud to start (this takes 2-5 minutes)...${NC}"
    oc rollout status deployment/nextcloud --timeout=600s || true
    
    # ─────────────────────────────────────────────────────────────────────────
    # Route
    # ─────────────────────────────────────────────────────────────────────────
    echo -e "${BLUE}Creating route...${NC}"
    oc create route edge nextcloud \
        --service=nextcloud \
        --port=8080 \
        --insecure-policy=Redirect \
        --hostname="${HOSTNAME}" 2>/dev/null || true
    
    oc annotate route nextcloud haproxy.router.openshift.io/timeout=3600s --overwrite
    
    # ─────────────────────────────────────────────────────────────────────────
    # Summary
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    DEPLOYMENT COMPLETE                                ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Access URL:${NC} https://${HOSTNAME}"
    echo ""
    echo -e "${CYAN}Admin Credentials:${NC}"
    echo -e "  Username: ${GREEN}admin${NC}"
    echo -e "  Password: ${GREEN}${ADMIN_PASSWORD}${NC}"
    echo ""
    echo -e "${CYAN}MinIO Console:${NC}"
    echo -e "  oc port-forward deployment/minio 9001:9001"
    echo -e "  http://localhost:9001"
    echo -e "  User: ${MINIO_ROOT_USER}"
    echo -e "  Pass: ${MINIO_ROOT_PASSWORD}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────
cleanup() {
    echo -e "${YELLOW}Cleaning up all Nextcloud resources...${NC}"
    oc delete deployment nextcloud minio mariadb redis --ignore-not-found
    oc delete service nextcloud minio mariadb redis --ignore-not-found
    oc delete secret nextcloud-secret minio-secret mariadb-secret redis-secret --ignore-not-found
    oc delete pvc minio-pvc mariadb-pvc --ignore-not-found
    oc delete route nextcloud --ignore-not-found
    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
case "$COMMAND" in
    build)
        build_container
        ;;
    deploy)
        deploy_to_openshift
        ;;
    all)
        build_container
        deploy_to_openshift
        ;;
    cleanup)
        cleanup
        ;;
    *)
        show_help
        ;;
esac

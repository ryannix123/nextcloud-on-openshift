#!/bin/bash
# Simplified Nextcloud Deployment for OpenShift
# Uses PVC storage instead of S3, single replica, no scaling
set -e

# Configuration
IMAGE="${1:-quay.io/ryan_nix/nextcloud-openshift:latest}"
ROUTE_HOST="${2:-}"
NAMESPACE="${3:-$(oc project -q)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
    echo "Usage: $0 <image> [route-host] [namespace]"
    echo ""
    echo "Commands:"
    echo "  $0 deploy <image> <route-host>  - Deploy Nextcloud"
    echo "  $0 cleanup                       - Remove all resources"
    echo ""
    echo "Example:"
    echo "  $0 deploy quay.io/ryan_nix/nextcloud-openshift:latest nextcloud.apps.example.com"
    exit 1
}

generate_password() {
    openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 20
}

post_deploy_config() {
    local ROUTE_HOST="$1"
    
    log "Running post-deployment configuration..."
    
    # Wait a bit for Nextcloud to fully initialize
    log "Waiting for Nextcloud to fully initialize (30s)..."
    sleep 30
    
    # Get the pod name
    POD=$(oc get pods -l app=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$POD" ]; then
        warn "Could not find Nextcloud pod, skipping post-deploy config"
        return
    fi
    
    log "Configuring Nextcloud on pod: $POD"
    
    # ─────────────────────────────────────────────────────────────────────────
    # Fix warnings
    # ─────────────────────────────────────────────────────────────────────────
    
    log "Removing lost+found from custom_apps (if exists)..."
    oc exec "$POD" -- rm -rf /var/www/html/custom_apps/lost+found 2>/dev/null || true
    
    log "Adding missing database indices..."
    oc exec "$POD" -- php /var/www/html/occ db:add-missing-indices -n 2>/dev/null || warn "Could not add indices (may already exist)"
    
    log "Running mimetype migrations..."
    oc exec "$POD" -- php /var/www/html/occ maintenance:repair --include-expensive -n 2>/dev/null || warn "Mimetype repair had issues"
    
    log "Rescanning files for integrity..."
    oc exec "$POD" -- php /var/www/html/occ integrity:check-core 2>/dev/null || true
    
    # ─────────────────────────────────────────────────────────────────────────
    # Install Nextcloud Office (Collabora)
    # ─────────────────────────────────────────────────────────────────────────
    
    log "Installing Nextcloud Office (richdocuments)..."
    oc exec "$POD" -- php /var/www/html/occ app:install richdocuments 2>/dev/null || warn "richdocuments may already be installed"
    
    log "Installing Collabora CODE server (richdocumentscode)..."
    oc exec "$POD" -- php /var/www/html/occ app:install richdocumentscode 2>/dev/null || warn "richdocumentscode may already be installed"
    
    # Enable the apps (in case they were disabled)
    oc exec "$POD" -- php /var/www/html/occ app:enable richdocuments 2>/dev/null || true
    oc exec "$POD" -- php /var/www/html/occ app:enable richdocumentscode 2>/dev/null || true
    
    log "Configuring WOPI URLs for Collabora..."
    oc exec "$POD" -- php /var/www/html/occ config:app:set richdocuments wopi_url \
        --value="https://${ROUTE_HOST}/custom_apps/richdocumentscode/proxy.php?req=" 2>/dev/null || warn "Could not set wopi_url"
    
    oc exec "$POD" -- php /var/www/html/occ config:app:set richdocuments public_wopi_url \
        --value="https://${ROUTE_HOST}" 2>/dev/null || warn "Could not set public_wopi_url"
    
    # ─────────────────────────────────────────────────────────────────────────
    # Final verification
    # ─────────────────────────────────────────────────────────────────────────
    
    log "Verifying Nextcloud Office configuration..."
    oc exec "$POD" -- php /var/www/html/occ richdocuments:activate-config 2>/dev/null || warn "Could not verify richdocuments config"
    
    log "Post-deployment configuration complete!"
}

deploy() {
    local IMAGE="$1"
    local ROUTE_HOST="$2"
    
    [[ -z "$IMAGE" ]] && error "Image is required"
    [[ -z "$ROUTE_HOST" ]] && error "Route host is required"
    
    log "Deploying simplified Nextcloud to namespace: $NAMESPACE"
    log "Image: $IMAGE"
    log "Route: $ROUTE_HOST"
    
    # Generate passwords
    MYSQL_ROOT_PW=$(generate_password)
    MYSQL_PW=$(generate_password)
    REDIS_PW=$(generate_password)
    ADMIN_PW=$(generate_password)
    
    log "Creating secrets..."
    
    # MariaDB Secret
    oc create secret generic mariadb-secret \
        --from-literal=root-password="$MYSQL_ROOT_PW" \
        --from-literal=database=nextcloud \
        --from-literal=username=nextcloud \
        --from-literal=password="$MYSQL_PW" \
        --dry-run=client -o yaml | oc apply -f -
    
    # Redis Secret
    oc create secret generic redis-secret \
        --from-literal=password="$REDIS_PW" \
        --dry-run=client -o yaml | oc apply -f -
    
    # Nextcloud Secret
    oc create secret generic nextcloud-secret \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="$ADMIN_PW" \
        --dry-run=client -o yaml | oc apply -f -
    
    log "Creating PVCs..."
    
    cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-data-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-apps-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-config-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Mi
EOF
    
    log "Deploying MariaDB..."
    
    cat <<EOF | oc apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: mariadb
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
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: root-password
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: username
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: password
          volumeMounts:
            - name: mariadb-data
              mountPath: /var/lib/mysql/data
          resources:
            requests: { memory: 256Mi, cpu: 100m }
            limits: { memory: 1Gi, cpu: 1000m }
          livenessProbe:
            exec:
              command: ["sh", "-c", "mysqladmin ping -u root -p\${MYSQL_ROOT_PASSWORD}"]
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["sh", "-c", "mysqladmin ping -u root -p\${MYSQL_ROOT_PASSWORD}"]
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: mariadb-data
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
    
    log "Deploying Redis..."
    
    cat <<EOF | oc apply -f -
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
          command: ["redis-server", "--requirepass", "\$(REDIS_PASSWORD)", "--save", "", "--appendonly", "no", "--stop-writes-on-bgsave-error", "no"]
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
    
    log "Waiting for MariaDB to be ready..."
    oc wait --for=condition=available deployment/mariadb --timeout=120s || warn "MariaDB taking longer than expected"
    
    log "Deploying Nextcloud..."
    
    cat <<EOF | oc apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nextcloud
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nextcloud
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
              value: "mariadb"
            - name: NC_MYSQL_PORT
              value: "3306"
            - name: NC_MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: database
            - name: NC_MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: username
            - name: NC_MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-secret
                  key: password
            # Redis
            - name: NC_REDIS_HOST
              value: "redis"
            - name: NC_REDIS_PORT
              value: "6379"
            - name: NC_REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-secret
                  key: password
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
            # Trusted domains
            - name: NEXTCLOUD_TRUSTED_DOMAINS
              value: "${ROUTE_HOST} localhost"
            # Disable S3
            - name: NC_S3_ENABLED
              value: "false"
          volumeMounts:
            - name: nextcloud-data
              mountPath: /var/www/html/data
            - name: nextcloud-config
              mountPath: /var/www/html/config
            - name: nextcloud-apps
              mountPath: /var/www/html/custom_apps
          resources:
            requests: { memory: 256Mi, cpu: 100m }
            limits: { memory: 1Gi, cpu: 1000m }
          readinessProbe:
            httpGet:
              path: /status.php
              port: 8080
              httpHeaders:
                - name: Host
                  value: localhost
            initialDelaySeconds: 60
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 30
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: nextcloud-data
          persistentVolumeClaim:
            claimName: nextcloud-data-pvc
        - name: nextcloud-config
          persistentVolumeClaim:
            claimName: nextcloud-config-pvc
        - name: nextcloud-apps
          persistentVolumeClaim:
            claimName: nextcloud-apps-pvc
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
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: nextcloud
  annotations:
    haproxy.router.openshift.io/timeout: 3600s
spec:
  host: ${ROUTE_HOST}
  to:
    kind: Service
    name: nextcloud
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
    
    log "Waiting for Nextcloud to be ready..."
    oc wait --for=condition=available deployment/nextcloud --timeout=300s || warn "Nextcloud taking longer than expected"
    
    # Run post-deployment configuration
    post_deploy_config "$ROUTE_HOST"
    
    echo ""
    log "========================================="
    log "Deployment complete!"
    log "========================================="
    echo ""
    echo "URL: https://${ROUTE_HOST}"
    echo ""
    echo "Admin credentials:"
    echo "  Username: admin"
    echo "  Password: $ADMIN_PW"
    echo ""
    echo "Save these credentials - they won't be shown again!"
    echo ""
}

cleanup() {
    log "Cleaning up Nextcloud deployment..."
    
    oc delete deployment nextcloud mariadb redis --ignore-not-found
    oc delete service nextcloud mariadb redis --ignore-not-found
    oc delete route nextcloud --ignore-not-found
    oc delete secret nextcloud-secret mariadb-secret redis-secret --ignore-not-found
    
    warn "PVCs are NOT deleted automatically. To delete them:"
    echo "  oc delete pvc mariadb-pvc nextcloud-data-pvc nextcloud-apps-pvc nextcloud-config-pvc"
    
    log "Cleanup complete!"
}

# Main
case "${1:-}" in
    deploy)
        deploy "$2" "$3"
        ;;
    cleanup)
        cleanup
        ;;
    *)
        usage
        ;;
esac

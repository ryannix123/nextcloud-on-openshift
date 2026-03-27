#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Nextcloud Deployment for OpenShift
# Just run: sh deploy.sh
# Auto-generates route hostname from cluster's ingress domain
# ═══════════════════════════════════════════════════════════════════════════════
set -e

# Configuration
IMAGE="${NEXTCLOUD_IMAGE:-quay.io/ryan_nix/nextcloud-openshift:latest}"
NAMESPACE="${NAMESPACE:-$(oc project -q)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[    ]${NC} $1"; }

generate_password() {
    openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 20
}

get_cluster_domain() {
    # Try to get the default ingress domain from the cluster
    local domain=""
    
    # Method 1: Get from existing route (most reliable in Developer Sandbox)
    domain=$(oc get routes -A -o jsonpath='{.items[0].spec.host}' 2>/dev/null | sed 's/^[^.]*\.//')
    
    # Method 2: Try ingress config (requires cluster-reader)
    if [ -z "$domain" ]; then
        domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
    fi
    
    # Method 3: Parse from console URL
    if [ -z "$domain" ]; then
        domain=$(oc whoami --show-console 2>/dev/null | sed 's|https://console-openshift-console\.||')
    fi
    
    echo "$domain"
}

post_deploy_config() {
    local ROUTE_HOST="$1"
    
    log "Running post-deployment configuration..."
    
    log "Waiting for Nextcloud to fully initialize (30s)..."
    sleep 30
    
    POD=$(oc get pods -l app=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$POD" ]; then
        warn "Could not find Nextcloud pod, skipping post-deploy config"
        return
    fi
    
    log "Configuring Nextcloud on pod: $POD"
    
    log "Removing lost+found from custom_apps..."
    oc exec "$POD" -- rm -rf /var/www/html/custom_apps/lost+found 2>/dev/null || true
    
    log "Adding missing database indices..."
    oc exec "$POD" -- php /var/www/html/occ db:add-missing-indices -n 2>/dev/null || warn "Could not add indices"
    
    log "Running mimetype migrations..."
    oc exec "$POD" -- php /var/www/html/occ maintenance:repair --include-expensive -n 2>/dev/null || warn "Repair had issues"
    
    log "Installing Nextcloud Office (richdocuments)..."
    oc exec "$POD" -- php /var/www/html/occ app:install richdocuments 2>/dev/null || true
    oc exec "$POD" -- php /var/www/html/occ app:install richdocumentscode 2>/dev/null || true
    oc exec "$POD" -- php /var/www/html/occ app:enable richdocuments 2>/dev/null || true
    oc exec "$POD" -- php /var/www/html/occ app:enable richdocumentscode 2>/dev/null || true
    
    log "Configuring WOPI URLs for Collabora..."
    oc exec "$POD" -- php /var/www/html/occ config:app:set richdocuments wopi_url \
        --value="https://${ROUTE_HOST}/custom_apps/richdocumentscode/proxy.php?req=" 2>/dev/null || true
    oc exec "$POD" -- php /var/www/html/occ config:app:set richdocuments public_wopi_url \
        --value="https://${ROUTE_HOST}" 2>/dev/null || true
    
    sleep 10
    
    if oc exec "$POD" -- php /var/www/html/occ richdocuments:activate-config 2>/dev/null; then
        log "✓ Nextcloud Office verified and ready!"
    else
        warn "CODE server still initializing - document editing available in 1-2 minutes"
    fi
    
    log "Post-deployment configuration complete!"
}

deploy() {
    log "═══════════════════════════════════════════════════════════════"
    log "  Nextcloud on OpenShift - Automated Deployment"
    log "═══════════════════════════════════════════════════════════════"
    echo ""
    
    # Get cluster domain and generate route
    log "Detecting cluster ingress domain..."
    CLUSTER_DOMAIN=$(get_cluster_domain)
    
    if [ -z "$CLUSTER_DOMAIN" ]; then
        error "Could not detect cluster domain. Set ROUTE_HOST environment variable manually."
    fi
    
    ROUTE_HOST="${ROUTE_HOST:-nextcloud-${NAMESPACE}.${CLUSTER_DOMAIN}}"
    
    log "Namespace: $NAMESPACE"
    log "Image: $IMAGE"
    log "Route: $ROUTE_HOST"
    echo ""
    
    # Generate passwords
    MYSQL_ROOT_PW=$(generate_password)
    MYSQL_PW=$(generate_password)
    REDIS_PW=$(generate_password)
    ADMIN_PW=$(generate_password)
    
    log "Creating secrets..."
    
    oc create secret generic mariadb-secret \
        --from-literal=root-password="$MYSQL_ROOT_PW" \
        --from-literal=database=nextcloud \
        --from-literal=username=nextcloud \
        --from-literal=password="$MYSQL_PW" \
        --dry-run=client -o yaml | oc apply -f -
    
    oc create secret generic redis-secret \
        --from-literal=password="$REDIS_PW" \
        --dry-run=client -o yaml | oc apply -f -
    
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
    
    log "Deploying MariaDB 11.8..."
    
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
          image: quay.io/fedora/mariadb-118
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
    
    log "Deploying Redis 8..."
    
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
          image: docker.io/redis:8-alpine
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
            - name: NC_REDIS_HOST
              value: "redis"
            - name: NC_REDIS_PORT
              value: "6379"
            - name: NC_REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-secret
                  key: password
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
              value: "${ROUTE_HOST} localhost"
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
    log "═══════════════════════════════════════════════════════════════"
    log "  ✓ Deployment Complete!"
    log "═══════════════════════════════════════════════════════════════"
    echo ""
    info "URL: https://${ROUTE_HOST}"
    echo ""
    info "Admin credentials:"
    info "  Username: admin"
    info "  Password: $ADMIN_PW"
    echo ""
    warn "Save these credentials - they won't be shown again!"
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

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════
case "${1:-}" in
    cleanup)
        cleanup
        ;;
    -h|--help|help)
        echo "Nextcloud on OpenShift - Deployment Script"
        echo ""
        echo "Usage:"
        echo "  sh deploy.sh           Deploy Nextcloud (auto-generates route)"
        echo "  sh deploy.sh cleanup   Remove all resources"
        echo ""
        echo "Environment variables:"
        echo "  NEXTCLOUD_IMAGE  Container image (default: quay.io/ryan_nix/nextcloud-openshift:latest)"
        echo "  ROUTE_HOST       Custom route hostname (default: auto-generated)"
        echo "  NAMESPACE        Target namespace (default: current project)"
        echo ""
        echo "Examples:"
        echo "  sh deploy.sh"
        echo "  ROUTE_HOST=nextcloud.example.com sh deploy.sh"
        echo "  sh deploy.sh cleanup"
        ;;
    *)
        deploy
        ;;
esac

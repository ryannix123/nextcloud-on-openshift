#!/bin/bash
# OpenShift Nextcloud Deployment Script with PostgreSQL and Redis

set -e

# Configuration
PROJECT_NAME="nextcloud"
DATABASE_NAME="postgresql"
DOMAIN="nextcloud.example.com"

# Create new project
echo "Creating OpenShift project..."
oc new-project ${PROJECT_NAME} || oc project ${PROJECT_NAME}

# Deploy PostgreSQL database
echo "Deploying PostgreSQL database..."
oc new-app postgresql:15-alpine \
  --name=${DATABASE_NAME} \
  -e POSTGRESQL_DATABASE=nextcloud \
  -e POSTGRESQL_USER=nextcloud \
  -e POSTGRESQL_PASSWORD=nextcloudpassword \
  -e POSTGRESQL_ADMIN_PASSWORD=postgrespassword

# Create persistent volume claims for PostgreSQL
oc create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
EOF

# Attach PVC to PostgreSQL deployment
oc set volume deployment/${DATABASE_NAME} --add \
  --type=persistentVolumeClaim \
  --claim-name=postgresql-data-pvc \
  --mount-path=/var/lib/postgresql/data

# Create secrets for Nextcloud
echo "Creating secrets..."
oc create secret generic nextcloud-db-secret \
  --from-literal=username=nextcloud \
  --from-literal=password=nextcloudpassword

oc create secret generic nextcloud-admin-secret \
  --from-literal=username=admin \
  --from-literal=password=NextcloudAdmin123!

# Create BuildConfig and ImageStream
echo "Creating build configuration..."
oc apply -f openshift-buildconfig.yaml

# Build the Nextcloud image
echo "Starting build..."
oc start-build nextcloud-builder --wait

# Update deployment with actual image tag
echo "Deploying Nextcloud..."
oc apply -f openshift-deployment.yaml

# Wait for deployments to be ready
echo "Waiting for deployments to be ready..."
oc rollout status deployment/postgresql
oc rollout status deployment/nextcloud

# Get the route
echo "Getting route..."
ROUTE=$(oc get route nextcloud -o jsonpath='{.spec.host}')
echo "Nextcloud is now available at: https://${ROUTE}"

# Show important information
echo ""
echo "Deployment Complete!"
echo "===================="
echo "Nextcloud URL: https://${ROUTE}"
echo "Admin Username: admin"
echo "Admin Password: (from nextcloud-admin-secret)"
echo ""
echo "Database Connection:"
echo "- Type: PostgreSQL"
echo "- Host: postgresql-service"
echo "- Database: nextcloud"
echo "- Username: nextcloud"
echo "- Password: (from nextcloud-db-secret)"
echo ""
echo "Redis Configuration:"
echo "- Running locally in the Nextcloud container"
echo "- Host: 127.0.0.1"
echo "- Port: 6379"
echo ""
echo "PHP Configuration:"
echo "- Version: PHP 8.3 (from Remi's repository)"
echo "- OPcache enabled"
echo "- APCu cache enabled"
echo "- Redis integration enabled"
echo ""
echo "To update the application:"
echo "oc rollout restart deployment/nextcloud"
echo ""
echo "To check logs:"
echo "oc logs -f deployment/nextcloud"
echo ""
echo "To access the database:"
echo "oc rsh deployment/postgresql"
echo "psql -U nextcloud -d nextcloud"
# Nextcloud on OpenShift with Restricted SCC

This configuration deploys the Nextcloud Helm chart on OpenShift using the **restricted** (or restricted-v2) Security Context Constraint, requiring no elevated privileges.

## Files Included

| File | Description |
|------|-------------|
| `nextcloud-openshift-values.yaml` | Helm values override for OpenShift compatibility |
| `nextcloud-openshift-route.yaml` | OpenShift Route and NetworkPolicy resources |
| `deploy-nextcloud.sh` | Automated deployment script |

## Key Modifications for OpenShift Restricted SCC

### 1. Security Context Changes

The restricted SCC enforces several constraints that the default Nextcloud chart doesn't accommodate:

```yaml
# Pod-level - let OpenShift assign UIDs
podSecurityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
  # NO runAsUser or fsGroup - OpenShift assigns from namespace range

# Container-level
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  capabilities:
    drop:
      - ALL
```

**Why no explicit UIDs?** OpenShift's restricted SCC uses `MustRunAsRange` which assigns UIDs from the namespace's `openshift.io/sa.scc.uid-range` annotation. Hardcoding UID 33 or 82 would cause pod admission failures.

### 2. Non-Privileged Ports

The standard Apache/nginx images bind to port 80, which requires root. This configuration:

- Uses the **FPM-Alpine** image (PHP-FPM on port 9000)
- Configures nginx sidecar on port **8080**
- Custom nginx.conf writes temp files to `/tmp` (writable by any user)

### 3. Image Selection

```yaml
image:
  flavor: fpm-alpine
nginx:
  enabled: true
```

The FPM variant separates PHP processing from web serving, making it easier to configure both to run as non-root.

### 4. File Permissions

OpenShift assigns a random UID, but the container's group membership includes the namespace's fsGroup. The Nextcloud image handles this via group-writable directories.

## Quick Start

### Prerequisites

- OpenShift 4.x cluster
- `oc` CLI logged in with appropriate permissions
- `helm` v3.x installed
- Cluster storage class configured (for PVCs)

### Automated Deployment

```bash
chmod +x deploy-nextcloud.sh
./deploy-nextcloud.sh <namespace> <hostname>

# Example:
./deploy-nextcloud.sh nextcloud nextcloud.apps.mycluster.example.com
```

### Manual Deployment

```bash
# Create namespace
oc new-project nextcloud

# Add Helm repo
helm repo add nextcloud https://nextcloud.github.io/helm/
helm repo update

# Update hostname in values file
sed -i 's/nextcloud.apps.example.com/YOUR_HOSTNAME/g' nextcloud-openshift-values.yaml

# Deploy
helm install nextcloud nextcloud/nextcloud \
    -f nextcloud-openshift-values.yaml \
    --set nextcloud.password=YourSecurePassword \
    --set postgresql.global.postgresql.auth.password=DBPassword \
    --set redis.auth.password=RedisPassword \
    --namespace nextcloud

# Create Route
oc apply -f nextcloud-openshift-route.yaml
```

## Verification

### Check SCC Assignment

```bash
# Should show "restricted" or "restricted-v2"
oc get pod -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'
```

### Check Pod UID

```bash
oc exec deploy/nextcloud -- id
# Output should show a high UID like: uid=1000680000 gid=0(root)
```

### Verify Service Connectivity

```bash
oc exec deploy/nextcloud -- curl -s localhost:8080/status.php
```

## Troubleshooting

### Pod Stuck in CreateContainerConfigError

Usually indicates SCC violation. Check:
```bash
oc describe pod <pod-name>
oc get events --field-selector reason=FailedCreate
```

### Permission Denied on PVC

If you see permission errors accessing persistent volumes:

1. Check the fsGroup:
```bash
oc get namespace nextcloud -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}'
```

2. Verify PVC access mode matches your storage class capabilities

3. Consider adding an init container to fix permissions (requires anyuid SCC)

### Nginx 403 Forbidden

Often caused by nginx temp directory permissions:
```bash
# Check nginx can write to temp
oc exec deploy/nextcloud -c nginx -- ls -la /tmp/
```

The custom nginx.conf in values.yaml configures temp paths in `/tmp/`.

### Database Connection Refused

```bash
# Check PostgreSQL pod
oc get pods -l app.kubernetes.io/name=postgresql
oc logs -l app.kubernetes.io/name=postgresql

# Test connectivity
oc exec deploy/nextcloud -- nc -zv nextcloud-postgresql 5432
```

## Alternative: Using anyuid SCC

If restricted SCC causes insurmountable issues, you can use anyuid:

```bash
# Create service account
oc create sa nextcloud-anyuid -n nextcloud

# Grant anyuid SCC
oc adm policy add-scc-to-user anyuid -z nextcloud-anyuid -n nextcloud

# Deploy with modified values
helm install nextcloud nextcloud/nextcloud \
    -f nextcloud-openshift-values.yaml \
    --set rbac.serviceaccount.create=false \
    --set rbac.serviceaccount.name=nextcloud-anyuid \
    --set nextcloud.podSecurityContext.runAsUser=33 \
    --set nextcloud.podSecurityContext.fsGroup=33 \
    --namespace nextcloud
```

**Note:** This is less secure and not recommended for production.

## Production Considerations

### 1. External Database

For production, use a managed PostgreSQL service or dedicated database cluster:

```yaml
postgresql:
  enabled: false
externalDatabase:
  enabled: true
  type: postgresql
  host: your-postgresql.example.com
  database: nextcloud
  existingSecret:
    enabled: true
    secretName: nextcloud-db-creds
```

### 2. Object Storage

For scalable file storage, configure S3-compatible backend:

```yaml
nextcloud:
  configs:
    s3.config.php: |-
      <?php
      $CONFIG = array (
        'objectstore' => array(
          'class' => '\\OC\\Files\\ObjectStore\\S3',
          'arguments' => array(
            'bucket' => 'nextcloud',
            'key' => getenv('S3_KEY'),
            'secret' => getenv('S3_SECRET'),
            'hostname' => 's3.example.com',
            'use_ssl' => true,
            'use_path_style' => true,
          ),
        ),
      );
```

### 3. Horizontal Scaling

Enable HPA for auto-scaling (requires shared storage like NFS or S3):

```yaml
hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 75
```

### 4. TLS/Certificates

For custom certificates, modify the Route:

```yaml
spec:
  tls:
    termination: edge
    certificate: |
      -----BEGIN CERTIFICATE-----
      ...
    key: |
      -----BEGIN RSA PRIVATE KEY-----
      ...
```

## Resource Requests

Adjust based on your workload:

```yaml
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi
```

## References

- [Nextcloud Helm Chart](https://github.com/nextcloud/helm)
- [OpenShift SCC Documentation](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
- [Nextcloud Admin Manual](https://docs.nextcloud.com/server/latest/admin_manual/)

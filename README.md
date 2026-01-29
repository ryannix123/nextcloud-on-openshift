<p align="center">
  <img src="https://nextcloud.com/c/uploads/2025/10/Nextcloud_01-standard-logo.svg" alt="Nextcloud Logo" width="400">
</p>

<h1 align="center">Nextcloud on OpenShift — Zero Privilege Deployment</h1>

<p align="center">
  <a href="https://www.redhat.com/en/technologies/cloud-computing/openshift"><img src="https://img.shields.io/badge/OpenShift-4.x-red?logo=redhatopenshift" alt="OpenShift"></a>
  <a href="https://nextcloud.com"><img src="https://img.shields.io/badge/Nextcloud-32.x-blue?logo=nextcloud" alt="Nextcloud"></a>
  <a href="https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html"><img src="https://img.shields.io/badge/SCC-restricted-brightgreen" alt="SCC"></a>
  <a href="https://mariadb.org"><img src="https://img.shields.io/badge/MariaDB-11-blue?logo=mariadb" alt="MariaDB"></a>
  <a href="https://www.php.net"><img src="https://img.shields.io/badge/PHP-8.x-777BB4?logo=php&logoColor=white" alt="PHP"></a>
  <a href="https://www.centos.org"><img src="https://img.shields.io/badge/CentOS-Stream%209-purple?logo=centos&logoColor=white" alt="CentOS"></a>
  <a href="https://quay.io"><img src="https://img.shields.io/badge/Quay.io-Container-red?logo=redhat&logoColor=white" alt="Quay.io"></a>
  <a href="https://github.com/ryannix123/nextcloud-on-openshift/actions/workflows/build-nextcloud.yml"><img src="https://github.com/ryannix123/nextcloud-on-openshift/actions/workflows/build-nextcloud.yml/badge.svg" alt="Build and Push Nextcloud"></a>
</p>

<p align="center">
  <strong>Deploy Nextcloud on OpenShift without ANY elevated privileges.</strong><br>
  No <code>anyuid</code>. No <code>privileged</code>. Just pure, security-hardened container goodness designed for multi-tenancy.
</p>

---

## 🆓 Red Hat Developer Sandbox

The [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) is a **free** OpenShift environment perfect for testing Nextcloud:

- **Free tier** — No credit card required
- **Generous resources** — 14 GB RAM, 40 GB storage, 3 CPU cores
- **Latest OpenShift** — Always running a recent version (4.18+)
- **Auto-hibernation** — Deployments scale to zero after 12 hours of inactivity

### Waking Up Your Deployment

When you return after the sandbox has hibernated, your pods will be scaled down. Run this command to bring everything back up:

```bash
# Scale all deployments back to 1 replica
oc scale deployment --all --replicas=1

# Or specify your namespace explicitly
oc scale deployment --all --replicas=1 -n $(oc project -q)
```

Your data persists in the PVCs — only the pods are stopped during hibernation.

---

## 🎯 Two Deployment Options

| Option | Best For | Document Editing | Complexity |
|--------|----------|------------------|------------|
| **[Custom Container](#option-1-custom-container-recommended)** | Production, simplicity | ✅ Collabora built-in | Simple |
| **[Helm Chart](#option-2-helm-chart)** | GitOps, existing Helm users | ⚠️ Manual setup | Moderate |

---

## Option 1: Custom Container (Recommended)

A purpose-built Nextcloud container optimized for OpenShift's restricted Security Context Constraints (SCC) with **Nextcloud Office (Collabora)** document editing included.

### ✨ Features

- ✅ CentOS Stream 9 + PHP 8.3 + nginx
- ✅ Runs as non-root (OpenShift restricted SCC compatible)
- ✅ **Nextcloud Office (Collabora) document editing** — edit docs, spreadsheets, presentations in-browser
- ✅ MariaDB + Redis for performance
- ✅ Persistent storage for data, config, and apps
- ✅ Automatic WOPI configuration for document editing
- ✅ Background cron jobs included

### 🚀 Quick Start

```bash
# Clone the repository
git clone https://github.com/ryannix123/nextcloud-on-openshift.git
cd nextcloud-on-openshift/custom-container

# Build and push the container image
podman build --platform linux/amd64 -t quay.io/YOUR_USERNAME/nextcloud-openshift:latest -f Containerfile .
podman push quay.io/YOUR_USERNAME/nextcloud-openshift:latest

# Deploy to OpenShift
./deploy-nextcloud-simple.sh deploy quay.io/YOUR_USERNAME/nextcloud-openshift:latest nextcloud.apps.your-cluster.com
```

The script outputs your admin credentials at the end — save them!

**Document editing is automatically enabled** — Nextcloud Office (Collabora) is installed and configured on first boot. You can start editing `.docx`, `.xlsx`, `.pptx`, `.odt`, and more right away!

### ⚠️ Collabora CODE Server Warnings

When running the built-in CODE server in OpenShift's restricted environment, you'll see these warnings in the Nextcloud Office admin settings:

| Warning | Cause | Impact |
|---------|-------|--------|
| Missing capabilities/namespaces | OpenShift restricted SCC doesn't allow namespace creation | Documents aren't sandboxed as securely |
| Slow Kit jail setup | Can't bind-mount in containers, must copy files | Slower document loading |
| Poorly performing proxying | All traffic goes through PHP proxy | Higher latency |

**These warnings are expected and can be safely ignored** for demo, personal, or small team use. The built-in CODE server is designed for "home use or small groups" — document editing works fine despite these warnings.

**For production deployments with many concurrent users**, consider deploying a dedicated Collabora Online server with its own pod and appropriate privileges for better performance.

### 🧹 Automatic Post-Installation Optimization

The entrypoint automatically handles common Nextcloud warnings on each startup:

- ✅ Removes `lost+found` directory from custom_apps (PVC filesystem artifact)
- ✅ Adds missing database indices for better performance  
- ✅ Runs mimetype migrations

**Note:** The "AppAPI deploy daemon" warning can be safely ignored — it's for running containerized external apps which require Docker socket access that OpenShift doesn't allow.

### 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      OpenShift Cluster                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                   Nextcloud Pod                       │   │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────────┐  │   │
│  │  │   nginx    │  │  PHP-FPM   │  │   Collabora    │  │   │
│  │  │  :8080     │─▶│   :9000    │  │   (CODE)       │  │   │
│  │  └────────────┘  └────────────┘  └────────────────┘  │   │
│  └──────────────────────────┬───────────────────────────┘   │
│                              │                               │
│  ┌───────────┐  ┌───────────┴───┐  ┌───────────┐            │
│  │  MariaDB  │  │  Redis Cache  │  │   PVCs    │            │
│  │   :3306   │  │    :6379      │  │ Data/Cfg  │            │
│  └───────────┘  └───────────────┘  └───────────┘            │
└─────────────────────────────────────────────────────────────┘
```

### 📁 Files

| File | Description |
|------|-------------|
| `Containerfile` | Container build definition (CentOS Stream 9 + PHP 8.3) |
| `entrypoint.sh` | Startup script with auto-configuration |
| `nginx.conf` | Web server configuration with .mjs MIME fix |
| `supervisord.conf` | Process manager for nginx + PHP-FPM + cron |
| `deploy-nextcloud-simple.sh` | OpenShift deployment script |

### ⚙️ Configuration

#### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NC_MYSQL_HOST` | mariadb | Database hostname |
| `NC_MYSQL_DATABASE` | nextcloud | Database name |
| `NC_REDIS_HOST` | redis | Redis hostname |
| `NEXTCLOUD_ADMIN_USER` | admin | Admin username |
| `NEXTCLOUD_TRUSTED_DOMAINS` | (required) | Space-separated trusted domains |

#### Persistent Volumes

| PVC | Size | Purpose |
|-----|------|---------|
| `nextcloud-data-pvc` | 20Gi | User files |
| `nextcloud-config-pvc` | 100Mi | Nextcloud configuration |
| `nextcloud-apps-pvc` | 1Gi | Custom/installed apps |
| `mariadb-pvc` | 5Gi | Database storage |

### 🔧 Management Commands

```bash
# View admin password
oc get secret nextcloud-secret -o jsonpath='{.data.admin-password}' | base64 -d

# Check Nextcloud status
oc exec deployment/nextcloud -- php /var/www/html/occ status

# Run maintenance
oc exec deployment/nextcloud -- php /var/www/html/occ maintenance:repair

# Add missing database indices
oc exec deployment/nextcloud -- php /var/www/html/occ db:add-missing-indices

# List installed apps
oc exec deployment/nextcloud -- php /var/www/html/occ app:list

# Check Collabora configuration
oc exec deployment/nextcloud -- php /var/www/html/occ richdocuments:activate-config

# Cleanup (keeps PVCs)
./deploy-nextcloud-simple.sh cleanup

# Full cleanup including data
./deploy-nextcloud-simple.sh cleanup
oc delete pvc mariadb-pvc nextcloud-data-pvc nextcloud-apps-pvc nextcloud-config-pvc
```

### 🐛 Troubleshooting

#### Document editing shows "Loading..." forever

Check the WOPI configuration:
```bash
oc exec deployment/nextcloud -- php /var/www/html/occ richdocuments:activate-config
```

The URLs should point to your external domain, not `localhost`.

#### JavaScript MIME type errors in browser console

Rebuild the container — the Containerfile includes a fix for `.mjs` files.

#### Pod CrashLoopBackOff

```bash
oc logs deployment/nextcloud
```

Common causes: database not ready (script waits 60s), PVC mount issues.

---

## Option 2: Helm Chart

Use the official Nextcloud Helm chart with OpenShift-specific modifications. Better for GitOps workflows or if you're already using Helm.

### 📋 Prerequisites

- Helm 3.x installed
- `oc` CLI logged in

### 🚀 Quick Start (Developer Sandbox)

```bash
# Clone the repo
git clone https://github.com/ryannix123/nextcloud-on-openshift.git
cd nextcloud-on-openshift

# Login to your sandbox
oc login --token=YOUR_TOKEN --server=https://api.sandbox.openshiftapps.com:6443

# Deploy!
./deploy-nextcloud-sandbox.sh
```

### 🚀 Full OpenShift Cluster

```bash
# Create namespace
oc new-project nextcloud

# Add Helm repo
helm repo add nextcloud https://nextcloud.github.io/helm/
helm repo update

# Deploy with custom values
helm install nextcloud nextcloud/nextcloud \
    -f openshift-values.yaml \
    --set nextcloud.host=nextcloud.apps.mycluster.example.com \
    --set nextcloud.password=$(openssl rand -base64 16) \
    -n nextcloud

# Create Route
oc apply -f route.yaml
```

### 🔧 What's Different About This Configuration?

The official Helm chart assumes you can run as specific UIDs and bind to port 80. OpenShift's restricted SCC blocks this.

| Challenge | Our Fix |
|-----------|---------|
| Fixed UID requirement | Let OpenShift assign from namespace range |
| Port 80 binding | Use FPM + nginx-unprivileged on port 8080 |
| Health probes on wrong port | Patch probes to target nginx (8080) |
| Trusted domain errors | Auto-configure via `php occ` |

### ⚠️ Limitations

- **No built-in Collabora** — requires separate deployment for document editing
- **Requires post-install patches** — health probes, trusted domains
- **More complex troubleshooting** — multiple containers and configurations

---

## 🔒 Security

Both deployment options run under OpenShift's most restrictive security policy:

| Security Feature | Status |
|------------------|--------|
| Runs as non-root | ✅ |
| Random UID from namespace range | ✅ |
| All capabilities dropped | ✅ |
| No privilege escalation | ✅ |
| Seccomp profile enforced | ✅ |
| Works on Developer Sandbox | ✅ |

Verify your deployment:

```bash
# Check SCC assignment (should show "restricted" or "restricted-v2")
oc get pod -l app=nextcloud -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'

# Verify non-root UID
oc exec deployment/nextcloud -- id
```

---

## 🛡️ Securing Access with IP Whitelisting

OpenShift makes it easy to restrict access to your Nextcloud instance by IP address using route annotations — no firewall rules or external load balancer configuration needed.

### Allow Only Specific IPs

```bash
# Allow access only from your office and home IPs
oc annotate route nextcloud \
  haproxy.router.openshift.io/ip_whitelist="203.0.113.50 198.51.100.0/24"
```

### Common Use Cases

| Scenario | Annotation Value |
|----------|------------------|
| Single IP | `203.0.113.50` |
| Multiple IPs | `203.0.113.50 198.51.100.25` |
| CIDR range | `10.0.0.0/8` |
| Mixed | `203.0.113.50 192.168.1.0/24 10.0.0.0/8` |

### Remove Restriction

```bash
oc annotate route nextcloud haproxy.router.openshift.io/ip_whitelist-
```

### Verify Configuration

```bash
oc get route nextcloud -o jsonpath='{.metadata.annotations.haproxy\.router\.openshift\.io/ip_whitelist}'
```

This is a great way to lock down a POC or demo instance to only your team's IPs without any infrastructure changes.

---

## 🚀 Production Recommendations

1. **External Database** — Use managed PostgreSQL/MariaDB for reliability
2. **Object Storage** — Configure S3-compatible backend for scalability
3. **Redis Cluster** — Enable Redis Sentinel for HA caching
4. **Backup Strategy** — Implement OADP or Velero for disaster recovery
5. **Resource Limits** — Tune CPU/memory based on user count

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-fix`)
3. Commit your changes (`git commit -m 'Add amazing fix'`)
4. Push to the branch (`git push origin feature/amazing-fix`)
5. Open a Pull Request

---

## 📚 References

- [Nextcloud Documentation](https://docs.nextcloud.com/server/latest/admin_manual/)
- [Nextcloud Helm Chart](https://github.com/nextcloud/helm)
- [OpenShift SCC Documentation](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
- [Collabora Online](https://www.collaboraoffice.com/code/)
- [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox)

---

## 🙏 Acknowledgments

- [Nextcloud](https://nextcloud.com) for the amazing self-hosted cloud platform
- [Collabora](https://www.collaboraoffice.com/) for the document editing engine
- Red Hat for OpenShift and the Developer Sandbox

---

<p align="center">
  <strong>⭐ If this saved you hours of debugging, consider giving it a star! ⭐</strong>
</p>

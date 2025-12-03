# 🚀 Nextcloud on OpenShift — Zero Privilege Deployment

[![OpenShift](https://img.shields.io/badge/OpenShift-4.x-red?logo=redhatopenshift)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-32.x-blue?logo=nextcloud)](https://nextcloud.com)
[![SCC](https://img.shields.io/badge/SCC-restricted-brightgreen)](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)

> **Deploy Nextcloud on OpenShift without ANY elevated privileges.** No `anyuid`. No `privileged`. Just pure, security-hardened container goodness designed for multi-tenancy.

---

## 🎯 Why This Matters

Most Nextcloud deployment guides tell you to grant `anyuid` or `privileged` SCCs. **That's a security anti-pattern.**

This repository provides a **battle-tested configuration** that runs Nextcloud under OpenShift's most restrictive security policy — the same constraints applied to untrusted workloads. Here's what that means:

| Security Feature | Status |
|-----------------|--------|
| Runs as non-root | ✅ |
| Random UID from namespace range | ✅ |
| All capabilities dropped | ✅ |
| No privilege escalation | ✅ |
| Seccomp profile enforced | ✅ |
| Works on Developer Sandbox | ✅ |

**The result?** A production-ready Nextcloud that your security team will actually approve.

---

## ✨ Features

- **🔒 Security First** — Runs entirely under `restricted` or `restricted-v2` SCC
- **☁️ Cloud Native** — Helm-based deployment with proper health checks and resource limits
- **🏃 Rootless Nginx** — Uses `nginxinc/nginx-unprivileged` for the web tier
- **📦 Self-Contained** — Single script deployment with auto-configuration
- **🧪 Sandbox Ready** — Tested on Red Hat Developer Sandbox (free tier!)
- **🔧 Fully Documented** — Every fix and workaround explained

---

## 📁 Repository Structure

```
nextcloud-on-openshift/
├── README.md                        # You're reading it
├── LICENSE                          # MIT License
├── deploy-nextcloud-sandbox.sh      # 🌟 One-click deployment for Developer Sandbox
├── values/
│   └── openshift-values.yaml        # Helm values for full OpenShift clusters
└── manifests/
    ├── route.yaml                   # OpenShift Route with TLS
    └── networkpolicy.yaml           # Network policies (optional)
```

### Files You Need

| File | Required | Description |
|------|----------|-------------|
| `deploy-nextcloud-sandbox.sh` | ✅ | All-in-one deployment script (recommended) |
| `values/openshift-values.yaml` | Optional | Standalone Helm values for customization |
| `manifests/route.yaml` | Optional | If deploying Route separately |
| `manifests/networkpolicy.yaml` | Optional | For network-isolated environments |

---

## 🚀 Quick Start

### Option 1: Developer Sandbox (Easiest)

Perfect for testing or personal use on the [free Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox):

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/nextcloud-on-openshift.git
cd nextcloud-on-openshift

# Login to your sandbox
oc login --token=YOUR_TOKEN --server=https://api.sandbox.openshiftapps.com:6443

# Deploy! 🎉
./deploy-nextcloud-sandbox.sh
```

The script auto-detects your namespace and hostname. Credentials are displayed at the end.

### Option 2: Full OpenShift Cluster

For production or self-managed clusters:

```bash
# Create namespace
oc new-project nextcloud

# Add Helm repo
helm repo add nextcloud https://nextcloud.github.io/helm/
helm repo update

# Deploy with custom values
helm install nextcloud nextcloud/nextcloud \
    -f values/openshift-values.yaml \
    --set nextcloud.host=nextcloud.apps.mycluster.example.com \
    --set nextcloud.password=$(openssl rand -base64 16) \
    -n nextcloud

# Create Route
oc apply -f manifests/route.yaml
```

---

## 🔧 What's Different About This Configuration?

### The Problem

The official Nextcloud Helm chart assumes you can:
- Run as a specific UID (33 or 82)
- Bind to port 80
- Write to arbitrary filesystem paths

**OpenShift's restricted SCC blocks all of this** — for good reason.

### The Solution

| Challenge | Our Fix |
|-----------|---------|
| Fixed UID requirement | Let OpenShift assign from namespace range |
| Port 80 binding | Use FPM + nginx-unprivileged on port 8080 |
| Health probes on wrong port | Patch probes to target nginx (8080) |
| `try_files` causing 403s | Remove `$uri/` directory fallback |
| Trusted domain errors | Auto-configure via `php occ` |
| Permission check failures | Disable false-positive check |

Every fix is automated in the deployment script.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     OpenShift Route                         │
│                  (TLS termination)                          │
└─────────────────────────┬───────────────────────────────────┘
                          │ :443 → :8080
┌─────────────────────────▼───────────────────────────────────┐
│                    Nextcloud Pod                            │
│  ┌─────────────────────┐    ┌─────────────────────────┐    │
│  │   nginx-unprivileged │    │   nextcloud:fpm-alpine  │    │
│  │      (port 8080)     │───▶│      (port 9000)        │    │
│  │   Static files +     │    │   PHP-FPM processing    │    │
│  │   reverse proxy      │    │                         │    │
│  └─────────────────────┘    └───────────┬─────────────┘    │
│                                          │                  │
│  ┌──────────────────────────────────────▼─────────────────┐│
│  │              Persistent Volume (RWO)                   ││
│  │   /var/www/html  /config  /data  /custom_apps          ││
│  └────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 Prerequisites

- **OpenShift 4.x** cluster (or Developer Sandbox)
- **oc CLI** installed and logged in
- **Helm 3.x** installed
- **Storage class** available for PVCs

---

## 🔍 Verification

After deployment, verify you're running with restricted SCC:

```bash
# Check SCC assignment (should show "restricted" or "restricted-v2")
oc get pod -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'

# Verify non-root UID
oc exec deploy/nextcloud -c nextcloud -- id
# Output: uid=1000680000(1000680000) gid=0(root) ...

# Test the application
curl -I https://$(oc get route nextcloud -o jsonpath='{.spec.host}')
```

---

## 🐛 Troubleshooting

### Pod stuck in `CrashLoopBackOff`

```bash
# Check which container is failing
oc get pods -l app.kubernetes.io/name=nextcloud

# View logs for each container
oc logs deploy/nextcloud -c nextcloud
oc logs deploy/nextcloud -c nextcloud-nginx
```

### 403 Forbidden in Browser

Usually a `trusted_domains` issue:

```bash
# Add your hostname to trusted domains
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set \
    trusted_domains 2 --value="your-hostname.apps.example.com"
```

### Probes Failing (Pod shows 1/2 Ready)

The Helm chart defaults probes to port 9000, but nginx is on 8080:

```bash
oc patch deploy nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/readinessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/livenessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/1/startupProbe/httpGet/port", "value": 8080}
]'
```

### "Data directory is readable by other people"

This is a false positive on OpenShift due to random UIDs:

```bash
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set \
    check_data_directory_permissions --value="false" --type=boolean
```

---

## 🚀 Production Recommendations

For production deployments, consider:

1. **External Database** — Use managed PostgreSQL instead of SQLite
2. **Object Storage** — Configure S3-compatible backend for scalability
3. **Redis Cache** — Enable Redis for improved performance
4. **Horizontal Scaling** — Use HPA with shared storage (NFS/S3)
5. **Backup Strategy** — Implement OADP or Velero for disaster recovery

---

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-fix`)
3. Commit your changes (`git commit -m 'Add amazing fix'`)
4. Push to the branch (`git push origin feature/amazing-fix`)
5. Open a Pull Request

---

## 🙏 Acknowledgments

- [Nextcloud](https://nextcloud.com) for the amazing self-hosted cloud platform
- [Nextcloud Helm Chart](https://github.com/nextcloud/helm) maintainers
- Red Hat for OpenShift and the Developer Sandbox
- Claude.ai's Opus 4.5 model for troubleshooting Nextcloud's native Helm deployment on OpenShift

---

## 📚 References

- [Nextcloud Helm Chart Documentation](https://github.com/nextcloud/helm)
- [OpenShift SCC Documentation](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
- [Nextcloud Admin Manual](https://docs.nextcloud.com/server/latest/admin_manual/)
- [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox)

---

<p align="center">
  <b>⭐ If this saved you hours of debugging, consider giving it a star! ⭐</b>
</p>

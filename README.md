# 🚀 Nextcloud on OpenShift — Cloud-Native Deployment

[![OpenShift](https://img.shields.io/badge/OpenShift-4.x-red?logo=redhatopenshift)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-32.x-blue?logo=nextcloud)](https://nextcloud.com)
[![SCC](https://img.shields.io/badge/SCC-restricted-brightgreen)](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)

> **Deploy a production-ready Nextcloud stack on OpenShift without ANY elevated privileges.** Includes MinIO S3 object storage, MariaDB, and Redis — all running under the most restrictive security policies.

---

## 🎯 Why This Matters

Most Nextcloud deployment guides require `anyuid` or `privileged` SCCs. **That's a security anti-pattern.**

This repository provides a **battle-tested, cloud-native configuration** that runs entirely under OpenShift's restricted SCC — the same constraints applied to untrusted workloads on multi-tenant clusters.

| Security Feature | Status |
| --- | --- |
| Runs as non-root | ✅ |
| Random UID from namespace range | ✅ |
| All capabilities dropped | ✅ |
| No privilege escalation | ✅ |
| Seccomp profile enforced | ✅ |
| Works on Developer Sandbox | ✅ |

---

## ✨ Features

* **🔒 Security First** — Runs entirely under `restricted` or `restricted-v2` SCC
* **☁️ S3 Object Storage** — User files stored in MinIO (scalable, fast)
* **🗄️ Production Database** — MariaDB using SCLORG images (Red Hat optimized)
* **⚡ Redis Caching** — Sessions and file locking for performance
* **📦 Single Script Deploy** — One command to deploy the entire stack
* **🧪 Sandbox Ready** — Tested on Red Hat Developer Sandbox (free tier!)

---

## 🏗️ Architecture

```
                        ┌─────────────────┐
                        │  OpenShift      │
                        │  Route (TLS)    │
                        └────────┬────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │   Nextcloud     │
                        │   (FPM+nginx)   │
                        │    gp3 5Gi      │
                        └───────┬─────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
   ┌─────────┐            ┌──────────┐            ┌─────────┐
   │  MinIO  │            │ MariaDB  │            │  Redis  │
   │   S3    │            │  10.11   │            │    6    │
   │gp3 20Gi │            │ gp3 2Gi  │            │(memory) │
   └─────────┘            └──────────┘            └─────────┘
        │
   User files
   stored here
```

### Component Breakdown

| Component | Image | Purpose | Storage |
| --- | --- | --- | --- |
| **Nextcloud** | `nextcloud:fpm-alpine` | Application server | gp3 5Gi (app code) |
| **nginx** | `nginxinc/nginx-unprivileged` | Web server (sidecar) | — |
| **MinIO** | `quay.io/minio/minio` | S3 object storage | gp3 20Gi (user files) |
| **MariaDB** | `quay.io/sclorg/mariadb-1011-c9s` | Database | gp3 2Gi |
| **Redis** | `quay.io/sclorg/redis-6-c9s` | Cache & locking | In-memory |

All images run as non-root with arbitrary UIDs — perfect for OpenShift's restricted SCC.

---

## 📁 Repository Structure

```
nextcloud-on-openshift/
├── README.md                        # You're reading it
├── deploy-nextcloud-mariadb.sh      # 🌟 One-click cloud-native deployment
└── manifests/                       # Optional standalone manifests
    ├── route.yaml                   # OpenShift Route with TLS
    └── networkpolicy.yaml           # Network policies
```

---

## 🚀 Quick Start

### Prerequisites

* **OpenShift 4.x** cluster or [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) (free!)
* **oc CLI** installed and logged in
* **Helm 3.x** installed

### Deploy

```bash
# Clone the repo
git clone https://github.com/ryannix123/nextcloud-on-openshift.git
cd nextcloud-on-openshift

# Login to your cluster/sandbox
oc login --token=YOUR_TOKEN --server=https://api.your-cluster.com:6443

# Deploy the entire stack! 🎉
bash deploy-nextcloud-mariadb.sh
```

The script:
1. Deploys MinIO with a `nextcloud` bucket
2. Deploys MariaDB (SCLORG image)
3. Deploys Redis (SCLORG image)
4. Deploys Nextcloud via Helm with all fixes pre-applied
5. Configures S3 object storage, Redis caching, and trusted domains
6. Creates an OpenShift Route with TLS
7. Outputs credentials and URLs

**Credentials are saved to `nextcloud-credentials.txt`**

### Custom Hostname

```bash
# Auto-detect hostname (default)
bash deploy-nextcloud-mariadb.sh

# Or specify explicitly
bash deploy-nextcloud-mariadb.sh nextcloud.apps.mycluster.example.com
```

---

## 🔧 What Problems Does This Solve?

The official Nextcloud Helm chart wasn't designed for OpenShift's security model. Here's what we fix:

| Challenge | Problem | Our Fix |
| --- | --- | --- |
| **Fixed UID** | Chart expects UID 33/82 | Let OpenShift assign from namespace range |
| **Port 80** | Can't bind privileged ports | Use FPM + nginx-unprivileged on 8080 |
| **Probe ports** | Health checks target wrong port | Patch probes to target nginx (8080) |
| **Probe headers** | 400 errors from trusted domains | Add `Host: localhost` header to probes |
| **Service port** | targetPort defaults to 9000 | Patch to 8080 (nginx, not PHP-FPM) |
| **Permission check** | False positive on random UIDs | Disable via `occ` config |
| **File storage** | Local PVC doesn't scale | MinIO S3 for user files |
| **Sessions** | Filesystem sessions don't scale | Redis for sessions & locking |

Every fix is automated in the deployment script.

---

## 🔍 Verification

After deployment, verify the security posture:

```bash
# Check SCC assignment (should show "restricted" or "restricted-v2")
oc get pods -o custom-columns=\
'NAME:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'

# Verify non-root UID
oc exec deploy/nextcloud -c nextcloud -- id
# Output: uid=1004220000(1004220000) gid=0(root) ...

# Test S3 storage
oc exec deploy/minio -- mc ls local/nextcloud

# Test Redis
oc exec deploy/redis -- redis-cli -a $(oc get secret redis-secret -o jsonpath='{.data.redis-password}' | base64 -d) ping
```

---

## 📊 Storage Architecture

### Why MinIO S3?

| Storage Type | Pros | Cons |
| --- | --- | --- |
| **Local PVC** | Simple | Single-node, doesn't scale |
| **EFS (NFS)** | Multi-attach | UID mismatch on OpenShift, slow IOPS |
| **MinIO S3** ✅ | Scalable, fast, proper S3 API | Extra component |

With MinIO:
- User uploads go directly to S3 (fast, scalable)
- Thumbnails and previews stored in S3
- Metadata stays in MariaDB (fast queries)
- App code on fast gp3 EBS

### Viewing Your Files

```bash
# List objects in MinIO
oc exec deploy/minio -- mc ls local/nextcloud --recursive

# Access MinIO console (URL in credentials file)
oc get route minio-console -o jsonpath='{.spec.host}'
```

Files are stored as `urn:oid:X` — Nextcloud maps these to filenames in the database.

---

## 🐛 Troubleshooting

### Pod shows 1/2 Ready

Usually probe issues. Check probe configuration:

```bash
# Verify probes target port 8080
oc get deploy nextcloud -o jsonpath='{.spec.template.spec.containers[1].startupProbe.httpGet.port}'
# Should output: 8080

# If not, patch:
oc patch deploy nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/startupProbe/httpGet/port", "value": 8080}
]'
```

### 502 Bad Gateway

PHP-FPM not running or nginx can't reach it:

```bash
# Check PHP-FPM process
oc exec deploy/nextcloud -c nextcloud -- ps aux | grep php

# Check logs
oc logs deploy/nextcloud -c nextcloud
oc logs deploy/nextcloud -c nextcloud-nginx
```

### "Trusted domain" errors

```bash
# Add your hostname
oc exec deploy/nextcloud -c nextcloud -- php occ config:system:set \
    trusted_domains 2 --value="your-hostname.apps.example.com"
```

### S3 Connection Issues

```bash
# Test MinIO health
oc exec deploy/nextcloud -c nextcloud -- curl -s http://minio:9000/minio/health/ready

# Check S3 config
oc exec deploy/nextcloud -c nextcloud -- cat /var/www/html/config/config.php | grep -A15 objectstore
```

### Database Connection Issues

```bash
# Test MariaDB
oc exec deploy/mariadb -- mysql -u nextcloud -p$(oc get secret mariadb-secret -o jsonpath='{.data.database-password}' | base64 -d) -e "SELECT 1"
```

---

## 🔐 Credentials

All credentials are auto-generated and saved to `nextcloud-credentials.txt`:

```
Nextcloud:
- URL: https://nextcloud-yournamespace.apps.cluster.com
- Username: admin
- Password: (random)

MinIO Console:
- URL: https://minio-yournamespace.apps.cluster.com  
- Root User: minioadmin
- Root Password: (random)

MariaDB:
- Host: mariadb:3306
- Database: nextcloud
- Password: (random)

Redis:
- Host: redis:6379
- Password: (random)
```

---

## 🚀 Production Recommendations

For production deployments, consider:

1. **External Database** — Use AWS RDS or Azure Database for MariaDB/PostgreSQL
2. **External S3** — Use AWS S3 or any S3-compatible service instead of MinIO
3. **Redis Cluster** — For HA, use AWS ElastiCache or Redis Enterprise
4. **Backup Strategy** — Implement Velero or OADP for disaster recovery
5. **Monitoring** — Enable Nextcloud metrics and Prometheus scraping
6. **Custom Domain** — Configure proper DNS and certificates

---

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-fix`)
3. Commit your changes (`git commit -m 'Add amazing fix'`)
4. Push to the branch (`git push origin feature/amazing-fix`)
5. Open a Pull Request

---

## 📚 References

* [Nextcloud Helm Chart Documentation](https://github.com/nextcloud/helm)
* [OpenShift SCC Documentation](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
* [MinIO Documentation](https://min.io/docs/minio/kubernetes/upstream/)
* [SCLORG Container Images](https://github.com/sclorg)
* [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox)

---

## 🙏 Acknowledgments

* [Nextcloud](https://nextcloud.com) for the amazing self-hosted cloud platform
* [Nextcloud Helm Chart](https://github.com/nextcloud/helm) maintainers
* [MinIO](https://min.io) for S3-compatible object storage
* Red Hat for OpenShift and the Developer Sandbox
* Claude AI (Anthropic) for pair-programming through all the edge cases

---

**⭐ If this saved you hours of debugging, consider giving it a star! ⭐**

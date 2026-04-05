# lldap-on-openshift

<p align="center">
  <img src="https://miro.medium.com/v2/resize:fit:598/format:webp/1*KanqkJzW8EURgM86TePD0w.jpeg" alt="lldap" width="220">
</p>

<p align="center">
  <a href="https://github.com/ryannix123/lldap-on-openshift/actions/workflows/build.yaml">
    <img src="https://img.shields.io/github/actions/workflow/status/ryannix123/lldap-on-openshift/build.yaml?branch=main&label=build&logo=github" alt="Build Status">
  </a>
  <a href="https://quay.io/repository/ryan_nix/lldap-openshift">
    <img src="https://img.shields.io/badge/quay.io-ryan__nix%2Flldap--openshift-1f6feb?logo=redhat" alt="Quay.io">
  </a>
  <img src="https://img.shields.io/badge/lldap-0.6.2-brightgreen" alt="lldap version">
  <img src="https://img.shields.io/badge/base-lldap%3Astable-4b8bbe" alt="lldap stable">
  <img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-6e7681" alt="Multi-arch">
  <img src="https://img.shields.io/badge/OpenShift-compatible-EE0000?logo=redhat&logoColor=white" alt="OpenShift compatible">
  <img src="https://img.shields.io/badge/RAM-~20MB-success" alt="Low memory footprint">
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License">
  </a>
</p>

> **Lightweight LDAP authentication that never leaves the cluster.**

[lldap](https://github.com/lldap/lldap) is a Rust-based lightweight LDAP server purpose-built for authentication. It runs at ~20MB RAM, stores users in a single SQLite file, and includes a built-in web UI for user and group management — no `ldapadd` commands, no schema files, no LDIF.

---

## Why lldap on OpenShift?

Most enterprise applications that require LDAP authentication are designed to point at an external directory — Active Directory, FreeIPA, or a corporate LDAP server. That model introduces external dependencies, firewall rules, and a hard coupling that breaks whenever the upstream service is unreachable.

This project takes a different approach: deploy a self-contained LDAP service directly into your OpenShift namespace. Authentication traffic stays on the pod network, never crosses a namespace boundary, and works in air-gapped or disconnected environments.

### OpenShift SCC compatibility

Getting any LDAP server running under OpenShift's restricted Security Context Constraints is non-trivial. The restricted SCC:

- Assigns a random UID from the namespace's allocated range at runtime — hardcoded UIDs fail
- Prohibits `fsGroup: 0` on newer clusters — blocking the standard Docker pattern of fixing PVC ownership at startup
- Prevents `chown` and `gosu` at container runtime — which most LDAP images depend on for initialization

lldap's Rust binary runs natively as any UID and needs no privilege escalation. This image patches the upstream `docker-entrypoint.sh` at build time to remove the `chown` and `gosu` calls that would fail under the restricted SCC, replacing them with a direct `exec` of the lldap binary. No custom SCC, no `anyuid`, no cluster-admin required.

### Why not OpenLDAP or 389 DS?

| | OpenLDAP | 389 DS | **lldap** |
|---|---|---|---|
| Restricted SCC compatible | ❌ Requires patching | ❌ Needs systemd | ✅ Native |
| Runtime `chown`/`gosu` | ✅ Required | ✅ Required | ❌ Not needed |
| Memory footprint | ~150MB | ~300MB+ | ~20MB |
| Bootstrap complexity | High (OLC, slapadd, mdb) | High (dscreate) | None |
| Storage backend | MDB (file-per-instance) | LMDB + indexes | SQLite (single file) |
| Built-in web UI | ❌ | ✅ | ✅ |
| Suitable for auth-only use | ✅ | ✅ | ✅ |

`openldap-servers` was removed from RHEL 8 and all downstream distributions including CentOS Stream 10. 389 DS requires systemd socket activation and cluster-admin to install its operator. lldap works out of the box.

---

## Architecture

```
Namespace
├── Deployment/lldap
│     ├── LDAP  :3890  (ClusterIP — in-cluster auth)
│     ├── LDAPS :6360  (ClusterIP — TLS via OpenShift service cert)
│     └── Web   :17170 (Route — admin UI)
├── Service/lldap         (ClusterIP — unreachable from outside the cluster)
├── Route/lldap-web       (HTTPS edge termination for web UI only)
├── Secret/lldap-secret   (jwt-secret + admin-password)
├── Secret/lldap-tls      (auto-injected by OpenShift cert controller)
├── ConfigMap/lldap-ca-bundle (cluster CA for LDAPS client verification)
└── PVC/lldap-data        (SQLite database — 256Mi)
```

The `lldap` Service is `ClusterIP` only. There is no `NodePort`, no `LoadBalancer`, and no LDAP `Route`. Authentication traffic physically cannot leave the cluster.

---

## Deployment

### Prerequisites

```bash
pip install kubernetes
ansible-galaxy collection install kubernetes.core
oc login --token=<token> --server=<api-url>
```

### Run the playbook

```bash
ansible-playbook -i localhost, deploy.yml
```

```
LDAP base DN [dc=example,dc=com]: dc=myapp,dc=com
JWT secret (long random string): <use: openssl rand -hex 32>
lldap admin password: <8 characters minimum>
```

The playbook detects your current namespace from `oc project`, creates the secret, applies the Service first so OpenShift's cert controller can inject the TLS secret, waits for cert injection, then deploys everything else and prints the web UI URL.

### Manual deployment

```bash
oc create secret generic lldap-secret \
  --from-literal=jwt-secret="$(openssl rand -hex 32)" \
  --from-literal=admin-password='<8-char-minimum>'

oc apply -f manifests/service.yaml
oc apply -k manifests/
```

---

## Use cases

### Namespace-isolated authentication for self-hosted apps

Deploy one lldap instance per namespace alongside applications like Nextcloud, Gitea, Rocket.Chat, or OpenEMR. Each namespace gets its own independent user directory. Applications bind to `ldap://lldap:3890` — a ClusterIP address that is unreachable from outside the namespace.

### Development and staging environments

Spin up a real LDAP service in a dev namespace without connecting to production Active Directory. Developers get full control over test users and groups without risking production data.

### Air-gapped and disconnected OpenShift clusters

lldap has no external dependencies at runtime. Once the image is mirrored to an internal registry, it runs indefinitely without internet access.

### OpenShift Developer Sandbox

The Developer Sandbox enforces the restricted SCC with no exceptions. lldap is one of the few LDAP implementations that works within these constraints without modification to cluster policy.

---

## Connecting applications

### LDAP connection settings

| Setting | Value |
|---|---|
| LDAP URL (plain) | `ldap://lldap:3890` |
| LDAPS URL | `ldaps://lldap:6360` |
| Bind DN | `uid=admin,ou=people,dc=example,dc=com` |
| Users base DN | `ou=people,dc=example,dc=com` |
| Groups base DN | `ou=groups,dc=example,dc=com` |
| User filter | `(&(objectClass=person)(uid={login}))` |
| Group filter | `(member={dn})` |

### Mount the CA bundle for LDAPS

Add to any application Deployment that connects over LDAPS:

```yaml
volumeMounts:
  - name: ldap-ca
    mountPath: /etc/ldap/ca
    readOnly: true
volumes:
  - name: ldap-ca
    configMap:
      name: lldap-ca-bundle
```

Point your application's TLS config at `/etc/ldap/ca/service-ca.crt`.

### Nextcloud

In Nextcloud's LDAP/AD integration app (**Apps → LDAP user and group backend**):

```
Server:       ldap://lldap
Port:         3890
Bind DN:      uid=admin,ou=people,dc=example,dc=com
Bind password: <admin password>
Base DN:      dc=example,dc=com
```

User filter: `(&(objectClass=person)(uid=%uid))`
Login attribute: `uid`
Username field: `uid`

### Gitea

In Gitea's admin panel (**Site Administration → Authentication Sources → Add Authentication Source**):

```
Authentication type: LDAP (simple auth)
Host:               lldap
Port:               3890
Bind DN:            uid=admin,ou=people,dc=example,dc=com
User search base:   ou=people,dc=example,dc=com
User filter:        (&(objectClass=person)(uid=%s))
Username attribute: uid
Email attribute:    mail
```

### Rocket.Chat

In Rocket.Chat admin (**Administration → LDAP → Connection**):

```
Server:    lldap
Port:      3890
Bind DN:   uid=admin,ou=people,dc=example,dc=com
Base DN:   ou=people,dc=example,dc=com
```

Under **User Search**:
```
Filter: (objectclass=person)
Scope:  sub
```

### OpenEMR

In OpenEMR's LDAP configuration (**Admin → Globals → LDAP**):

```
LDAP Host:   ldap://lldap
LDAP Port:   3890
Bind DN:     uid=admin,ou=people,dc=example,dc=com
Base DN:     ou=people,dc=example,dc=com
```

---

## Directory layout

| DN | Purpose |
|---|---|
| `uid=admin,ou=people,<base>` | Admin — full access to web UI and LDAP |
| `ou=people,<base>` | User accounts |
| `ou=groups,<base>` | Groups for role-based access control |

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `LLDAP_LDAP_BASE_DN` | `dc=example,dc=com` | Root suffix — set before first deploy |
| `LLDAP_JWT_SECRET` | *(from Secret)* | Token signing secret — use `openssl rand -hex 32` |
| `LLDAP_LDAP_USER_PASS` | *(from Secret)* | Admin password — 8 character minimum |
| `LLDAP_DATABASE_URL` | `sqlite:///data/users.db?mode=rwc` | SQLite path — leave as default |
| `LLDAP_LDAPS_OPTIONS__ENABLED` | `true` | Enable LDAPS |
| `LLDAP_LDAPS_OPTIONS__PORT` | `6360` | LDAPS port (non-privileged) |

---

## Nextcloud integration

Full step-by-step `occ` commands for connecting Nextcloud to lldap are documented in the [nextcloud-on-openshift](https://github.com/ryannix123/nextcloud-on-openshift) companion repository:

📄 [additions/authentication/README.md](https://github.com/ryannix123/nextcloud-on-openshift/blob/main/additions/authentication/README.md)

This covers enabling the `user_ldap` app, creating a config slot, wiring up all filters and attribute mappings, and verifying the connection — all via `oc exec` without touching the Nextcloud GUI.

---

## Securing the web UI Route

By default the Route is publicly accessible to anyone with the URL. Add the OpenShift OAuth proxy annotation to restrict access to authenticated cluster users only:

```bash
oc annotate route lldap-web \
  haproxy.router.openshift.io/ip_whitelist="" \
  --overwrite
```

Or restrict to a specific IP range — useful for limiting web UI access to a VPN or office network:

```bash
oc annotate route lldap-web \
  haproxy.router.openshift.io/ip_whitelist="10.0.0.0/8 192.168.1.0/24" \
  --overwrite
```

You can also set this directly in `manifests/route.yaml` before deploying:

```yaml
metadata:
  annotations:
    haproxy.router.openshift.io/ip_whitelist: "10.0.0.0/8"
```

Note that LDAP and LDAPS traffic on ports 3890 and 6360 are ClusterIP only and already unreachable from outside the cluster — the Route only exposes the web UI on port 17170.

---

## Image

`quay.io/ryan_nix/lldap-openshift:latest`

Built weekly from `lldap:stable`. Multi-arch: `linux/amd64` and `linux/arm64`. The upstream `docker-entrypoint.sh` is patched at build time to remove `chown` and `gosu` calls that are incompatible with OpenShift's restricted SCC.



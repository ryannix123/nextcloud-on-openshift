# Nextcloud on OpenShift — Ansible Deployment

An Ansible alternative to `deploy.sh` using the `kubernetes.core` collection.

## Prerequisites

```bash
ansible-galaxy collection install kubernetes.core community.okd
```

You must be logged into OpenShift (`oc login`) before running the playbook.

## Usage

### Deploy

```bash
ansible-playbook ansible/deploy.yml
```

You will be prompted whether to save manifests to `./manifests/`.

Override the image:

```bash
ansible-playbook ansible/deploy.yml -e nextcloud_image=quay.io/me/nextcloud:v2
```

### Cleanup (full teardown including PVCs)

```bash
ansible-playbook ansible/deploy.yml --tags cleanup
```

### Cleanup (preserve PVCs — for image rebuilds)

```bash
ansible-playbook ansible/deploy.yml --tags cleanup -e keep_data=true
```

## Notes

- Secrets are created once and preserved on re-runs, keeping MariaDB and
  `config.php` in sync. This is the same idempotency behaviour as `deploy.sh`.
- WOPI URL configuration for Collabora is owned by `entrypoint.sh` via the
  `NEXTCLOUD_TRUSTED_DOMAINS` environment variable. The playbook does not
  override WOPI settings post-deploy.
- Saved manifests do not include secrets — those are regenerated at deploy time.

# Authentication — LDAP via lldap

This guide covers connecting Nextcloud to [lldap-on-openshift](https://github.com/ryannix123/lldap-on-openshift) — a lightweight, OpenShift-native LDAP service that runs inside your namespace. Authentication traffic stays on the pod network and never leaves the cluster.

## Prerequisites

- lldap deployed in the same namespace as Nextcloud
- At least one user created in the lldap web UI
- The `user_ldap` app available in Nextcloud

## Configure LDAP via occ

All commands use `oc exec` to run Nextcloud's `occ` CLI inside the running pod. Replace `dc=acme,dc=com` with your base DN and update the admin password accordingly.

### 1. Enable the LDAP app

```bash
oc exec deployment/nextcloud -- php occ app:enable user_ldap
```

### 2. Create a config slot

```bash
oc exec deployment/nextcloud -- php occ ldap:create-empty-config
```

Note the slot ID returned (e.g. `s01`). Use it in all subsequent commands.

### 3. Configure the connection

```bash
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapHost ldap://lldap
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapPort 3890
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapAgentName "uid=admin,ou=people,dc=acme,dc=com"
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapAgentPassword "your-lldap-admin-password"
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapBase "dc=acme,dc=com"
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapBaseUsers "ou=people,dc=acme,dc=com"
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapBaseGroups "ou=groups,dc=acme,dc=com"
```

### 4. Set user and login filters

```bash
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapUserFilter "(|(objectclass=person)(objectclass=inetOrgPerson))"
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapLoginFilter "(&(objectClass=person)(uid=%uid))"
```

### 5. Set attribute mappings

```bash
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapUserDisplayName displayname
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapEmailAttribute mail
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapGroupFilter "(objectclass=groupOfUniqueNames)"
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapGroupDisplayName cn
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapGroupMemberAssocAttr member
```

### 6. Activate the configuration

```bash
oc exec deployment/nextcloud -- php occ ldap:set-config s01 ldapConfigurationActive 1
```

### 7. Test the connection

```bash
oc exec deployment/nextcloud -- php occ ldap:test-config s01
```

A successful response looks like:

```
The configuration is valid and the connection could be established!
```

## Verify user lookup

```bash
# Check that lldap users are visible to Nextcloud
oc exec deployment/nextcloud -- php occ ldap:search --group '' ''
oc exec deployment/nextcloud -- php occ user:list
```

## Useful management commands

```bash
# Clear the LDAP cache if users aren't appearing
oc exec deployment/nextcloud -- php occ ldap:clear-mapping user
oc exec deployment/nextcloud -- php occ ldap:clear-mapping group

# Show current LDAP config
oc exec deployment/nextcloud -- php occ ldap:show-config s01

# Delete a config slot
oc exec deployment/nextcloud -- php occ ldap:delete-config s01
```

## Connection reference

| Setting | Value |
|---|---|
| Host | `ldap://lldap` |
| Port | `3890` |
| Bind DN | `uid=admin,ou=people,dc=acme,dc=com` |
| Users base DN | `ou=people,dc=acme,dc=com` |
| Groups base DN | `ou=groups,dc=acme,dc=com` |
| User filter | `(&#124;(objectclass=person)(objectclass=inetOrgPerson))` |
| Login filter | `(&(objectClass=person)(uid=%uid))` |

## Notes

- lldap's LDAP service is `ClusterIP` only — it is not reachable from outside the cluster
- The bind DN uses lldap's admin account; create a dedicated read-only user for production use
- Users log in to Nextcloud with their lldap `uid`, not their email address
- See [lldap-on-openshift](https://github.com/ryannix123/lldap-on-openshift) for full deployment instructions

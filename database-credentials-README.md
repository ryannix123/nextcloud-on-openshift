## Accessing Database Credentials

The Nextcloud deployment uses Kubernetes secrets to store sensitive database credentials. Here's how to retrieve them:

### View the Secret

```bash
oc get secret nextcloud-db-secret -n nextcloud -o yaml
```

### Decode Individual Values

The secret values are base64-encoded. To decode them:

```bash
# Get the database name
oc get secret nextcloud-db-secret -n nextcloud -o jsonpath='{.data.MYSQL_DATABASE}' | base64 -d && echo

# Get the database user
oc get secret nextcloud-db-secret -n nextcloud -o jsonpath='{.data.MYSQL_USER}' | base64 -d && echo

# Get the database password
oc get secret nextcloud-db-secret -n nextcloud -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d && echo

# Get the root password
oc get secret nextcloud-db-secret -n nextcloud -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d && echo
```

### View All Credentials at Once

```bash
echo "Database: $(oc get secret nextcloud-db-secret -n nextcloud -o jsonpath='{.data.MYSQL_DATABASE}' | base64 -d)"
echo "User: $(oc get secret nextcloud-db-secret -n nextcloud -o jsonpath='{.data.MYSQL_USER}' | base64 -d)"
echo "Password: $(oc get secret nextcloud-db-secret -n nextcloud -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)"
echo "Root Password: $(oc get secret nextcloud-db-secret -n nextcloud -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)"
```

### Connect to MariaDB Directly

If you need to access the database directly for troubleshooting:

```bash
# Port-forward to the MariaDB pod
oc port-forward svc/mariadb 3306:3306 -n nextcloud

# In another terminal, connect using mysql client
mysql -h 127.0.0.1 -u nextcloud -p nextcloud
# Enter the password when prompted (retrieve using the commands above)
```

**Security Note**: These credentials are automatically generated during deployment. In production environments, consider using external secret management solutions like HashiCorp Vault or OpenShift's built-in secret management features.

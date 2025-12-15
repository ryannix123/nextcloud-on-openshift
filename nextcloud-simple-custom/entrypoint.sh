#!/bin/bash
# Nextcloud entrypoint for OpenShift
# Supports both PVC storage and S3 object storage
set -e

echo "Starting Nextcloud container..."

# Wait for MariaDB
echo "Waiting for MariaDB at ${NC_MYSQL_HOST:-mariadb}:${NC_MYSQL_PORT:-3306}..."
for i in $(seq 1 30); do
    if php -r "if(@fsockopen('${NC_MYSQL_HOST:-mariadb}', ${NC_MYSQL_PORT:-3306})) exit(0); else exit(1);" 2>/dev/null; then
        echo "MariaDB is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "ERROR: MariaDB not available after 30 attempts"
        exit 1
    fi
    echo "  Attempt $i/30..."
    sleep 2
done

# Wait for Redis
echo "Waiting for Redis at ${NC_REDIS_HOST:-redis}:${NC_REDIS_PORT:-6379}..."
for i in $(seq 1 30); do
    if php -r "if(@fsockopen('${NC_REDIS_HOST:-redis}', ${NC_REDIS_PORT:-6379})) exit(0); else exit(1);" 2>/dev/null; then
        echo "Redis is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "WARNING: Redis not available, continuing without it"
        break
    fi
    echo "  Attempt $i/30..."
    sleep 2
done

# Setup data directory
DATA_DIR="/var/www/html/data"
echo "Setting up data directory..."
if [ ! -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR"
fi

# Try to fix permissions (may fail if PVC doesn't allow)
chmod 0770 "$DATA_DIR" 2>/dev/null && echo "Set data dir to 0770" || echo "Warning: Could not chmod data dir (this may be OK)"

# Create .ncdata marker
if [ ! -f "$DATA_DIR/.ncdata" ]; then
    touch "$DATA_DIR/.ncdata" 2>/dev/null || true
fi

echo "Data dir permissions: $(ls -ld $DATA_DIR)"

# Check if permissions are acceptable (no world-readable)
PERMS=$(stat -c %a "$DATA_DIR" 2>/dev/null || echo "unknown")
if [ "$PERMS" != "unknown" ]; then
    WORLD_READ=$((PERMS % 10))
    if [ "$WORLD_READ" -gt 0 ]; then
        echo "Warning: Data directory has world-readable permissions ($PERMS)"
        echo "Nextcloud may complain but we'll try to continue..."
    fi
fi

# Check config
echo "Config directory contents:"
ls -la /var/www/html/config/

echo "Checking if config.php exists..."
if [ -f /var/www/html/config/config.php ]; then
    echo "config.php found! Checking if installation is valid..."
    if grep -q "'installed' => true" /var/www/html/config/config.php; then
        echo "Installation appears valid."
    else
        echo "Installation incomplete, removing config.php..."
        rm -f /var/www/html/config/config.php
    fi
fi

# Install Nextcloud if not installed
if [ ! -f /var/www/html/config/config.php ]; then
    echo "Installing Nextcloud..."
    
    # Create CAN_INSTALL marker
    touch "$DATA_DIR/CAN_INSTALL"
    
    # Pre-create minimal config to disable permission check (OpenShift PVCs have restricted perms)
    echo "Creating minimal config to disable permission check..."
    cat > /var/www/html/config/config.php << 'EOFCFG'
<?php
$CONFIG = array (
  'check_data_directory_permissions' => false,
);
EOFCFG
    
    # Check for stale database and clean if needed
    echo "Checking for stale database tables..."
    TABLE_COUNT=$(php -r "
        try {
            \$pdo = new PDO(
                'mysql:host=${NC_MYSQL_HOST:-mariadb};port=${NC_MYSQL_PORT:-3306};dbname=${NC_MYSQL_DATABASE:-nextcloud}',
                '${NC_MYSQL_USER:-nextcloud}',
                '${NC_MYSQL_PASSWORD:-}'
            );
            \$result = \$pdo->query('SHOW TABLES');
            echo \$result->rowCount();
        } catch (Exception \$e) {
            echo '0';
        }
    " 2>/dev/null)
    
    if [ "$TABLE_COUNT" -gt 0 ]; then
        echo "Found $TABLE_COUNT stale tables, cleaning database..."
        php -r "
            \$pdo = new PDO(
                'mysql:host=${NC_MYSQL_HOST:-mariadb};port=${NC_MYSQL_PORT:-3306};dbname=${NC_MYSQL_DATABASE:-nextcloud}',
                '${NC_MYSQL_USER:-nextcloud}',
                '${NC_MYSQL_PASSWORD:-}'
            );
            \$pdo->exec('SET FOREIGN_KEY_CHECKS = 0');
            \$result = \$pdo->query('SHOW TABLES');
            while (\$row = \$result->fetch(PDO::FETCH_NUM)) {
                \$pdo->exec('DROP TABLE IF EXISTS ' . \$row[0]);
            }
            \$pdo->exec('SET FOREIGN_KEY_CHECKS = 1');
            echo 'Database cleaned.';
        " 2>/dev/null || echo "Warning: Could not clean database"
    fi
    
    # Run installation
    php /var/www/html/occ maintenance:install \
        --database=mysql \
        --database-host="${NC_MYSQL_HOST:-mariadb}:${NC_MYSQL_PORT:-3306}" \
        --database-name="${NC_MYSQL_DATABASE:-nextcloud}" \
        --database-user="${NC_MYSQL_USER:-nextcloud}" \
        --database-pass="${NC_MYSQL_PASSWORD:-}" \
        --admin-user="${NEXTCLOUD_ADMIN_USER:-admin}" \
        --admin-pass="${NEXTCLOUD_ADMIN_PASSWORD:-admin}" \
        --data-dir="$DATA_DIR"
    
    echo "Installation complete!"
else
    echo "Nextcloud already installed, checking for upgrades..."
    php /var/www/html/occ upgrade --no-interaction || true
    php /var/www/html/occ maintenance:mode --off || true
fi

# Configure Redis
echo "Configuring Redis..."
php /var/www/html/occ config:system:set redis host --value="${NC_REDIS_HOST:-redis}"
php /var/www/html/occ config:system:set redis port --value="${NC_REDIS_PORT:-6379}" --type=integer
if [ -n "${NC_REDIS_PASSWORD:-}" ]; then
    php /var/www/html/occ config:system:set redis password --value="${NC_REDIS_PASSWORD}"
fi
php /var/www/html/occ config:system:set memcache.local --value='\OC\Memcache\APCu'
php /var/www/html/occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
php /var/www/html/occ config:system:set memcache.locking --value='\OC\Memcache\Redis'

# Configure S3 if enabled
if [ "${NC_S3_ENABLED:-true}" = "true" ] && [ -n "${NC_S3_BUCKET:-}" ]; then
    echo "Configuring S3 object storage..."
    cat > /var/www/html/config/s3.config.php << EOFS3
<?php
\$CONFIG = array (
  'objectstore' => array(
    'class' => '\\OC\\Files\\ObjectStore\\S3',
    'arguments' => array(
      'bucket' => '${NC_S3_BUCKET}',
      'hostname' => '${NC_S3_HOST:-minio}',
      'port' => ${NC_S3_PORT:-9000},
      'key' => '${NC_S3_KEY}',
      'secret' => '${NC_S3_SECRET}',
      'use_ssl' => ${NC_S3_SSL:-false},
      'use_path_style' => true,
      'autocreate' => true,
      'region' => '${NC_S3_REGION:-us-east-1}',
      'verify_bucket_exists' => false,
    ),
  ),
);
EOFS3
else
    echo "S3 storage disabled, using local storage."
    # Remove S3 config if it exists
    rm -f /var/www/html/config/s3.config.php
fi

# Configure trusted domains
echo "Configuring trusted domains..."
IFS=' ' read -ra DOMAINS <<< "${NEXTCLOUD_TRUSTED_DOMAINS:-localhost}"
INDEX=0
for DOMAIN in "${DOMAINS[@]}"; do
    php /var/www/html/occ config:system:set trusted_domains $INDEX --value="$DOMAIN"
    INDEX=$((INDEX + 1))
done

# Configure trusted proxies
php /var/www/html/occ config:system:set trusted_proxies 0 --value="10.0.0.0/8"
php /var/www/html/occ config:system:set trusted_proxies 1 --value="172.16.0.0/12"
php /var/www/html/occ config:system:set trusted_proxies 2 --value="192.168.0.0/16"
php /var/www/html/occ config:system:set overwriteprotocol --value="https"
php /var/www/html/occ config:system:set default_phone_region --value="US"

# Disable data directory permission check (OpenShift PVCs have restricted permissions)
php /var/www/html/occ config:system:set check_data_directory_permissions --value=false --type=boolean

# Start services
echo "Starting services..."
exec /usr/bin/supervisord -n -c /etc/supervisord.conf

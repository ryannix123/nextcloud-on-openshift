# Nextcloud Container for OpenShift
# Base: CentOS Stream 10 | Web: Nginx | PHP: 8.3 (Remi) | Non-root compatible
# Nextcloud Version: 31.0.8

FROM quay.io/centos/centos:stream10

LABEL maintainer="Ryan" \
      description="Nextcloud 31 on CentOS Stream 10 with Nginx and PHP-FPM 8.3 (OpenShift compatible)" \
      version="31.0.8"

ARG NEXTCLOUD_VERSION=31.0.8

# Set environment variables
ENV NEXTCLOUD_VERSION=${NEXTCLOUD_VERSION} \
    PHP_MEMORY_LIMIT=512M \
    PHP_UPLOAD_MAX_FILESIZE=16G \
    PHP_POST_MAX_SIZE=16G \
    PHP_MAX_EXECUTION_TIME=3600 \
    PHP_MAX_INPUT_TIME=3600 \
    NGINX_LISTEN_PORT=8080

# Install EPEL and Remi repositories, then PHP 8.3 and dependencies
RUN dnf -y install epel-release && \
    dnf -y install https://rpms.remirepo.net/enterprise/remi-release-10.rpm && \
    dnf config-manager --set-enabled crb && \
    dnf -y module reset php && \
    dnf -y module enable php:remi-8.3 && \
    dnf -y install \
        nginx \
        supervisor \
        curl \
        unzip \
        bzip2 \
        procps-ng \
        # PHP and required extensions for Nextcloud
        php \
        php-fpm \
        php-cli \
        php-gd \
        php-mbstring \
        php-xml \
        php-zip \
        php-curl \
        php-intl \
        php-bcmath \
        php-gmp \
        php-opcache \
        php-apcu \
        php-redis \
        php-imagick \
        php-ldap \
        php-smbclient \
        # Database connectors
        php-mysqlnd \
        php-pgsql \
        php-pdo \
        # Additional recommended extensions
        php-sodium \
        php-pecl-apcu \
        php-process \
        php-sysvsem \
        && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# Download and extract Nextcloud
RUN curl -fsSL "https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2" \
        -o /tmp/nextcloud.tar.bz2 && \
    curl -fsSL "https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2.sha256" \
        -o /tmp/nextcloud.tar.bz2.sha256 && \
    cd /tmp && sha256sum -c nextcloud.tar.bz2.sha256 && \
    tar -xjf /tmp/nextcloud.tar.bz2 -C /var/www && \
    rm -f /tmp/nextcloud.tar.bz2 /tmp/nextcloud.tar.bz2.sha256

# Create required directories with proper permissions for OpenShift
# OpenShift runs containers with arbitrary UIDs in the root group (GID 0)
RUN mkdir -p /var/www/nextcloud/data \
             /var/www/nextcloud/config \
             /var/www/nextcloud/custom_apps \
             /var/run/php-fpm \
             /var/log/php-fpm \
             /var/log/nginx \
             /var/lib/nginx \
             /var/lib/nginx/tmp \
             /run/nginx \
             /etc/nginx/conf.d && \
    # Set ownership to root group for OpenShift arbitrary UID support
    chown -R 1001:0 /var/www/nextcloud && \
    chown -R 1001:0 /var/run/php-fpm && \
    chown -R 1001:0 /var/log/php-fpm && \
    chown -R 1001:0 /var/log/nginx && \
    chown -R 1001:0 /var/lib/nginx && \
    chown -R 1001:0 /run/nginx && \
    chown -R 1001:0 /etc/nginx && \
    # Set group-writable permissions (required for OpenShift)
    chmod -R g+rwX /var/www/nextcloud && \
    chmod -R g+rwX /var/run/php-fpm && \
    chmod -R g+rwX /var/log/php-fpm && \
    chmod -R g+rwX /var/log/nginx && \
    chmod -R g+rwX /var/lib/nginx && \
    chmod -R g+rwX /run/nginx && \
    chmod -R g+rwX /etc/nginx

# Configure PHP
RUN { \
        echo "[PHP]"; \
        echo "memory_limit = \${PHP_MEMORY_LIMIT}"; \
        echo "upload_max_filesize = \${PHP_UPLOAD_MAX_FILESIZE}"; \
        echo "post_max_size = \${PHP_POST_MAX_SIZE}"; \
        echo "max_execution_time = \${PHP_MAX_EXECUTION_TIME}"; \
        echo "max_input_time = \${PHP_MAX_INPUT_TIME}"; \
        echo "date.timezone = UTC"; \
        echo "expose_php = Off"; \
        echo ""; \
        echo "[opcache]"; \
        echo "opcache.enable = 1"; \
        echo "opcache.interned_strings_buffer = 32"; \
        echo "opcache.max_accelerated_files = 10000"; \
        echo "opcache.memory_consumption = 128"; \
        echo "opcache.save_comments = 1"; \
        echo "opcache.revalidate_freq = 60"; \
        echo "opcache.jit = 1255"; \
        echo "opcache.jit_buffer_size = 128M"; \
        echo ""; \
        echo "[apcu]"; \
        echo "apc.enabled = 1"; \
        echo "apc.shm_size = 128M"; \
        echo "apc.enable_cli = 1"; \
    } > /etc/php.d/99-nextcloud.ini

# Configure PHP-FPM for non-root operation
RUN sed -i \
        -e 's/^user = .*/user = default/' \
        -e 's/^group = .*/group = root/' \
        -e 's/^listen = .*/listen = 127.0.0.1:9000/' \
        -e 's/^;listen.owner = .*/listen.owner = default/' \
        -e 's/^;listen.group = .*/listen.group = root/' \
        -e 's/^;listen.mode = .*/listen.mode = 0660/' \
        -e 's/^pm.max_children = .*/pm.max_children = 50/' \
        -e 's/^pm.start_servers = .*/pm.start_servers = 5/' \
        -e 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 5/' \
        -e 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 35/' \
        -e 's/^;pm.max_requests = .*/pm.max_requests = 500/' \
        -e 's|^;*php_admin_value\[error_log\] = .*|php_admin_value[error_log] = /dev/stderr|' \
        -e 's|^;*php_admin_flag\[log_errors\] = .*|php_admin_flag[log_errors] = on|' \
        /etc/php-fpm.d/www.conf && \
    # Remove default pid file location (we'll set it via command line)
    sed -i 's|^pid = .*|pid = /var/run/php-fpm/php-fpm.pid|' /etc/php-fpm.conf && \
    # Send PHP-FPM logs to stderr
    sed -i 's|^error_log = .*|error_log = /dev/stderr|' /etc/php-fpm.conf && \
    # Ensure error log directory exists and is writable
    touch /var/log/php-fpm/www-error.log && \
    chmod 664 /var/log/php-fpm/www-error.log

# Create Nginx configuration for Nextcloud
RUN cat > /etc/nginx/nginx.conf << 'NGINXCONF'
# Run as non-root user
worker_processes auto;
error_log /dev/stderr warn;
pid /run/nginx/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /dev/stdout main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Temp paths for non-root operation
    client_body_temp_path /var/lib/nginx/tmp/client_body;
    proxy_temp_path /var/lib/nginx/tmp/proxy;
    fastcgi_temp_path /var/lib/nginx/tmp/fastcgi;
    uwsgi_temp_path /var/lib/nginx/tmp/uwsgi;
    scgi_temp_path /var/lib/nginx/tmp/scgi;

    # Increase body size for large file uploads
    client_max_body_size 16G;
    client_body_buffer_size 512k;

    # FastCGI settings
    fastcgi_buffers 64 4K;
    fastcgi_buffer_size 32k;
    fastcgi_busy_buffers_size 32k;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml application/javascript application/json application/ld+json 
               application/manifest+json application/rss+xml application/vnd.geo+json 
               application/vnd.ms-fontobject application/wasm application/x-font-ttf 
               application/x-web-app-manifest+json application/xhtml+xml application/xml 
               font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest 
               text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt 
               text/x-component text/x-cross-domain-policy;

    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF

# Create Nextcloud-specific Nginx server block
RUN cat > /etc/nginx/conf.d/nextcloud.conf << 'SERVERCONF'
upstream php-handler {
    server 127.0.0.1:9000;
}

# HTTP redirect map for Nextcloud
map $http_x_forwarded_proto $nc_proto {
    default $scheme;
    https https;
}

server {
    listen 8080 default_server;
    listen [::]:8080 default_server;
    server_name _;

    root /var/www/nextcloud;

    # Security headers
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Remove X-Powered-By header
    fastcgi_hide_header X-Powered-By;

    # Nextcloud discovery
    location = /.well-known/carddav {
        return 301 $nc_proto://$host/remote.php/dav;
    }
    location = /.well-known/caldav {
        return 301 $nc_proto://$host/remote.php/dav;
    }
    location = /.well-known/webfinger {
        return 301 $nc_proto://$host/index.php/.well-known/webfinger;
    }
    location = /.well-known/nodeinfo {
        return 301 $nc_proto://$host/index.php/.well-known/nodeinfo;
    }

    # Deny access to sensitive directories
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) {
        return 404;
    }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) {
        return 404;
    }
    location ~ ^/(?:index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy)\.php(?:$|/) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;
        try_files $fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass php-handler;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_read_timeout 3600;
        fastcgi_send_timeout 3600;
        fastcgi_connect_timeout 3600;
    }

    location ~ ^/(?:updater|ocs-provider)(?:$|/) {
        try_files $uri/ =404;
        index index.php;
    }

    location ~ \.(?:css|js|woff2?|svg|gif|map)$ {
        try_files $uri /index.php$request_uri;
        add_header Cache-Control "public, max-age=15778463, immutable";
        access_log off;
    }

    location ~ \.(?:png|html|ttf|ico|jpg|jpeg|bcmap|mp4|webm|webp|avif)$ {
        try_files $uri /index.php$request_uri;
        access_log off;
    }

    location / {
        try_files $uri $uri/ /index.php$request_uri;
    }
}
SERVERCONF

# Create supervisord configuration
RUN mkdir -p /etc/supervisor.d && \
    cat > /etc/supervisor.d/nextcloud.ini << 'SUPERVISOR'
[supervisord]
nodaemon=true
user=root
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/var/run/supervisord.pid
loglevel=warn

[program:php-fpm]
command=/usr/sbin/php-fpm --nodaemonize
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
priority=5

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
priority=10

[program:cron]
command=/bin/bash -c "while true; do php -f /var/www/nextcloud/cron.php; sleep 300; done"
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
priority=15
SUPERVISOR

# Create entrypoint script
RUN cat > /entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
set -e

# Ensure directories exist and have correct permissions at runtime
# This handles OpenShift's arbitrary UID assignment
for dir in /var/www/nextcloud/data \
           /var/www/nextcloud/config \
           /var/www/nextcloud/custom_apps \
           /var/run/php-fpm \
           /var/lib/nginx/tmp/client_body \
           /var/lib/nginx/tmp/proxy \
           /var/lib/nginx/tmp/fastcgi \
           /var/lib/nginx/tmp/uwsgi \
           /var/lib/nginx/tmp/scgi \
           /run/nginx; do
    mkdir -p "$dir"
done

# Update PHP configuration from environment variables
if [ -f /etc/php.d/99-nextcloud.ini ]; then
    sed -i "s|memory_limit = .*|memory_limit = ${PHP_MEMORY_LIMIT}|" /etc/php.d/99-nextcloud.ini
    sed -i "s|upload_max_filesize = .*|upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}|" /etc/php.d/99-nextcloud.ini
    sed -i "s|post_max_size = .*|post_max_size = ${PHP_POST_MAX_SIZE}|" /etc/php.d/99-nextcloud.ini
    sed -i "s|max_execution_time = .*|max_execution_time = ${PHP_MAX_EXECUTION_TIME}|" /etc/php.d/99-nextcloud.ini
    sed -i "s|max_input_time = .*|max_input_time = ${PHP_MAX_INPUT_TIME}|" /etc/php.d/99-nextcloud.ini
fi

# Check if Nextcloud is installed
if [ ! -f /var/www/nextcloud/config/config.php ]; then
    echo "==> Nextcloud not yet configured."
    echo "==> Complete installation via web UI or use occ command:"
    echo "    php /var/www/nextcloud/occ maintenance:install \\"
    echo "        --database mysql --database-host DB_HOST \\"
    echo "        --database-name nextcloud --database-user nextcloud \\"
    echo "        --database-pass PASSWORD --admin-user admin --admin-pass PASSWORD"
fi

# Run Nextcloud cron if config exists
if [ -f /var/www/nextcloud/config/config.php ]; then
    echo "==> Running initial Nextcloud maintenance..."
    php /var/www/nextcloud/occ maintenance:mode --off 2>/dev/null || true
fi

exec "$@"
ENTRYPOINT

RUN chmod +x /entrypoint.sh

# Expose port 8080 (non-privileged port for OpenShift)
EXPOSE 8080

# Set working directory
WORKDIR /var/www/nextcloud

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/status.php || exit 1

# Switch to non-root user
# Using UID 1001 which is commonly used, but OpenShift will override this
USER 1001

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
# Use CentOS 9 as base image
FROM quay.io/centos/centos:stream9

# Set environment variables
ENV NEXTCLOUD_VERSION=30.0.10 \
    APACHE_UID=1001 \
    APACHE_GID=0 \
    NEXTCLOUD_HOME=/var/www/html \
    APACHE_PORT=8080 \
    PHP_VERSION=8.3

# Install EPEL and Remi's repositories
RUN dnf install -y epel-release && \
    dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm && \
    dnf module reset php -y && \
    dnf module enable php:remi-${PHP_VERSION} -y

# Install required packages
RUN dnf update -y && \
    dnf install -y \
    httpd \
    php \
    php-fpm \
    php-zip \
    php-curl \
    php-gd \
    php-mbstring \
    php-intl \
    php-imagick \
    php-xml \
    php-json \
    php-pdo \
    php-pdo_mysql \
    php-pdo_pgsql \
    php-pgsql \
    php-redis \
    php-pecl-redis5 \
    php-opcache \
    php-process \
    php-bcmath \
    php-gmp \
    php-sysvsem \
    php-posix \
    php-pecl-apcu \
    php-ldap \
    php-imap \
    redis \
    postgresql \
    postgresql-server \
    unzip \
    wget \
    supervisor && \
    dnf clean all

# Download and install Nextcloud
RUN cd /tmp && \
    wget https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip && \
    unzip nextcloud-${NEXTCLOUD_VERSION}.zip && \
    rm -rf ${NEXTCLOUD_HOME}/* && \
    mv nextcloud/* ${NEXTCLOUD_HOME}/ && \
    rm -rf /tmp/nextcloud* && \
    chown -R ${APACHE_UID}:${APACHE_GID} ${NEXTCLOUD_HOME}

# Configure Apache for OpenShift
RUN sed -i "s/Listen 80/Listen ${APACHE_PORT}/" /etc/httpd/conf/httpd.conf && \
    sed -i "s/Listen 443/Listen 8443/" /etc/httpd/conf.d/ssl.conf || true && \
    sed -i "s/User apache/User ${APACHE_UID}/" /etc/httpd/conf/httpd.conf && \
    sed -i "s/Group apache/Group ${APACHE_GID}/" /etc/httpd/conf/httpd.conf && \
    echo "ServerName localhost" >> /etc/httpd/conf/httpd.conf

# Configure PHP-FPM for OpenShift
RUN sed -i 's/^listen = .*/listen = 127.0.0.1:9000/' /etc/php-fpm.d/www.conf && \
    sed -i "s/^user = .*/user = ${APACHE_UID}/" /etc/php-fpm.d/www.conf && \
    sed -i "s/^group = .*/group = ${APACHE_GID}/" /etc/php-fpm.d/www.conf && \
    sed -i "s/^listen.owner = .*/listen.owner = ${APACHE_UID}/" /etc/php-fpm.d/www.conf && \
    sed -i "s/^listen.group = .*/listen.group = ${APACHE_GID}/" /etc/php-fpm.d/www.conf

# Create custom PHP configuration for Nextcloud
RUN echo "upload_max_filesize = 512M" >> /etc/php.d/nextcloud.ini && \
    echo "post_max_size = 512M" >> /etc/php.d/nextcloud.ini && \
    echo "max_execution_time = 3600" >> /etc/php.d/nextcloud.ini && \
    echo "max_input_time = 3600" >> /etc/php.d/nextcloud.ini && \
    echo "memory_limit = 512M" >> /etc/php.d/nextcloud.ini && \
    echo "opcache.enable=1" >> /etc/php.d/nextcloud.ini && \
    echo "opcache.memory_consumption=128" >> /etc/php.d/nextcloud.ini && \
    echo "opcache.max_accelerated_files=10000" >> /etc/php.d/nextcloud.ini && \
    echo "opcache.revalidate_freq=1" >> /etc/php.d/nextcloud.ini && \
    echo "opcache.save_comments=1" >> /etc/php.d/nextcloud.ini

# Configure Redis
RUN echo "bind 127.0.0.1" >> /etc/redis/redis.conf && \
    echo "port 6379" >> /etc/redis/redis.conf && \
    echo "maxmemory 256mb" >> /etc/redis/redis.conf && \
    echo "maxmemory-policy allkeys-lru" >> /etc/redis/redis.conf

# Create Apache virtual host configuration
RUN cat > /etc/httpd/conf.d/nextcloud.conf << 'EOF'
<VirtualHost *:8080>
    ServerName localhost
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
        
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
        
        SetEnv HOME /var/www/html
        SetEnv HTTP_HOME /var/www/html
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:fcgi://127.0.0.1:9000"
    </FilesMatch>

    ErrorLog /proc/self/fd/2
    CustomLog /proc/self/fd/1 combined
</VirtualHost>
EOF

# Create necessary directories and adjust permissions
RUN mkdir -p /var/run/php-fpm /var/log/php-fpm /var/run/redis /var/lib/redis && \
    chown -R ${APACHE_UID}:${APACHE_GID} /etc/httpd /var/www /var/run/php-fpm /var/log/php-fpm /var/run/redis /var/lib/redis /etc/redis && \
    chmod -R g+rwx /etc/httpd /var/www /var/run/php-fpm /var/log/php-fpm /var/run/redis /var/lib/redis /etc/redis && \
    mkdir -p /var/www/html/data && \
    chown -R ${APACHE_UID}:${APACHE_GID} /var/www/html/data && \
    chmod -R g+rwx /var/www/html/data

# Create supervisor configuration
RUN cat > /etc/supervisord.conf << 'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/dev/stdout
logfile_maxbytes=0
loglevel=info

[program:redis]
command=/usr/bin/redis-server /etc/redis/redis.conf
user=1001
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:php-fpm]
command=/usr/sbin/php-fpm --nodaemonize
user=1001
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:httpd]
command=/usr/sbin/httpd -DFOREGROUND
user=root
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# Create Nextcloud configuration template for Redis and PostgreSQL
RUN cat > /var/www/html/config/redis.config.php << 'EOF'
<?php
$CONFIG = array (
  'memcache.local' => '\OC\Memcache\APCu',
  'memcache.distributed' => '\OC\Memcache\Redis',
  'memcache.locking' => '\OC\Memcache\Redis',
  'redis' => array(
    'host' => '127.0.0.1',
    'port' => 6379,
  ),
  'filelocking.enabled' => true,
);
EOF

RUN chown -R ${APACHE_UID}:${APACHE_GID} /var/www/html/config && \
    chmod -R g+rwx /var/www/html/config

# Set user and expose port
USER ${APACHE_UID}
EXPOSE ${APACHE_PORT}

# Set working directory
WORKDIR ${NEXTCLOUD_HOME}

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:${APACHE_PORT}/status.php || exit 1

# Start command
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
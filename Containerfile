FROM quay.io/centos/centos:stream10

# Install EPEL and Remi's repository
RUN dnf install -y epel-release && \
    dnf install -y https://rpms.remirepo.net/enterprise/remi-release-10.rpm && \
    dnf config-manager --set-enabled crb && \
    dnf module reset php -y && \
    dnf module enable php:remi-8.3 -y

# Install Nginx, PHP-FPM, and required PHP extensions for Nextcloud
RUN dnf install -y \
    nginx \
    php-fpm \
    php-gd \
    php-json \
    php-curl \
    php-mbstring \
    php-intl \
    php-mcrypt \
    php-imagick \
    php-xml \
    php-zip \
    php-pdo \
    php-mysqlnd \
    php-pgsql \
    php-bcmath \
    php-gmp \
    php-apcu \
    php-redis \
    php-opcache \
    php-process \
    unzip \
    wget && \
    dnf clean all

# Create non-root user for running the application
RUN useradd -u 1001 -r -g 0 -s /sbin/nologin \
    -c "Nextcloud user" nextcloud

# Download and extract Nextcloud 32
WORKDIR /tmp
RUN wget https://download.nextcloud.com/server/releases/nextcloud-32.0.0.zip && \
    unzip nextcloud-32.0.0.zip -d /var/www/ && \
    rm nextcloud-32.0.0.zip

# Set up directory structure and permissions
RUN mkdir -p /var/www/nextcloud/data \
    /var/lib/nginx \
    /var/log/nginx \
    /run/php-fpm && \
    chown -R 1001:0 /var/www/nextcloud \
    /var/lib/nginx \
    /var/log/nginx \
    /run/php-fpm && \
    chmod -R g=u /var/www/nextcloud \
    /var/lib/nginx \
    /var/log/nginx \
    /run/php-fpm

# Configure PHP-FPM to run as non-root
RUN sed -i 's/user = apache/user = nextcloud/g' /etc/php-fpm.d/www.conf && \
    sed -i 's/group = apache/group = root/g' /etc/php-fpm.d/www.conf && \
    sed -i 's/listen = \/run\/php-fpm\/www.sock/listen = 127.0.0.1:9000/g' /etc/php-fpm.d/www.conf && \
    sed -i 's/;listen.owner = nobody/listen.owner = nextcloud/g' /etc/php-fpm.d/www.conf && \
    sed -i 's/;listen.group = nobody/listen.group = root/g' /etc/php-fpm.d/www.conf && \
    sed -i 's/;clear_env = no/clear_env = no/g' /etc/php-fpm.d/www.conf

# Configure PHP settings for Nextcloud
RUN echo "upload_max_filesize = 512M" >> /etc/php.ini && \
    echo "post_max_size = 512M" >> /etc/php.ini && \
    echo "memory_limit = 512M" >> /etc/php.ini && \
    echo "max_execution_time = 300" >> /etc/php.ini && \
    echo "max_input_time = 300" >> /etc/php.ini

# Create Nginx configuration
RUN rm -f /etc/nginx/nginx.conf
COPY <<'EOF' /etc/nginx/nginx.conf
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    client_max_body_size 512M;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    upstream php-handler {
        server 127.0.0.1:9000;
    }

    server {
        listen 8080;
        server_name _;

        root /var/www/nextcloud;

        add_header Referrer-Policy "no-referrer" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Download-Options "noopen" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Permitted-Cross-Domain-Policies "none" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header X-XSS-Protection "1; mode=block" always;

        fastcgi_hide_header X-Powered-By;

        index index.php index.html /index.php$request_uri;

        location = / {
            if ( $http_user_agent ~ ^DavClnt ) {
                return 302 /remote.php/webdav/$is_args$args;
            }
        }

        location = /robots.txt {
            allow all;
            log_not_found off;
            access_log off;
        }

        location ^~ /.well-known {
            location = /.well-known/carddav { return 301 /remote.php/dav/; }
            location = /.well-known/caldav  { return 301 /remote.php/dav/; }

            location /.well-known/acme-challenge    { try_files $uri $uri/ =404; }
            location /.well-known/pki-validation    { try_files $uri $uri/ =404; }

            return 301 /index.php$request_uri;
        }

        location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
        location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

        location ~ \.php(?:$|/) {
            rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode\/proxy) /index.php$request_uri;

            fastcgi_split_path_info ^(.+?\.php)(/.*)$;
            set $path_info $fastcgi_path_info;

            try_files $fastcgi_script_name =404;

            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $path_info;

            fastcgi_param modHeadersAvailable true;
            fastcgi_param front_controller_active true;
            fastcgi_pass php-handler;

            fastcgi_intercept_errors on;
            fastcgi_request_buffering off;
        }

        location ~ \.(?:css|js|svg|gif|png|jpg|ico|wasm|tflite|map)$ {
            try_files $uri /index.php$request_uri;
            expires 6M;
            access_log off;
        }

        location ~ \.woff2?$ {
            try_files $uri /index.php$request_uri;
            expires 7d;
            access_log off;
        }

        location /remote {
            return 301 /remote.php$request_uri;
        }

        location / {
            try_files $uri $uri/ /index.php$request_uri;
        }
    }
}
EOF

# Fix Nginx PID file location for non-root
RUN sed -i 's/pid \/run\/nginx.pid;/pid \/tmp\/nginx.pid;/g' /etc/nginx/nginx.conf

# Create startup script
COPY <<'EOF' /usr/local/bin/start.sh
#!/bin/bash
set -e

# Start PHP-FPM in the background
php-fpm -D

# Start Nginx in the foreground
exec nginx -g 'daemon off;'
EOF

RUN chmod +x /usr/local/bin/start.sh

# Set working directory
WORKDIR /var/www/nextcloud

# Switch to non-root user
USER 1001

# Expose port 8080 (non-privileged port)
EXPOSE 8080

# Start services
CMD ["/usr/local/bin/start.sh"]
#!/bin/bash
# WordPress Setup Script for Ubuntu 24.04+ - Clean, Minimal & Dedicated Nginx Site

set -o errexit

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

section_done() {
    echo -e "${GREEN}✓ Section complete.${NC}"
    echo -e "${YELLOW}Continuing in 3 seconds...${NC}"
    sleep 3
}

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}     WordPress Setup Script for Ubuntu 24.04+            ${NC}"
echo -e "${GREEN}============================================================${NC}"

# === Configuration ===
echo -e "${YELLOW}=== Configuration ===${NC}"

PHP_VERSION="8.3"
echo -e "${YELLOW}PHP Version:${NC} ${GREEN}${PHP_VERSION}${NC}"

WP_DIR_NAME_DEFAULT="html"
read -p "$(echo -e "${YELLOW}WordPress directory under /var/www/ [${WP_DIR_NAME_DEFAULT}]:${NC} ")" WP_DIR_NAME_INPUT
WP_DIR_NAME=${WP_DIR_NAME_INPUT:-$WP_DIR_NAME_DEFAULT}
WP_PATH="/var/www/${WP_DIR_NAME}"

PRIMARY_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
DOMAIN_DEFAULT="${PRIMARY_IP:-localhost}"
read -p "$(echo -e "${YELLOW}Site domain / IP [${DOMAIN_DEFAULT}]:${NC} ")" DOMAIN_INPUT
DOMAIN=${DOMAIN_INPUT:-$DOMAIN_DEFAULT}

# Create safe config filename (domain without TLD or IP with dashes)
SITE_NAME=$(echo "${DOMAIN}" | sed 's/\.[^.]*$//' | tr '.' '-')
CONFIG_FILE="/etc/nginx/sites-available/${SITE_NAME}.conf"

read -p "$(echo -e "${YELLOW}Install Certbot via Snap? (y/N):${NC} ")" CERTBOT_CHOICE
INSTALL_CERTBOT=false
[[ "$CERTBOT_CHOICE" =~ ^[Yy]$ ]] && INSTALL_CERTBOT=true

WP_DB_PASS=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+' < /dev/urandom | head -c 32)

echo -e "\n${YELLOW}Summary:${NC}"
echo -e "   Path       : ${GREEN}${WP_PATH}${NC}"
echo -e "   URL        : ${GREEN}http://${DOMAIN}${NC}"
echo -e "   Site Config: ${GREEN}${SITE_NAME}.conf${NC}"
echo -e "   DB User    : ${GREEN}wp_user${NC}"
echo -e "   Certbot    : ${GREEN}$([[ $INSTALL_CERTBOT == true ]] && echo Yes || echo No)${NC}"
sleep 3

# === Packages ===
log_info "Installing minimal required packages..."
sudo apt-get update -qq
sudo apt-get install -y \
    nginx mariadb-server \
    php${PHP_VERSION}-fpm \
    php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-imagick \
    curl unzip
section_done

# === Certbot Snap ===
if [ "$INSTALL_CERTBOT" = true ]; then
    log_info "Installing official Certbot via Snap..."
    sudo snap install core
    sudo snap refresh core
    sudo snap install --classic certbot
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot
    log_success "Certbot installed"
    section_done
fi

# === MariaDB ===
log_info "Securing MariaDB and creating WordPress database..."
sudo mysql -e "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" 2>/dev/null || true
sudo mysql -e "
CREATE DATABASE IF NOT EXISTS wordpress;
CREATE USER IF NOT EXISTS 'wp_user'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wp_user'@'localhost';
FLUSH PRIVILEGES;
"
section_done

# === PHP Settings ===
log_info "Configuring PHP limits..."
PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
for s in "upload_max_filesize=64M" "post_max_size=64M" "memory_limit=256M"; do
    k="${s%%=*}"; v="${s##*=}"
    sudo sed -i "s|^${k}\s*=.*|${k} = ${v}|" "${PHP_INI}" 2>/dev/null || echo "${k} = ${v}" | sudo tee -a "${PHP_INI}" >/dev/null
done
sudo systemctl restart php${PHP_VERSION}-fpm
section_done

# === Nginx global ===
log_info "Setting client_max_body_size = 64M..."
sudo sed -i '/http {/a \        client_max_body_size 64M;' /etc/nginx/nginx.conf 2>/dev/null || true
section_done

# === WordPress Files ===
log_info "Installing latest WordPress..."
if [ ! -f "${WP_PATH}/wp-config-sample.php" ]; then
    cd /tmp
    wget -q https://wordpress.org/latest.tar.gz
    sudo mkdir -p "${WP_PATH}"
    sudo tar -xzf latest.tar.gz -C /tmp
    sudo rsync -a --delete /tmp/wordpress/ "${WP_PATH}/"
    rm -rf /tmp/wordpress latest.tar.gz
    log_success "WordPress files installed"
else
    log_info "WordPress files already present"
fi
section_done

# === wp-config.php ===
if [ ! -f "${WP_PATH}/wp-config.php" ]; then
    log_info "Creating clean wp-config.php..."
    SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    
    sudo tee "${WP_PATH}/wp-config.php" > /dev/null <<EOF
<?php
/**
 * WordPress configuration
 */

define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'wp_user' );
define( 'DB_PASSWORD', '${WP_DB_PASS}' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

${SALTS}

\$table_prefix = 'wp_';

define( 'WP_MEMORY_LIMIT', '256M' );
define( 'WP_DEBUG', false );

if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
EOF
    log_success "wp-config.php created"
fi
section_done

# === Permissions ===
log_info "Setting correct permissions..."
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} +
sudo find "${WP_PATH}" -type f -exec chmod 644 {} +
sudo chmod 640 "${WP_PATH}/wp-config.php"
section_done

# === Dedicated Nginx Site Config ===
log_info "Creating dedicated site config: ${SITE_NAME}.conf"
sudo tee "${CONFIG_FILE}" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WP_PATH};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~ /\.ht { deny all; }

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options "SAMEORIGIN";
}
EOF

# Enable the site and disable default if it exists
sudo ln -sf "${CONFIG_FILE}" /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
section_done

# === Final Restart ===
log_info "Restarting services..."
sudo systemctl restart nginx php${PHP_VERSION}-fpm mariadb
log_success "All services restarted"

# === Final Summary ===
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}                  SETUP COMPLETE!                          ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "WordPress Location : ${BLUE}${WP_PATH}${NC}"
echo -e "Access URL         : ${BLUE}http://${DOMAIN}${NC}"
echo -e "Nginx Config       : ${BLUE}${CONFIG_FILE}${NC}"
echo -e "Database           : ${BLUE}wordpress${NC}"
echo -e "DB User            : ${BLUE}wp_user${NC}"
echo -e "DB Password        : ${YELLOW}${WP_DB_PASS}${NC}   ← SAVE THIS SECURELY!"
echo -e "\n${GREEN}Next Steps:${NC}"
echo -e "1. Open ${BLUE}http://${DOMAIN}${NC} to finish WordPress setup"
if [ "$INSTALL_CERTBOT" = true ]; then
    echo -e "2. Enable HTTPS : ${YELLOW}sudo certbot --nginx -d ${DOMAIN}${NC}"
fi
echo -e "\n${GREEN}Script is fully repeatable and safe to re-run.${NC}"

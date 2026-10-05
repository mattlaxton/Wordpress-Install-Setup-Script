#!/bin/bash
# WordPress Setup Script for Debian and Ubuntu 24.04+ - Clean, Minimal & Dedicated Nginx Site

set -o errexit
set -o nounset
set -o pipefail

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
echo -e "${GREEN}  WordPress Setup Script for Debian and Ubuntu 24.04+     ${NC}"
echo -e "${GREEN}============================================================${NC}"

# === Configuration ===
echo -e "${YELLOW}=== Configuration ===${NC}"

PRIMARY_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
DOMAIN_DEFAULT="${PRIMARY_IP:-localhost}"
read -p "$(echo -e "${YELLOW}Site domain / IP [${DOMAIN_DEFAULT}]:${NC} ")" DOMAIN_INPUT
DOMAIN=${DOMAIN_INPUT:-$DOMAIN_DEFAULT}
if [[ ! "${DOMAIN}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
    && [[ ! "${DOMAIN}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo -e "${RED}Domain must be a hostname or IPv4 address.${NC}" >&2
    exit 1
fi

WP_DIR_NAME_DEFAULT="${DOMAIN}"
echo -e "${BLUE}[INFO]${NC} This creates a new site directory. It does not replace /var/www/html."
read -p "$(echo -e "${YELLOW}WordPress directory under /var/www/ [${WP_DIR_NAME_DEFAULT}]:${NC} ")" WP_DIR_NAME_INPUT
WP_DIR_NAME=${WP_DIR_NAME_INPUT:-$WP_DIR_NAME_DEFAULT}
# One path segment only. Stops "../" and absolute paths from reaching chown/rsync.
if [[ ! "${WP_DIR_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo -e "${RED}Directory name must be a single segment (letters, numbers, dot, underscore, hyphen).${NC}" >&2
    exit 1
fi
WP_PATH="/var/www/${WP_DIR_NAME}"

# Database and user follow the domain, so each site gets its own.
DB_ID=$(printf '%s' "${DOMAIN}" | tr '[:upper:]' '[:lower:]' | tr '.-' '__' | tr -cd 'a-z0-9_')
if [[ ${#DB_ID} -gt 60 ]]; then
    DB_HASH=$(printf '%s' "${DOMAIN}" | sha256sum | awk '{print substr($1,1,8)}')
    DB_ID="${DB_ID:0:48}${DB_HASH}"
fi
DB_NAME="${DB_ID}"
DB_USER="${DB_ID}"

# Full domain keeps example.com and example.org from sharing one config file.
CONFIG_FILE="/etc/nginx/sites-available/${DOMAIN}.conf"

. /etc/os-release
read -p "$(echo -e "${YELLOW}Install Certbot from apt (certbot, python3-certbot-nginx)? (y/N):${NC} ")" CERTBOT_CHOICE
INSTALL_CERTBOT=false
[[ "$CERTBOT_CHOICE" =~ ^[Yy]$ ]] && INSTALL_CERTBOT=true

# Re-runs keep the password already stored in wp-config.php so MariaDB stays in sync.
if [[ -f "${WP_PATH}/wp-config.php" ]]; then
    WP_DB_PASS=$(sudo sed -n "s/^define( 'DB_PASSWORD', '\([A-Za-z0-9]*\)' );/\1/p" "${WP_PATH}/wp-config.php")
    if [[ -z "${WP_DB_PASS}" ]]; then
        echo -e "${RED}Could not read DB_PASSWORD from ${WP_PATH}/wp-config.php.${NC}" >&2
        exit 1
    fi
else
    # Alphanumeric only so the value is safe inside SQL and the shell.
    WP_DB_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
    if [[ ${#WP_DB_PASS} -ne 32 ]]; then
        echo -e "${RED}Failed to generate a database password.${NC}" >&2
        exit 1
    fi
fi

echo -e "\n${YELLOW}Summary:${NC}"
echo -e "   Path       : ${GREEN}${WP_PATH}${NC}"
echo -e "   URL        : ${GREEN}http://${DOMAIN}${NC}"
echo -e "   Site Config: ${GREEN}${DOMAIN}.conf${NC}"
echo -e "   Database   : ${GREEN}${DB_NAME}${NC}"
echo -e "   DB User    : ${GREEN}${DB_USER}${NC}"
echo -e "   Certbot    : ${GREEN}$([[ $INSTALL_CERTBOT == true ]] && echo Yes || echo No)${NC}"
echo
read -p "$(echo -e "${YELLOW}Continue with this site? (y/N):${NC} ")" CONTINUE_CHOICE
if [[ ! "${CONTINUE_CHOICE}" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Stopped before installing anything.${NC}" >&2
    exit 1
fi

# === Packages ===
PACKAGES=(
    nginx
    mariadb-server
    php-fpm
    php-mysql
    php-curl
    php-gd
    php-mbstring
    php-xml
    php-zip
    php-intl
    php-bcmath
    curl
    unzip
    wget
    rsync
)

log_info "Checking required packages..."
sudo apt-get update -qq

MISSING=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
        MISSING+=("${pkg}")
    fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    log_info "All required packages are already installed."
else
    echo -e "\n${YELLOW}Packages to install${NC}"
    echo -e "${YELLOW}-------------------${NC}"
    for pkg in "${MISSING[@]}"; do
        echo -e "  ${GREEN}${pkg}${NC}"
    done
    echo
    read -p "$(echo -e "${YELLOW}Install these ${#MISSING[@]} packages and continue? (y/N):${NC} ")" INSTALL_PACKAGES_CHOICE
    if [[ ! "${INSTALL_PACKAGES_CHOICE}" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Stopped before installing packages.${NC}" >&2
        exit 1
    fi
    sudo apt-get install -y "${MISSING[@]}"
fi

if ! dpkg-query -W -f='${Status}' php-imagick 2>/dev/null | grep -q 'install ok installed'; then
    SKIP_IMAGICK=false
    if [[ "${ID:-}" == "ubuntu" ]] && ! grep -RIsEq --exclude='*.save' '(^|[[:space:]])universe([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        read -p "$(echo -e "${YELLOW}Ubuntu universe is not enabled. php-imagick comes from there. Enable universe? (y/N):${NC} ")" ENABLE_UNIVERSE
        if [[ "${ENABLE_UNIVERSE}" =~ ^[Yy]$ ]]; then
            if ! command -v add-apt-repository >/dev/null 2>&1; then
                sudo apt-get install -y software-properties-common
            fi
            sudo add-apt-repository -y universe
        else
            SKIP_IMAGICK=true
            log_warn "Leaving universe disabled. php-imagick will not be installed."
        fi
    fi
    if [[ "${SKIP_IMAGICK}" == true ]]; then
        :
    elif apt-cache show php-imagick >/dev/null 2>&1; then
        log_info "Installing optional php-imagick..."
        if ! sudo apt-get install -y php-imagick; then
            log_warn "php-imagick was not installed. Install it later with: sudo apt-get install php-imagick"
        fi
    else
        log_warn "php-imagick is not in the enabled apt repositories, so it was skipped."
    fi
fi

# php-fpm is the distro metapackage (Depends: phpX.Y-fpm). Paths and the
# systemd unit stay versioned, so resolve that version from the package.
PHP_VERSION=$(apt-cache depends php-fpm | awk '/Depends: php[0-9]+\.[0-9]+-fpm/{print $2; exit}' | grep -oE '[0-9]+\.[0-9]+')
if [[ -z "${PHP_VERSION}" ]]; then
    echo -e "${RED}Could not determine the distribution default PHP version from php-fpm.${NC}" >&2
    exit 1
fi
log_info "Using distribution default PHP ${PHP_VERSION}"
section_done

# === Certbot ===
if [ "$INSTALL_CERTBOT" = true ]; then
    if ! apt-cache show certbot >/dev/null 2>&1 || ! apt-cache show python3-certbot-nginx >/dev/null 2>&1; then
        if [[ "${ID:-}" == "ubuntu" ]] && ! grep -RIsEq --exclude='*.save' '(^|[[:space:]])universe([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
            read -p "$(echo -e "${YELLOW}Ubuntu universe is not enabled. Certbot comes from there. Enable universe? (y/N):${NC} ")" ENABLE_UNIVERSE_CERTBOT
            if [[ "${ENABLE_UNIVERSE_CERTBOT}" =~ ^[Yy]$ ]]; then
                if ! command -v add-apt-repository >/dev/null 2>&1; then
                    sudo apt-get install -y software-properties-common
                fi
                sudo add-apt-repository -y universe
            else
                log_warn "Leaving universe disabled. Certbot will not be installed."
            fi
        fi
    fi
    if apt-cache show certbot >/dev/null 2>&1 && apt-cache show python3-certbot-nginx >/dev/null 2>&1; then
        log_info "Installing Certbot from apt..."
        sudo apt-get install -y certbot python3-certbot-nginx
        log_success "Certbot installed"
        section_done
    else
        log_warn "certbot or python3-certbot-nginx is not in the enabled apt repositories. Skipping Certbot."
        INSTALL_CERTBOT=false
    fi
fi

# === PHP Settings ===
log_info "Configuring PHP limits..."
PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
if [[ ! -f "${PHP_INI}" ]]; then
    echo -e "${RED}PHP ini not found at ${PHP_INI}.${NC}" >&2
    exit 1
fi

# Values shipped in the Debian/Ubuntu php.ini. Anything else was set on this server.
declare -A PHP_DISTRO=( [upload_max_filesize]=2M [post_max_size]=8M [memory_limit]=128M )
declare -A PHP_OURS=( [upload_max_filesize]=64M [post_max_size]=64M [memory_limit]=256M )
PHP_APPLY=()
PHP_CUSTOM=()
for k in upload_max_filesize post_max_size memory_limit; do
    current=$(grep -E "^[[:space:]]*${k}[[:space:]]*=" "${PHP_INI}" | head -n1 || true)
    current=$(printf '%s' "${current}" | sed -E "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*//; s/[[:space:]]*;.*//; s/[[:space:]]*$//")
    if [[ -z "${current}" || "${current}" == "${PHP_DISTRO[$k]}" ]]; then
        PHP_APPLY+=("${k}")
    elif [[ "${current}" != "${PHP_OURS[$k]}" ]]; then
        PHP_CUSTOM+=("${k}=${current}")
    fi
done
APPLY_CUSTOM=false
if [[ ${#PHP_CUSTOM[@]} -gt 0 ]]; then
    echo -e "${YELLOW}These PHP limits are no longer the distribution defaults:${NC}"
    for entry in "${PHP_CUSTOM[@]}"; do
        k="${entry%%=*}"
        current="${entry#*=}"
        echo -e "   ${k}: ${GREEN}${current}${NC}  (distribution ${PHP_DISTRO[$k]}, this script ${PHP_OURS[$k]})"
    done
    read -p "$(echo -e "${YELLOW}Change them to this script's values? (y/N):${NC} ")" PHP_CHANGE_CHOICE
    [[ "${PHP_CHANGE_CHOICE}" =~ ^[Yy]$ ]] && APPLY_CUSTOM=true
fi
for k in "${PHP_APPLY[@]+"${PHP_APPLY[@]}"}"; do
    [[ -z "${k}" ]] && continue
    if grep -qE "^[;[:space:]]*${k}[[:space:]]*=" "${PHP_INI}"; then
        sudo sed -i -E "s|^[;[:space:]]*${k}[[:space:]]*=.*|${k} = ${PHP_OURS[$k]}|" "${PHP_INI}"
    else
        echo "${k} = ${PHP_OURS[$k]}" | sudo tee -a "${PHP_INI}" >/dev/null
    fi
done
if [[ "${APPLY_CUSTOM}" == true ]]; then
    for entry in "${PHP_CUSTOM[@]}"; do
        k="${entry%%=*}"
        if grep -qE "^[;[:space:]]*${k}[[:space:]]*=" "${PHP_INI}"; then
            sudo sed -i -E "s|^[;[:space:]]*${k}[[:space:]]*=.*|${k} = ${PHP_OURS[$k]}|" "${PHP_INI}"
        else
            echo "${k} = ${PHP_OURS[$k]}" | sudo tee -a "${PHP_INI}" >/dev/null
        fi
    done
fi
if systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
    sudo systemctl reload "php${PHP_VERSION}-fpm"
else
    sudo systemctl start "php${PHP_VERSION}-fpm"
fi
section_done

# === WordPress directory ===
# Decide this before removing the default site or creating a database.
INSTALL_WP_FILES=true
if [[ -d "${WP_PATH}" ]] && [[ -n "$(sudo ls -A "${WP_PATH}")" ]]; then
    read -p "$(echo -e "${YELLOW}${WP_PATH} exists. Overwrite its contents? wp-config.php is kept. (y/N):${NC} ")" OVERWRITE_CHOICE
    if [[ ! "${OVERWRITE_CHOICE}" =~ ^[Yy]$ ]]; then
        if [[ -f "${WP_PATH}/wp-config-sample.php" ]]; then
            log_info "Keeping existing WordPress files"
            INSTALL_WP_FILES=false
        else
            echo -e "${RED}${WP_PATH} is not empty. Choose another directory or confirm overwrite.${NC}" >&2
            exit 1
        fi
    fi
fi

# === Default Nginx site ===
REMOVE_DEFAULT_SITE=false
if [[ -e /etc/nginx/sites-enabled/default || -e /etc/nginx/sites-available/default || -d /var/www/html ]]; then
    echo -e "${BLUE}[INFO]${NC} The new site will live in ${GREEN}${WP_PATH}${NC}."
    DEFAULT_SITE_FILE=""
    if [[ -f /etc/nginx/sites-available/default ]]; then
        DEFAULT_SITE_FILE=/etc/nginx/sites-available/default
    elif [[ -f /etc/nginx/sites-enabled/default ]]; then
        DEFAULT_SITE_FILE=/etc/nginx/sites-enabled/default
    fi
    if [[ -n "${DEFAULT_SITE_FILE}" ]]; then
        echo -e "${YELLOW}Default Nginx site (${DEFAULT_SITE_FILE}):${NC}"
        grep -E '^[[:space:]]*(listen|server_name|root)[[:space:]]' "${DEFAULT_SITE_FILE}" | sed 's/^/  /' || true
    fi
    if [[ -d /var/www/html ]]; then
        echo -e "${YELLOW}/var/www/html contains:${NC}"
        sudo ls -A /var/www/html | sed 's/^/  /' || true
    fi
    read -p "$(echo -e "${YELLOW}Remove the default Nginx site and /var/www/html? (y/N):${NC} ")" REMOVE_DEFAULT_CHOICE
    if [[ "${REMOVE_DEFAULT_CHOICE}" =~ ^[Yy]$ ]]; then
        REMOVE_DEFAULT_SITE=true
        sudo rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
        if [[ "${WP_PATH}" == "/var/www/html" ]]; then
            log_warn "This site uses /var/www/html, so that directory was not removed."
        elif [[ -d /var/www/html ]]; then
            sudo rm -rf /var/www/html
            log_success "Removed the default Nginx site and /var/www/html"
        else
            log_success "Removed the default Nginx site"
        fi
    else
        log_info "Keeping the default Nginx site and /var/www/html"
    fi
fi

# === Dedicated Nginx Site Config ===
log_info "Creating dedicated site config: ${DOMAIN}.conf"
DOMAIN_RE=$(printf '%s' "${DOMAIN}" | sed 's/[.[\*^$()+?{|]/\\&/g')
shopt -s nullglob
for existing in /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*; do
    [[ -f "${existing}" ]] || continue
    [[ "${existing}" == "${CONFIG_FILE}" ]] && continue
    [[ "${existing}" == "/etc/nginx/sites-enabled/${DOMAIN}.conf" ]] && continue
    if grep -Eq "server_name[[:space:]]+([^;]*[[:space:]])?${DOMAIN_RE}([[:space:];]|$)" "${existing}"; then
        echo -e "${RED}${DOMAIN} is already a server_name in ${existing}.${NC}" >&2
        exit 1
    fi
done
shopt -u nullglob

ENABLED_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"
HAD_CONFIG=false
CONFIG_BACKUP=""
if [[ -f "${CONFIG_FILE}" ]]; then
    HAD_CONFIG=true
    CONFIG_BACKUP=$(mktemp)
    sudo cp "${CONFIG_FILE}" "${CONFIG_BACKUP}"
fi
HAD_LINK=false
if [[ -e "${ENABLED_LINK}" || -L "${ENABLED_LINK}" ]]; then
    HAD_LINK=true
fi

sudo tee "${CONFIG_FILE}" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WP_PATH};
    index index.php index.html index.htm;

    client_max_body_size 64M;

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

sudo ln -sfn "${CONFIG_FILE}" "${ENABLED_LINK}"
if ! sudo nginx -t; then
    if [[ "${HAD_CONFIG}" == true ]]; then
        sudo cp "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    else
        sudo rm -f "${CONFIG_FILE}"
    fi
    if [[ "${HAD_LINK}" != true ]]; then
        sudo rm -f "${ENABLED_LINK}"
    fi
    rm -f "${CONFIG_BACKUP}"
    echo -e "${RED}Nginx config test failed. The new site was not left enabled.${NC}" >&2
    exit 1
fi
rm -f "${CONFIG_BACKUP}"

log_info "Reloading Nginx..."
if systemctl is-active --quiet nginx; then
    sudo nginx -s reload
else
    sudo systemctl start nginx
fi
log_success "Nginx reloaded"
section_done

# === MariaDB ===
mysql_root() {
    if [[ -n "${MYSQL_DEFAULTS:-}" ]]; then
        sudo mysql --defaults-extra-file="${MYSQL_DEFAULTS}" "$@"
    else
        sudo mysql "$@"
    fi
}

log_info "Connecting to MariaDB..."
MYSQL_DEFAULTS=""
if ! sudo mysql -N -e "SELECT 1" >/dev/null 2>&1; then
    read -r -s -p "$(echo -e "${YELLOW}MariaDB root password:${NC} ")" MYSQL_ROOT_PASS
    echo
    MYSQL_DEFAULTS=$(mktemp)
    chmod 600 "${MYSQL_DEFAULTS}"
    escaped_pass=${MYSQL_ROOT_PASS//\\/\\\\}
    escaped_pass=${escaped_pass//\"/\\\"}
    printf '[client]\nuser=root\npassword="%s"\n' "${escaped_pass}" > "${MYSQL_DEFAULTS}"
    unset MYSQL_ROOT_PASS escaped_pass
    if ! mysql_root -N -e "SELECT 1" >/dev/null 2>&1; then
        rm -f "${MYSQL_DEFAULTS}"
        echo -e "${RED}Could not log in to MariaDB as root.${NC}" >&2
        exit 1
    fi
fi

log_info "Creating database ${DB_NAME} and user ${DB_USER}..."
DB_EXISTS=$(mysql_root -N -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}'")
DB_USER_EXISTS=$(mysql_root -N -e "SELECT User FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost'")
SAME_SITE=false
if [[ -f "${WP_PATH}/wp-config.php" ]]; then
    CFG_DB=$(sudo sed -n "s/^define( 'DB_NAME', '\([^']*\)' );/\1/p" "${WP_PATH}/wp-config.php")
    CFG_USER=$(sudo sed -n "s/^define( 'DB_USER', '\([^']*\)' );/\1/p" "${WP_PATH}/wp-config.php")
    if [[ "${CFG_DB}" == "${DB_NAME}" && "${CFG_USER}" == "${DB_USER}" ]]; then
        SAME_SITE=true
    else
        rm -f "${MYSQL_DEFAULTS}"
        echo -e "${RED}${WP_PATH}/wp-config.php uses database '${CFG_DB}' and user '${CFG_USER}'.${NC}" >&2
        echo -e "${RED}This domain would use '${DB_NAME}'. Refusing to create a second database for it.${NC}" >&2
        exit 1
    fi
fi
if [[ "${SAME_SITE}" != true && ( -n "${DB_EXISTS}" || -n "${DB_USER_EXISTS}" ) ]]; then
    if [[ ! -f "${WP_PATH}/wp-config.php" ]]; then
        echo -e "${YELLOW}Database ${DB_NAME} or user ${DB_USER} already exists, and ${WP_PATH}/wp-config.php does not.${NC}"
        read -p "$(echo -e "${YELLOW}Reuse them for this site? (y/N):${NC} ")" REUSE_DB_CHOICE
        if [[ "${REUSE_DB_CHOICE}" =~ ^[Yy]$ ]]; then
            SAME_SITE=true
        fi
    fi
    if [[ "${SAME_SITE}" != true ]]; then
        rm -f "${MYSQL_DEFAULTS}"
        echo -e "${RED}Database ${DB_NAME} or user ${DB_USER} already exists. Not reusing them.${NC}" >&2
        exit 1
    fi
fi
mysql_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
rm -f "${MYSQL_DEFAULTS}"
section_done

# === WordPress Files ===
log_info "Installing latest WordPress..."
if [[ "${INSTALL_WP_FILES}" == true ]]; then
    tmp_wp=$(mktemp -d)
    trap 'rm -rf "${tmp_wp}"' EXIT
    saved_config=""
    if [[ -f "${WP_PATH}/wp-config.php" ]]; then
        saved_config=$(mktemp)
        sudo cat "${WP_PATH}/wp-config.php" > "${saved_config}"
    fi
    wget -q -O "${tmp_wp}/latest.tar.gz" https://wordpress.org/latest.tar.gz
    tar -xzf "${tmp_wp}/latest.tar.gz" -C "${tmp_wp}"
    sudo mkdir -p "${WP_PATH}"
    sudo rsync -a --delete "${tmp_wp}/wordpress/" "${WP_PATH}/"
    if [[ -n "${saved_config}" ]]; then
        sudo cp "${saved_config}" "${WP_PATH}/wp-config.php"
        rm -f "${saved_config}"
    fi
    rm -rf "${tmp_wp}"
    trap - EXIT
    log_success "WordPress files installed"
fi
section_done

# === wp-config.php ===
if [ ! -f "${WP_PATH}/wp-config.php" ]; then
    log_info "Creating clean wp-config.php..."
    SALTS=$(curl -fsS https://api.wordpress.org/secret-key/1.1/salt/)
    if [[ -z "${SALTS}" ]] || ! grep -q "AUTH_KEY" <<<"${SALTS}"; then
        echo -e "${RED}Failed to download WordPress secret keys.${NC}" >&2
        exit 1
    fi

    # Salts are written literally. An unquoted heredoc would expand $ and backticks in them.
    {
        cat <<EOF
<?php
/**
 * WordPress configuration
 */

define( 'DB_NAME', '${DB_NAME}' );
define( 'DB_USER', '${DB_USER}' );
define( 'DB_PASSWORD', '${WP_DB_PASS}' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

EOF
        printf '%s\n' "${SALTS}"
        cat <<'EOF'

$table_prefix = 'wp_';

define( 'WP_MEMORY_LIMIT', '256M' );
define( 'WP_DEBUG', false );

if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
EOF
    } | sudo tee "${WP_PATH}/wp-config.php" > /dev/null
    log_success "wp-config.php created"
fi
section_done

# === Permissions ===
log_info "Setting correct permissions..."
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} +
sudo find "${WP_PATH}" -type f -exec chmod 644 {} +
if [[ -f "${WP_PATH}/wp-config.php" ]]; then
    sudo chmod 640 "${WP_PATH}/wp-config.php"
fi
section_done

# === snapd ===
if dpkg-query -W -f='${Status}' snapd 2>/dev/null | grep -q 'install ok installed'; then
    echo -e "${YELLOW}snapd is installed.${NC}"
    if command -v snap >/dev/null 2>&1; then
        echo -e "${YELLOW}Installed snaps:${NC}"
        snap list 2>/dev/null | sed 's/^/  /' || true
    fi
    read -p "$(echo -e "${YELLOW}Remove snapd if you do not use it for anything else? (y/N):${NC} ")" REMOVE_SNAPD
    if [[ "${REMOVE_SNAPD}" =~ ^[Yy]$ ]]; then
        if command -v snap >/dev/null 2>&1; then
            for _ in 1 2 3 4 5; do
                mapfile -t SNAP_NAMES < <(snap list 2>/dev/null | awk 'NR>1 {print $1}')
                [[ ${#SNAP_NAMES[@]} -eq 0 ]] && break
                for snap_name in "${SNAP_NAMES[@]}"; do
                    sudo snap remove "${snap_name}" >/dev/null 2>&1 || true
                done
            done
        fi
        sudo systemctl stop snapd.socket snapd.service 2>/dev/null || true
        sudo apt-get purge -y snapd
        log_success "snapd removed"
    else
        log_info "Leaving snapd installed"
    fi
fi

# === Final Summary ===
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}                  SETUP COMPLETE!                          ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "WordPress Location : ${BLUE}${WP_PATH}${NC}"
echo -e "Access URL         : ${BLUE}http://${DOMAIN}${NC}"
echo -e "Nginx Config       : ${BLUE}${CONFIG_FILE}${NC}"
echo -e "Database           : ${BLUE}${DB_NAME}${NC}"
echo -e "DB User            : ${BLUE}${DB_USER}${NC}"
echo -e "DB Password        : ${YELLOW}${WP_DB_PASS}${NC}   ← SAVE THIS SECURELY!"
echo -e "\n${GREEN}Next Steps:${NC}"
echo -e "1. Open ${BLUE}http://${DOMAIN}${NC} to finish WordPress setup"
if [ "$INSTALL_CERTBOT" = true ]; then
    echo -e "2. Enable HTTPS : ${YELLOW}sudo certbot --nginx -d ${DOMAIN}${NC}"
fi
echo -e "\n${YELLOW}Re-running keeps this site's database password when wp-config.php exists.${NC}"
if [[ "${REMOVE_DEFAULT_SITE}" == true ]]; then
    echo -e "${YELLOW}The default Nginx site was removed.${NC}"
else
    echo -e "${YELLOW}Other Nginx sites, including the default site, are left enabled.${NC}"
fi

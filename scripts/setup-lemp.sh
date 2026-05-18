#!/usr/bin/env bash
# setup-lemp.sh — Install Nginx + PHP 8.2 + MariaDB + Let's Encrypt SSL (multi-distro)
# Supports: Debian, Ubuntu, Fedora, Arch, AlmaLinux, Rocky Linux, openSUSE, Alpine
# Usage: sudo ./setup-lemp.sh <domain> <email>
set -euo pipefail

DOMAIN="${1:-${DOMAIN:-}}"
EMAIL="${2:-${EMAIL:-}}"

[[ "$EUID" -ne 0 ]] && { echo "Run as root: sudo $0 <domain> <email>"; exit 1; }
[[ -z "$DOMAIN" || -z "$EMAIL" ]] && {
  echo "Usage:"
  echo "  sudo $0 <domain> <email>"
  echo "  curl -fsSL https://storescript.lenaca.workers.dev/setup-lemp.sh | sudo bash -s -- <domain> <email>"
  echo "  curl -fsSL https://storescript.lenaca.workers.dev/setup-lemp.sh | sudo DOMAIN=<domain> EMAIL=<email> bash"
  exit 1
}

WEBROOT="/var/www/${DOMAIN}/public"

detect_distro() {
  [[ -f /etc/os-release ]] && { . /etc/os-release; echo "${ID,,}"; } || echo "unknown"
}

DISTRO=$(detect_distro)

# ─── Package Installation ────────────────────────────────────────────────────

install_packages() {
  case "$DISTRO" in
    ubuntu|debian|linuxmint|pop)
      apt-get update -qq
      apt-get install -y nginx mariadb-server certbot python3-certbot-nginx \
        software-properties-common curl gnupg
      # PHP 8.2 via ondrej/php PPA (Ubuntu/Debian)
      if ! apt-cache show php8.2 &>/dev/null; then
        add-apt-repository -y ppa:ondrej/php 2>/dev/null \
          || { curl -sSL https://packages.sury.org/php/apt.gpg \
               | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg
               echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo $VERSION_CODENAME) main" \
               > /etc/apt/sources.list.d/sury-php.list; }
        apt-get update -qq
      fi
      apt-get install -y php8.2-fpm php8.2-mysql php8.2-xml php8.2-mbstring \
        php8.2-curl php8.2-zip php8.2-intl php8.2-bcmath
      ;;
    fedora)
      dnf -y install nginx mariadb-server certbot python3-certbot-nginx
      dnf -y install https://rpms.remirepo.net/fedora/remi-release-$(rpm -E %fedora).rpm
      dnf module reset php -y && dnf module enable php:remi-8.2 -y
      dnf -y install php php-fpm php-mysqlnd php-xml php-mbstring php-curl \
        php-zip php-intl php-bcmath
      ;;
    centos|almalinux|rocky|rhel)
      dnf -y install epel-release
      dnf -y install nginx mariadb-server certbot python3-certbot-nginx
      dnf -y install https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm
      dnf module reset php -y && dnf module enable php:remi-8.2 -y
      dnf -y install php php-fpm php-mysqlnd php-xml php-mbstring php-curl \
        php-zip php-intl php-bcmath
      ;;
    arch|manjaro|endeavouros)
      pacman -Sy --noconfirm nginx mariadb certbot certbot-nginx \
        php php-fpm
      # php8.2 on Arch is usually available via AUR or the php package
      ;;
    opensuse*|sles)
      zypper install -y nginx mariadb certbot python3-certbot-nginx \
        php8 php8-fpm php8-mysql php8-mbstring php8-curl php8-zip
      ;;
    alpine)
      apk add --no-cache nginx mariadb mariadb-client certbot certbot-nginx \
        php82 php82-fpm php82-pdo_mysql php82-xml php82-mbstring \
        php82-curl php82-zip php82-intl php82-bcmath php82-openssl
      ln -sf /usr/bin/php82 /usr/local/bin/php 2>/dev/null || true
      ;;
    *)
      echo "Distro '$DISTRO' not recognized."; exit 1 ;;
  esac
}

# ─── Service Management ──────────────────────────────────────────────────────

svc_enable() {
  if command -v systemctl &>/dev/null; then
    systemctl enable --now "$@"
  elif command -v rc-service &>/dev/null; then
    for s in "$@"; do rc-update add "$s" default; rc-service "$s" start; done
  fi
}

get_php_fpm_sock() {
  # Cari socket php-fpm yang tersedia
  for sock in \
    /run/php/php8.2-fpm.sock \
    /run/php-fpm/www.sock \
    /var/run/php-fpm/www.sock \
    /run/php82/php-fpm.sock; do
    [[ -S "$sock" ]] && { echo "$sock"; return; }
  done
  echo "/run/php/php8.2-fpm.sock"  # fallback
}

# ─── MariaDB Setup ───────────────────────────────────────────────────────────

setup_mariadb() {
  svc_enable mariadb mysql 2>/dev/null || true

  DB_NAME="${DOMAIN//./_}"
  DB_USER="${DB_NAME:0:16}"
  DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)

  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  # Save credentials
  cat > "/root/.db_${DOMAIN}.env" <<ENV
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
ENV
  chmod 600 "/root/.db_${DOMAIN}.env"
  echo "  DB credentials saved to /root/.db_${DOMAIN}.env"
}

# ─── Nginx Config ────────────────────────────────────────────────────────────

setup_nginx() {
  mkdir -p "$WEBROOT"
  [[ ! -f "${WEBROOT}/index.php" ]] && echo "<?php phpinfo();" > "${WEBROOT}/index.php"

  # Determine nginx config directory
  local conf_dir="/etc/nginx/sites-available"
  local enabled_dir="/etc/nginx/sites-enabled"
  if [[ ! -d "$conf_dir" ]]; then
    conf_dir="/etc/nginx/conf.d"
    enabled_dir="$conf_dir"
  fi

  local PHP_SOCK
  PHP_SOCK=$(get_php_fpm_sock)

  cat > "${conf_dir}/${DOMAIN}.conf" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${WEBROOT};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht { deny all; }
}
NGINX

  if [[ "$conf_dir" != "$enabled_dir" ]]; then
    ln -sf "${conf_dir}/${DOMAIN}.conf" "${enabled_dir}/${DOMAIN}.conf"
  fi

  nginx -t
  svc_enable nginx
  nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || true
}

# ─── SSL via Certbot ─────────────────────────────────────────────────────────

setup_ssl() {
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --redirect \
    -d "$DOMAIN" -d "www.${DOMAIN}"

  # Auto-renew cron (if not already set)
  if ! crontab -l 2>/dev/null | grep -q certbot; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'nginx -s reload'") | crontab -
  fi
}

# ─── PHP-FPM ─────────────────────────────────────────────────────────────────

setup_phpfpm() {
  case "$DISTRO" in
    ubuntu|debian*) svc_enable php8.2-fpm ;;
    alpine)         rc-update add php-fpm82 default; rc-service php-fpm82 start ;;
    *)              svc_enable php-fpm ;;
  esac
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "==> [1/5] Installing packages..."
install_packages

echo "==> [2/5] Setup MariaDB..."
setup_mariadb

echo "==> [3/5] Setup PHP-FPM..."
setup_phpfpm

echo "==> [4/5] Setup Nginx..."
setup_nginx

echo "==> [5/5] Setup SSL (Let's Encrypt)..."
setup_ssl

echo ""
echo "✓ LEMP stack configured successfully!"
echo "  Domain  : https://${DOMAIN}"
echo "  Webroot : ${WEBROOT}"
echo "  DB creds: /root/.db_${DOMAIN}.env"

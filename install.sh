#!/usr/bin/env bash
set -Eeuo pipefail

# SkylerNodes Professional Pterodactyl Panel Installer
# Independent third-party installer. Not affiliated with Pterodactyl or Nobita Cloud.

APP="SkylerNodes"
PANEL_DIR="/var/www/pterodactyl"
PTERO_ETC="/etc/pterodactyl"
BACKUP_DIR="/root/skylernodes-backups"
QUEUE_SERVICE="/etc/systemd/system/pteroq.service"
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
PHPMYADMIN_CONF="/etc/nginx/sites-available/phpmyadmin.conf"

R='\033[0m'; BLUE='\033[38;5;39m'; CYAN='\033[38;5;51m'; GREEN='\033[38;5;82m'
YELLOW='\033[38;5;220m'; RED='\033[38;5;203m'; PURPLE='\033[38;5;141m'; GRAY='\033[38;5;245m'; WHITE='\033[97m'

ok(){ echo -e "${GREEN}  ✓${R} $*"; }
info(){ echo -e "${CYAN}  •${R} $*"; }
warn(){ echo -e "${YELLOW}  !${R} $*"; }
die(){ echo -e "${RED}  ✗${R} $*" >&2; exit 1; }
pause(){ echo; read -r -p "  Press Enter to return..." _; }
trap 'die "Operation stopped at line $LINENO."' ERR

[[ $EUID -eq 0 ]] || die "Run this installer as root."
source /etc/os-release

case "${ID:-}" in
  ubuntu)
    case "${VERSION_ID:-}" in
      22.04|24.04) ;;
      *) die "Supported Ubuntu versions: 22.04 and 24.04." ;;
    esac
    OS_FAMILY="Ubuntu"
    ;;
  debian)
    case "${VERSION_ID:-}" in
      11|12|13) ;;
      *) die "Supported Debian versions: 11, 12 and 13." ;;
    esac
    OS_FAMILY="Debian"
    ;;
  *)
    die "Supported operating systems: Debian 11/12/13 or Ubuntu 22.04/24.04."
    ;;
esac

header(){
  clear 2>/dev/null || true
  echo -e "${BLUE}"
  cat <<'BANNER'
╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║             ███████╗██╗  ██╗██╗   ██╗██╗     ███████╗             ║
║             ██╔════╝██║ ██╔╝╚██╗ ██╔╝██║     ██╔════╝             ║
║             ███████╗█████╔╝  ╚████╔╝ ██║     █████╗               ║
║             ╚════██║██╔═██╗   ╚██╔╝  ██║     ██╔══╝               ║
║             ███████║██║  ██╗   ██║   ███████╗███████╗             ║
║             ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚══════╝             ║
║                                                                    ║
║                 S K Y L E R N O D E S                              ║
║             P T E R O D A C T Y L  I N S T A L L E R              ║
║                                                                    ║
║             FAST  •  CLEAN  •  AUTOMATIC  •  STABLE               ║
╚════════════════════════════════════════════════════════════════════╝
BANNER
  echo -e "${R}"
}

progress(){
  local label="$1" current="$2" total="${3:-100}"
  local width=28 filled empty bar=""
  filled=$(( current * width / total )); empty=$(( width - filled ))
  (( filled > 0 )) && bar=$(printf '%*s' "$filled" '' | tr ' ' '█')
  (( empty > 0 )) && bar="${bar}$(printf '%*s' "$empty" '' | tr ' ' '░')"
  printf "\r  ${BLUE}%-34s${R} [${CYAN}%s${R}] %3d%%" "$label" "$bar" "$current"
  [[ "$current" -ge "$total" ]] && echo -e " ${GREEN}✓${R}"
}
step(){
  local label="$1"
  progress "$label" 0
  for n in 20 40 60 80 100; do sleep 0.05; progress "$label" "$n"; done
}

random_pass(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true; }

set_env(){
  local key="$1" value="$2"
  if grep -qE "^${key}=" .env; then
    sed -i "s#^${key}=.*#${key}=${value}#" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

base_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y software-properties-common ca-certificates curl gnupg nginx mariadb-server redis-server cron git tar unzip openssl jq certbot python3-certbot-nginx
  add-apt-repository -y ppa:ondrej/php
  apt-get update
  apt-get install -y "$PHP_BIN" php8.3-cli php8.3-common php8.3-gd php8.3-mysql php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-fpm

  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer.php
    EXPECTED="$(curl -fsSL https://composer.github.io/installer.sig)"
    ACTUAL="$("$PHP_BIN" -r "echo hash_file('sha384','/tmp/composer.php');")"
    [[ "$EXPECTED" == "$ACTUAL" ]] || die "Composer checksum failed."
    "$PHP_BIN" /tmp/composer.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer.php
  fi
  composer self-update --2 >/dev/null 2>&1 || true
  systemctl enable --now nginx mariadb redis-server "$PHP_FPM_SERVICE" cron
}

db_setup(){
  DB_NAME="${DB_NAME:-panel}"
  DB_USER="${DB_USER:-pterodactyl}"
  DB_PASS="${DB_PASS:-$(random_pass)}"
  mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  cat > "$BACKUP_DIR/database.env" <<ENV
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
ENV
  chmod 600 "$BACKUP_DIR/database.env"
}

nginx_panel(){
  local domain="$1"
  cat > "$NGINX_CONF" <<EOF_NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    root ${PANEL_DIR}/public;
    index index.php;
    charset utf-8;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:"$PHP_FPM_SOCK";
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht { deny all; }
}
EOF_NGINX
  rm -f /etc/nginx/sites-enabled/default
  ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t && systemctl reload nginx
}

queue_setup(){
  cat > /etc/cron.d/pterodactyl <<EOF_CRON
* * * * * www-data "$PHP_BIN" ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1
EOF_CRON
  cat > "$QUEUE_SERVICE" <<EOF_SERVICE
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/"$PHP_BIN" ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload
  systemctl enable --now pteroq
}

panel_install(){
  header
  echo -e "${WHITE}  [1] INSTALL PANEL${R}"
  echo -e "  Fresh Pterodactyl Panel Installation"
  echo
  read -r -p "  Panel domain (example.com): " DOMAIN
  read -r -p "  Admin email: " ADMIN_EMAIL
  read -r -p "  Admin username [admin]: " ADMIN_USER; ADMIN_USER="${ADMIN_USER:-admin}"
  read -r -p "  Admin first name [Admin]: " ADMIN_FIRST; ADMIN_FIRST="${ADMIN_FIRST:-Admin}"
  read -r -p "  Admin last name [User]: " ADMIN_LAST; ADMIN_LAST="${ADMIN_LAST:-User}"
  read -r -s -p "  Admin password: " ADMIN_PASS; echo
  read -r -s -p "  Database password [blank = auto]: " DB_PASS; echo
  read -r -p "  Timezone [Asia/Kolkata]: " TZ; TZ="${TZ:-Asia/Kolkata}"
  read -r -p "  Install SSL now? [Y/n]: " SSL; SSL="${SSL:-Y}"

  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid domain."
  [[ "$ADMIN_EMAIL" == *@*.* ]] || die "Invalid email."
  [[ ${#ADMIN_PASS} -ge 8 ]] || die "Admin password must be at least 8 characters."

  echo
  echo -e "${PURPLE}  INSTALLATION PROGRESS${R}"
  step "Checking system requirements"
  info "Installing PHP, MariaDB, Redis, Nginx and Composer..."
  base_packages
  progress "Installing system dependencies" 100

  DB_NAME="panel"; DB_USER="pterodactyl"
  progress "Creating panel database" 20
  db_setup
  progress "Creating panel database" 100

  mkdir -p "$PANEL_DIR"; cd "$PANEL_DIR"
  info "Downloading the official Pterodactyl release..."
  progress "Downloading Pterodactyl Panel" 10
  curl -fL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
  tar -xzf panel.tar.gz; rm -f panel.tar.gz
  progress "Downloading Pterodactyl Panel" 100

  cp -n .env.example .env
  progress "Installing PHP dependencies" 10
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  progress "Installing PHP dependencies" 100
  "$PHP_BIN" artisan key:generate --force >/dev/null

  set_env APP_URL "http://${DOMAIN}"
  set_env APP_TIMEZONE "$TZ"
  set_env CACHE_DRIVER redis
  set_env SESSION_DRIVER redis
  set_env QUEUE_CONNECTION redis
  set_env REDIS_HOST 127.0.0.1
  set_env REDIS_PORT 6379
  set_env REDIS_PASSWORD null
  set_env DB_CONNECTION mysql
  set_env DB_HOST 127.0.0.1
  set_env DB_PORT 3306
  set_env DB_DATABASE "$DB_NAME"
  set_env DB_USERNAME "$DB_USER"
  set_env DB_PASSWORD "$DB_PASS"
  set_env MAIL_MAILER log
  "$PHP_BIN" artisan config:clear >/dev/null

  progress "Preparing database schema" 25
  "$PHP_BIN" artisan migrate --seed --force
  progress "Preparing database schema" 100

  chown -R www-data:www-data "$PANEL_DIR"
  chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"
  queue_setup
  progress "Configuring queue and scheduler" 100
  nginx_panel "$DOMAIN"
  progress "Configuring Nginx" 100

  if [[ "$SSL" =~ ^[Yy]$ ]]; then
    info "Requesting Let's Encrypt certificate..."
    certbot --nginx --non-interactive --agree-tos -m "$ADMIN_EMAIL" -d "$DOMAIN" || warn "SSL could not be issued. Use option 4 after DNS points to this VPS."
  fi

  "$PHP_BIN" artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --name-first="$ADMIN_FIRST" --name-last="$ADMIN_LAST" --password="$ADMIN_PASS" --admin=1
  cp "$PANEL_DIR/.env" "$BACKUP_DIR/panel.env"
  chmod 600 "$BACKUP_DIR/panel.env"

  echo
  echo -e "${GREEN}╭────────────────────────────────────────────────────────────╮${R}"
  echo -e "${GREEN}│${R}  ${WHITE}PTERODACTYL PANEL INSTALLED SUCCESSFULLY${R}                 ${GREEN}│${R}"
  echo -e "${GREEN}│${R}  URL: ${CYAN}$([[ "$SSL" =~ ^[Yy]$ ]] && echo "https" || echo "http")://${DOMAIN}${R}"
  echo -e "${GREEN}│${R}  Admin: ${CYAN}${ADMIN_EMAIL}${R}"
  echo -e "${GREEN}╰────────────────────────────────────────────────────────────╯${R}"
  pause
}

user_management(){
  header
  echo -e "${WHITE}  [2] USER MANAGEMENT${R}"
  echo -e "  Create Admin / User Accounts"
  echo
  echo "  [1] Create Admin"
  echo "  [2] Create User"
  echo "  [3] Delete User"
  echo "  [4] Disable 2FA"
  echo "  [0] Back"
  echo
  read -r -p "  Select: " X
  cd "$PANEL_DIR" 2>/dev/null || { warn "Panel is not installed."; pause; return; }
  case "$X" in
    1|2)
      read -r -p "  Email: " E; read -r -p "  Username: " U; read -r -p "  First name: " F; read -r -p "  Last name: " L; read -r -s -p "  Password: " P; echo
      [[ ${#P} -ge 8 ]] || { warn "Password must be at least 8 characters."; pause; return; }
      ADMIN_FLAG=0; [[ "$X" == "1" ]] && ADMIN_FLAG=1
      "$PHP_BIN" artisan p:user:make --email="$E" --username="$U" --name-first="$F" --name-last="$L" --password="$P" --admin="$ADMIN_FLAG"
      ;;
    3)
      read -r -p "  Username / email / UUID: " U; "$PHP_BIN" artisan p:user:delete --user="$U" ;;
    4)
      read -r -p "  User email: " E; "$PHP_BIN" artisan p:user:disable2fa --email="$E" ;;
  esac
  pause
}

panel_update(){
  header
  echo -e "${WHITE}  [3] PANEL UPDATE${R}"
  echo -e "  Update to a Pterodactyl Release"
  echo
  [[ -d "$PANEL_DIR" ]] || { warn "Panel is not installed."; pause; return; }
  cd "$PANEL_DIR"
  mkdir -p "$BACKUP_DIR"
  cp -f .env "$BACKUP_DIR/env-before-update-$(date +%Y%m%d-%H%M%S)"
  "$PHP_BIN" artisan down || true
  progress "Downloading latest release" 10
  curl -fL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xz
  progress "Downloading latest release" 100
  progress "Updating Composer dependencies" 20
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  progress "Updating Composer dependencies" 100
  "$PHP_BIN" artisan migrate --seed --force
  "$PHP_BIN" artisan optimize:clear
  chown -R www-data:www-data "$PANEL_DIR"
  "$PHP_BIN" artisan up
  ok "Panel update completed."
  pause
}

domain_ssl(){
  header
  echo -e "${WHITE}  [4] DOMAIN / SSL${R}"
  echo -e "  Configure Domain and SSL"
  echo
  [[ -d "$PANEL_DIR" ]] || { warn "Panel is not installed."; pause; return; }
  read -r -p "  New panel domain: " D
  read -r -p "  SSL email: " E
  [[ "$D" =~ ^[A-Za-z0-9.-]+$ ]] || { warn "Invalid domain."; pause; return; }
  nginx_panel "$D"
  sed -i "s#^APP_URL=.*#APP_URL=https://${D}#" "$PANEL_DIR/.env" || true
  (cd "$PANEL_DIR" && "$PHP_BIN" artisan config:clear >/dev/null)
  certbot --nginx --non-interactive --agree-tos -m "$E" -d "$D"
  ok "Domain and SSL configured."
  pause
}

uninstall_panel(){
  header
  echo -e "${WHITE}  [5] UNINSTALL PANEL${R}"
  echo -e "  Remove Panel Data and Configuration"
  echo
  warn "This removes the Pterodactyl panel files, Nginx config and queue service."
  warn "It does not remove system packages or automatically delete the database."
  read -r -p "  Type REMOVE to continue: " X
  [[ "$X" == "REMOVE" ]] || { echo "  Cancelled."; pause; return; }
  mkdir -p "$BACKUP_DIR"
  [[ -f "$PANEL_DIR/.env" ]] && cp "$PANEL_DIR/.env" "$BACKUP_DIR/uninstall-env-$(date +%Y%m%d-%H%M%S)"
  systemctl disable --now pteroq 2>/dev/null || true
  rm -f "$QUEUE_SERVICE" /etc/cron.d/pterodactyl /etc/nginx/sites-enabled/pterodactyl.conf "$NGINX_CONF"
  rm -rf "$PANEL_DIR"
  systemctl daemon-reload
  nginx -t && systemctl reload nginx || true
  ok "Panel data and configuration removed."
  pause
}

phpmyadmin_install(){
  header
  echo -e "${WHITE}  [6] PHPMYADMIN${R}"
  echo -e "  Database Management"
  echo
  if [[ -d /usr/share/phpmyadmin ]]; then
    ok "phpMyAdmin is already installed."
  else
    export DEBIAN_FRONTEND=noninteractive
    echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect' | debconf-set-selections
    echo 'phpmyadmin phpmyadmin/dbconfig-install boolean false' | debconf-set-selections
    progress "Installing phpMyAdmin" 10
    apt-get update
    apt-get install -y phpmyadmin
    progress "Installing phpMyAdmin" 100
  fi

  mkdir -p /etc/phpmyadmin
  if [[ ! -f /etc/phpmyadmin/config.inc.php ]]; then
    BLOWFISH="$(openssl rand -base64 32 | tr -d '=+/\n' | cut -c1-32)"
    cat > /etc/phpmyadmin/config.inc.php <<EOF_PM
<?php
\$cfg['blowfish_secret'] = '${BLOWFISH}';
\$cfg['Servers'][1]['auth_type'] = 'cookie';
\$cfg['Servers'][1]['host'] = '127.0.0.1';
\$cfg['Servers'][1]['port'] = '3306';
\$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';
EOF_PM
    mkdir -p /var/lib/phpmyadmin/tmp
    chown -R www-data:www-data /var/lib/phpmyadmin
  fi

  cat > "$PHPMYADMIN_CONF" <<'EOF_PMNGINX'
server {
    listen 8080;
    listen [::]:8080;
    server_name _;
    root /usr/share/phpmyadmin;
    index index.php;
    client_max_body_size 100M;
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:"$PHP_FPM_SOCK";
    }
    location ~ /\.ht { deny all; }
}
EOF_PMNGINX
  ln -sfn "$PHPMYADMIN_CONF" /etc/nginx/sites-enabled/phpmyadmin.conf
  nginx -t && systemctl reload nginx
  echo
  ok "phpMyAdmin is ready on: http://SERVER-IP:8080/"
  warn "For production, put phpMyAdmin behind a private VPN or a protected HTTPS domain."
  pause
}

status(){
  header
  echo -e "${WHITE}  SYSTEM STATUS${R}\n"
  for S in nginx mariadb redis-server php8.3-fpm pteroq; do
    if systemctl is-active --quiet "$S" 2>/dev/null; then echo -e "  ${GREEN}●${R} $S  ${GREEN}RUNNING${R}"; else echo -e "  ${RED}●${R} $S  ${GRAY}STOPPED / NOT INSTALLED${R}"; fi
  done
  pause
}

menu(){
  while true; do
    header
    echo -e "  ${WHITE}PANEL MANAGEMENT${R}"
    echo -e "  ${GRAY}────────────────────────────────────────────────────────────${R}"
    echo
    echo -e "  ${CYAN}[1]${R} ${WHITE}Install Panel${R}"
    echo -e "      ${GRAY}Fresh Pterodactyl Panel Installation${R}"
    echo
    echo -e "  ${CYAN}[2]${R} ${WHITE}User Management${R}"
    echo -e "      ${GRAY}Create Admin / User Accounts${R}"
    echo
    echo -e "  ${CYAN}[3]${R} ${WHITE}Panel Update${R}"
    echo -e "      ${GRAY}Update to a Pterodactyl Release${R}"
    echo
    echo -e "  ${CYAN}[4]${R} ${WHITE}Domain / SSL${R}"
    echo -e "      ${GRAY}Configure Domain and SSL${R}"
    echo
    echo -e "  ${CYAN}[5]${R} ${WHITE}Uninstall Panel${R}"
    echo -e "      ${GRAY}Remove Panel Data and Configuration${R}"
    echo
    echo -e "  ${CYAN}[6]${R} ${WHITE}phpMyAdmin${R}"
    echo -e "      ${GRAY}Database Management${R}"
    echo
    echo -e "  ${GRAY}────────────────────────────────────────────────────────────${R}"
    printf "  ${BLUE}SYSTEM${R}  Ubuntu %-5s  CPU %-3s  RAM %-12s  DISK %-12s\n" "${VERSION_ID}" "$(nproc 2>/dev/null || echo '?')" "$(free -h | awk '/^Mem:/ {print $3"/"$2}')" "$(df -h / | awk 'NR==2 {print $3"/"$2}')"
    echo
    echo -e "  ${GRAY}0) Exit${R}"
    echo
    read -r -p "  Select an option [0-6]: " N
    case "$N" in
      1) panel_install ;;
      2) user_management ;;
      3) panel_update ;;
      4) domain_ssl ;;
      5) uninstall_panel ;;
      6) phpmyadmin_install ;;
      7) status ;;
      0) clear 2>/dev/null || true; exit 0 ;;
      *) warn "Invalid option. Choose 0-6."; sleep 1 ;;
    esac
  done
}

menu

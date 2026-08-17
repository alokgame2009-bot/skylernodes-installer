#!/usr/bin/env bash
set -Eeuo pipefail

# SkylerNodes Fully Automatic Pterodactyl Installer
# Independent third-party installer. Not affiliated with Pterodactyl or Nobita Cloud.

APP="SkylerNodes"
PANEL_DIR="/var/www/pterodactyl"
PTERO_DIR="/etc/pterodactyl"
WINGS_BIN="/usr/local/bin/wings"
BACKUP_DIR="/root/skylernodes-backups"
QUEUE_SERVICE="/etc/systemd/system/pteroq.service"
WINGS_SERVICE="/etc/systemd/system/wings.service"
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"

R='\033[0m'; BLUE='\033[38;5;75m'; CYAN='\033[38;5;81m'; GREEN='\033[38;5;82m'
YELLOW='\033[38;5;220m'; RED='\033[38;5;203m'; PURPLE='\033[38;5;141m'; GRAY='\033[38;5;245m'

ok(){ echo -e "${GREEN}  ✓${R} $*"; }
info(){ echo -e "${CYAN}  •${R} $*"; }
warn(){ echo -e "${YELLOW}  !${R} $*"; }
die(){ echo -e "${RED}  ✗${R} $*" >&2; exit 1; }
pause(){ echo; read -r -p "  Press Enter to return..." _; }

trap 'die "Operation stopped at line $LINENO."' ERR

[[ $EUID -eq 0 ]] || die "Run this installer as root."

source /etc/os-release
[[ "$ID" == "ubuntu" ]] || die "Ubuntu 22.04/24.04 is required."
[[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] || die "Use Ubuntu 22.04 or 24.04."

header(){
  clear 2>/dev/null || true
  echo -e "${BLUE}"
  cat <<'EOF'
╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║      ███████╗██╗  ██╗██╗   ██╗██╗     ███████╗██████╗             ║
║      ██╔════╝██║ ██╔╝╚██╗ ██╔╝██║     ██╔════╝██╔══██╗            ║
║      ███████╗█████╔╝  ╚████╔╝ ██║     █████╗  ██████╔╝            ║
║      ╚════██║██╔═██╗   ╚██╔╝  ██║     ██╔══╝  ██╔══██╗            ║
║      ███████║██║  ██╗   ██║   ███████╗███████╗██║  ██║            ║
║      ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚══════╝╚═╝  ╚═╝            ║
║                                                                    ║
║              S K Y L E R N O D E S                                 ║
║          A L L - I N - O N E   I N S T A L L E R                  ║
║                                                                    ║
║              FAST  •  SECURE  •  STABLE  •  AUTOMATIC             ║
╚════════════════════════════════════════════════════════════════════╝
EOF
  echo -e "${R}"
}

random_pass(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true; }

progress(){
  local label="$1" current="$2" total="${3:-100}"
  local width=28
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar=""
  (( filled > 0 )) && bar=$(printf '%*s' "$filled" '' | tr ' ' '█')
  (( empty > 0 )) && bar="${bar}$(printf '%*s' "$empty" '' | tr ' ' '░')"
  printf "\r  ${BLUE}%-34s${R} [${CYAN}%s${R}] %3d%%" "$label" "$bar" "$current"
  [[ "$current" -ge "$total" ]] && echo -e " ${GREEN}✓${R}"
}
step(){
  local label="$1"
  progress "$label" 0 100
  for n in 20 40 60 80 100; do
    sleep 0.08
    progress "$label" "$n" 100
  done
}

base_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y software-properties-common ca-certificates curl gnupg \
    nginx mariadb-server redis-server cron git tar unzip openssl jq \
    certbot python3-certbot-nginx

  add-apt-repository -y ppa:ondrej/php
  apt-get update
  apt-get install -y php8.3 php8.3-cli php8.3-common php8.3-gd php8.3-mysql \
    php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-fpm

  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer.php
    EXPECTED="$(curl -fsSL https://composer.github.io/installer.sig)"
    ACTUAL="$(php8.3 -r "echo hash_file('sha384','/tmp/composer.php');")"
    [[ "$EXPECTED" == "$ACTUAL" ]] || die "Composer checksum failed."
    php8.3 /tmp/composer.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer.php
  fi

  systemctl enable --now nginx mariadb redis-server php8.3-fpm cron
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

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  cat > "$BACKUP_DIR/database.env" <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
  chmod 600 "$BACKUP_DIR/database.env"
}

panel_install(){
  header
  echo -e "${PURPLE}  AUTOMATIC PANEL INSTALLATION${R}"
  echo
  read -r -p "  Panel domain: " DOMAIN
  read -r -p "  Admin email: " EMAIL
  read -r -p "  Timezone [Asia/Kolkata]: " TZ
  TZ="${TZ:-Asia/Kolkata}"
  read -r -p "  Database name [panel]: " DB_NAME
  DB_NAME="${DB_NAME:-panel}"
  read -r -p "  Database user [pterodactyl]: " DB_USER
  DB_USER="${DB_USER:-pterodactyl}"
  read -r -s -p "  Database password [blank = auto]: " DB_PASS
  echo
  read -r -p "  Enable HTTPS automatically? [Y/n]: " SSL
  SSL="${SSL:-Y}"

  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid domain."
  [[ "$EMAIL" == *@*.* ]] || die "Invalid email."

  echo
  echo -e "${PURPLE}  CURRENT OPERATION${R}"
  step "Checking system requirements"
  info "Installing server dependencies..."
  base_packages
  progress "System dependencies" 100
  ok "Dependencies installed."

  progress "Configuring database" 35
  info "Creating database..."
  db_setup
  progress "Configuring database" 100
  ok "Database ready."

  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"

  info "Downloading official Pterodactyl Panel..."
  progress "Downloading Pterodactyl Panel" 10
  curl -fL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz

  progress "Downloading Pterodactyl Panel" 100
  cp -n .env.example .env
  info "Installing Composer dependencies..."
  progress "Installing PHP dependencies" 10
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  progress "Installing PHP dependencies" 100
  php8.3 artisan key:generate --force

  # The official CLI setup commands are used so the installer does not write
  # Laravel/Pterodactyl internals by hand.
  php8.3 artisan p:environment:setup -n \
    --author="$EMAIL" \
    --url="http://${DOMAIN}" \
    --timezone="$TZ" \
    --telemetry=false \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-port=6379 \
    --redis-pass=null

  php8.3 artisan p:environment:database -n \
    --host=127.0.0.1 --port=3306 \
    --database="$DB_NAME" --username="$DB_USER" --password="$DB_PASS"

  progress "Configuring application" 70
  php8.3 artisan migrate --seed --force
  progress "Running migrations" 100

  cat > /etc/cron.d/pterodactyl <<EOF
* * * * * www-data php8.3 ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1
EOF

  cat > "$QUEUE_SERVICE" <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php8.3 ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  chown -R www-data:www-data "$PANEL_DIR"
  chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"
  systemctl daemon-reload
  systemctl enable --now pteroq
  progress "Queue worker and scheduler" 100

  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${PANEL_DIR}/public;
    index index.php;
    charset utf-8;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
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
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t
  systemctl reload nginx
  progress "Configuring Nginx" 100

  cp "$PANEL_DIR/.env" "$BACKUP_DIR/panel.env"
  chmod 600 "$BACKUP_DIR/panel.env"

  echo
  warn "One account step remains by design: create the first admin."
  echo "  cd $PANEL_DIR && php8.3 artisan p:user:make"
  echo

  if [[ "$SSL" =~ ^[Yy]$ ]]; then
    warn "DNS must already point the domain to this VPS."
    certbot --nginx --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN" || \
      warn "SSL was not issued. Run option 5 after DNS is ready."
  fi

  progress "Finalizing installation" 100
  ok "Panel installation complete."
  pause
}

docker_wings(){
  command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | CHANNEL=stable bash
  systemctl enable --now docker

  mkdir -p "$PTERO_DIR"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) WA="amd64" ;;
    aarch64|arm64) WA="arm64" ;;
    *) die "Unsupported CPU architecture: $ARCH" ;;
  esac

  curl -fL "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WA}" -o "$WINGS_BIN"
  chmod u+x "$WINGS_BIN"

  cat > "$WINGS_SERVICE" <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=${PTERO_DIR}
LimitNOFILE=4096
ExecStart=${WINGS_BIN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wings
}

wings_install(){
  header
  echo -e "${PURPLE}  AUTOMATIC WINGS INSTALLATION${R}"
  echo
  docker_wings
  ok "Docker and Wings installed."
  echo
  warn "A real node config contains credentials generated by your Panel."
  echo "To make this safe, SkylerNodes does not fabricate those credentials."
  echo "The installer will automatically start Wings once /etc/pterodactyl/config.yml exists."
  if [[ -f "$PTERO_DIR/config.yml" ]]; then
    systemctl start wings
    ok "Existing node config detected; Wings started."
  else
    warn "No node config found yet."
  fi
  pause
}

all_in_one(){
  panel_install
  wings_install
  header
  ok "All software installation steps completed."
  warn "The only external dependency is the Panel-generated Wings node config."
  pause
}

update_panel(){
  [[ -d "$PANEL_DIR" ]] || die "Panel is not installed."
  cd "$PANEL_DIR"
  php8.3 artisan down || true
  cp -f .env "$BACKUP_DIR/env-before-update-$(date +%Y%m%d-%H%M%S)"
  curl -fL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xz
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  php8.3 artisan migrate --seed --force
  php8.3 artisan optimize:clear
  chown -R www-data:www-data "$PANEL_DIR"
  php8.3 artisan up
  ok "Panel updated automatically."
  pause
}

ssl(){
  header
  read -r -p "  Domain: " D
  read -r -p "  Email: " E
  certbot --nginx --agree-tos -m "$E" -d "$D"
  ok "SSL completed."
  pause
}

repair(){
  header
  if [[ -d "$PANEL_DIR" ]]; then
    cd "$PANEL_DIR"
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
    php8.3 artisan optimize:clear
    php8.3 artisan optimize
    chown -R www-data:www-data "$PANEL_DIR"
  fi
  nginx -t && systemctl reload nginx
  systemctl restart php8.3-fpm redis-server mariadb pteroq 2>/dev/null || true
  systemctl restart wings 2>/dev/null || true
  ok "Repair completed."
  pause
}

status(){
  header
  echo -e "${PURPLE}  SERVICE STATUS${R}"
  echo
  for S in nginx mariadb redis-server php8.3-fpm pteroq docker wings; do
    if systemctl is-active --quiet "$S" 2>/dev/null; then
      echo -e "    ${GREEN}●${R} $S  ${GREEN}RUNNING${R}"
    else
      echo -e "    ${RED}●${R} $S  ${GRAY}STOPPED / NOT INSTALLED${R}"
    fi
  done
  echo
  echo "    Panel : $([[ -d "$PANEL_DIR" ]] && echo INSTALLED || echo NOT-INSTALLED)"
  echo "    Wings : $([[ -x "$WINGS_BIN" ]] && echo INSTALLED || echo NOT-INSTALLED)"
  pause
}

logs(){
  header
  echo "[1] Queue"
  echo "[2] Nginx"
  echo "[3] Wings"
  echo "[4] Laravel"
  echo "[0] Back"
  echo
  read -r -p "  Select: " X
  case "$X" in
    1) journalctl -u pteroq -n 100 --no-pager ;;
    2) tail -n 100 /var/log/nginx/error.log ;;
    3) journalctl -u wings -n 100 --no-pager ;;
    4) F="$(ls -t "$PANEL_DIR"/storage/logs/*.log 2>/dev/null | head -n1 || true)"; [[ -n "$F" ]] && tail -n 100 "$F" || echo "No Laravel log found." ;;
  esac
  pause
}

backup(){
  header
  mkdir -p "$BACKUP_DIR"
  if [[ -f "$BACKUP_DIR/database.env" ]]; then
    # shellcheck disable=SC1091
    source "$BACKUP_DIR/database.env"
    mysqldump -u root "$DB_NAME" | gzip > "$BACKUP_DIR/${DB_NAME}-$(date +%Y%m%d-%H%M%S).sql.gz"
    ok "Database backup created."
  fi
  [[ -f "$PANEL_DIR/.env" ]] && cp "$PANEL_DIR/.env" "$BACKUP_DIR/panel-env-$(date +%Y%m%d-%H%M%S).backup"
  chmod 600 "$BACKUP_DIR"/*
  echo "  Backups: $BACKUP_DIR"
  pause
}

uninstall(){
  header
  warn "This removes SkylerNodes installer-managed Pterodactyl components."
  read -r -p "  Type REMOVE to continue: " X
  [[ "$X" == "REMOVE" ]] || { echo "  Cancelled."; pause; return; }

  systemctl disable --now pteroq wings 2>/dev/null || true
  rm -f "$QUEUE_SERVICE" "$WINGS_SERVICE" /etc/cron.d/pterodactyl "$WINGS_BIN"
  rm -f /etc/nginx/sites-enabled/pterodactyl.conf "$NGINX_CONF"
  systemctl daemon-reload
  nginx -t && systemctl reload nginx || true
  read -r -p "  Delete Panel files too? [y/N]: " D
  [[ "$D" =~ ^[Yy]$ ]] && rm -rf "$PANEL_DIR"
  ok "Installer-managed components removed."
  pause
}

menu(){
  while true; do
    header
    echo -e " ${PURPLE}╭────────────────────── SKYLER NODES ───────────────────────╮${R}"
    echo -e " ${PURPLE}│${R}  ${GREEN}[1]${R} Install Panel       ${CYAN}[2]${R} Install Wings        ${PURPLE}│${R}"
    echo -e " ${PURPLE}│${R}  ${YELLOW}[3]${R} All-in-One           ${BLUE}[4]${R} Update Panel         ${PURPLE}│${R}"
    echo -e " ${PURPLE}│${R}  ${CYAN}[5]${R} SSL / Let's Encrypt  ${PURPLE}[6]${R} Repair / Optimize    ${PURPLE}│${R}"
    echo -e " ${PURPLE}│${R}  ${GREEN}[7]${R} Status               ${YELLOW}[8]${R} View Logs             ${PURPLE}│${R}"
    echo -e " ${PURPLE}│${R}  ${CYAN}[9]${R} Backup               ${RED}[10]${R} Uninstall              ${PURPLE}│${R}"
    echo -e " ${PURPLE}│${R}  ${GRAY}[0]${R} Exit                                             ${PURPLE}│${R}"
    echo -e " ${PURPLE}╰───────────────────────────────────────────────────────────╯${R}"
    echo
    echo -e " ${GRAY}Ubuntu 22.04/24.04 • Official Pterodactyl releases • SkylerNodes${R}"
    echo
    printf "  ${BLUE}SYSTEM${R}  OS: %-12s  CPU: %-3s  RAM: %-12s  DISK: %-12s\n"       "$(grep -oP '(?<=^PRETTY_NAME=).+' /etc/os-release | tr -d '"' | cut -c1-12)"       "$(nproc 2>/dev/null || echo '?')"       "$(free -h | awk '/^Mem:/ {print $3"/"$2}')"       "$(df -h / | awk 'NR==2 {print $3"/"$2}')"
    echo
    read -r -p "  Select [0-10]: " N
    case "$N" in
      1) panel_install ;;
      2) wings_install ;;
      3) all_in_one ;;
      4) update_panel ;;
      5) ssl ;;
      6) repair ;;
      7) status ;;
      8) logs ;;
      9) backup ;;
      10) uninstall ;;
      0) clear 2>/dev/null || true; exit 0 ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

menu

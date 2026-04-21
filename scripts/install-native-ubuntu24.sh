#!/usr/bin/env bash
# =============================================================================
# Coolify native one-shot installer — Ubuntu 24.04 (noble) only
#
# NOT the official supported install path (Docker: scripts/install.sh).
# Run as root:  curl -fsSL .../install-native-ubuntu24.sh | bash
#           or:  sudo bash scripts/install-native-ubuntu24.sh
#
# Environment overrides (optional):
#   COOLIFY_INSTALL_DIR=/var/www/coolify
#   COOLIFY_GIT_URL=https://github.com/coollabsio/coolify.git
#   COOLIFY_GIT_REF=next
#   COOLIFY_APP_URL=https://deploywerk.orbytals.com   (default; no trailing slash required)
#   COOLIFY_LETSENCRYPT_EMAIL=you@example.com         (required for Certbot unless SKIP)
#   COOLIFY_SKIP_LETSENCRYPT=0                        set to 1 to skip TLS (HTTP only)
#   COOLIFY_RESOLVE_CONFLICTS=1                       stop/disable apache2/caddy if present
#   COOLIFY_IGNORE_PORT_CONFLICT=0                    set to 1 to continue if port 80/443 busy
#   COOLIFY_DB_PASSWORD=   (generated if empty)
#   COOLIFY_DB_USER=coolify
#   COOLIFY_DB_NAME=coolify
#   COOLIFY_UPDATE_EXISTING=0   set to 1 to git pull when install dir already exists
#   COOLIFY_RESET_DB=0          set to 1 to DROP DATABASE (destructive) before create
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

COOLIFY_INSTALL_DIR="${COOLIFY_INSTALL_DIR:-/var/www/coolify}"
COOLIFY_GIT_URL="${COOLIFY_GIT_URL:-https://github.com/coollabsio/coolify.git}"
COOLIFY_GIT_REF="${COOLIFY_GIT_REF:-next}"
COOLIFY_APP_URL="${COOLIFY_APP_URL:-https://deploywerk.orbytals.com}"
COOLIFY_LETSENCRYPT_EMAIL="${COOLIFY_LETSENCRYPT_EMAIL:-}"
COOLIFY_SKIP_LETSENCRYPT="${COOLIFY_SKIP_LETSENCRYPT:-0}"
COOLIFY_RESOLVE_CONFLICTS="${COOLIFY_RESOLVE_CONFLICTS:-1}"
COOLIFY_IGNORE_PORT_CONFLICT="${COOLIFY_IGNORE_PORT_CONFLICT:-0}"
COOLIFY_DB_USER="${COOLIFY_DB_USER:-coolify}"
COOLIFY_DB_NAME="${COOLIFY_DB_NAME:-coolify}"
COOLIFY_DB_PASSWORD="${COOLIFY_DB_PASSWORD:-}"
COOLIFY_UPDATE_EXISTING="${COOLIFY_UPDATE_EXISTING:-0}"
COOLIFY_RESET_DB="${COOLIFY_RESET_DB:-0}"
NODE_MAJOR="${NODE_MAJOR:-24}"

# Derived from COOLIFY_APP_URL (set in resolve_app_domain)
COOLIFY_DOMAIN=""
COOLIFY_URL_SCHEME=""

log() { printf '[coolify-install] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    die "Run as root (sudo)."
  fi
}

preflight_os() {
  [[ -f /etc/os-release ]] || die "Missing /etc/os-release"
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script only supports Ubuntu (found ID=$ID)."
  if [[ "${VERSION_ID:-}" != "24.04" ]] && [[ "${VERSION_CODENAME:-}" != "noble" ]]; then
    die "This script only supports Ubuntu 24.04 (noble). Found VERSION_ID=${VERSION_ID:-} VERSION_CODENAME=${VERSION_CODENAME:-}"
  fi
}

resolve_app_domain() {
  IFS=' ' read -r COOLIFY_DOMAIN COOLIFY_URL_SCHEME < <(
    COOLIFY_APP_URL="${COOLIFY_APP_URL}" python3 -c "
from urllib.parse import urlparse
import os
u = urlparse(os.environ['COOLIFY_APP_URL'])
host = u.hostname or '127.0.0.1'
scheme = 'https' if u.scheme == 'https' else 'http'
print(host + ' ' + scheme)
"
  )
  export COOLIFY_DOMAIN COOLIFY_URL_SCHEME
  [[ -n "${COOLIFY_DOMAIN}" ]] || die "Could not parse hostname from COOLIFY_APP_URL"
}

port_listeners_summary() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E ':(80|443)\s' || true
  fi
}

resolve_conflicts() {
  log "Checking for conflicting web stacks (Apache, Caddy) and ports 80/443…"

  if [[ "${COOLIFY_RESOLVE_CONFLICTS}" == "1" ]]; then
    for svc in apache2 caddy; do
      if systemctl list-unit-files --type=service 2>/dev/null | grep -qE "^${svc}.service"; then
        if systemctl is-active --quiet "${svc}" 2>/dev/null || systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
          log "Stopping and disabling ${svc} (conflicts with Nginx on 80/443)…"
          systemctl stop "${svc}" 2>/dev/null || true
          systemctl disable "${svc}" 2>/dev/null || true
        fi
      fi
    done
    # Apache may still be installed but inactive; ensure not started on boot
    if dpkg -l apache2 2>/dev/null | grep -q '^ii'; then
      log "Apache2 package is installed; stopping/disabling units…"
      systemctl stop apache2 2>/dev/null || true
      systemctl disable apache2 2>/dev/null || true
    fi
  fi

  # After stopping known stacks, ports 80/443 must be free for Nginx + Certbot (unless ignored)
  if [[ "${COOLIFY_IGNORE_PORT_CONFLICT}" != "1" ]]; then
    if ss -ltn 2>/dev/null | grep -qE ':80\s'; then
      log "Something is still listening on TCP port 80:"
      port_listeners_summary
      die "Stop that service (or Docker publish on :80), then re-run. Or set COOLIFY_IGNORE_PORT_CONFLICT=1 (risky)."
    fi
    if [[ "${COOLIFY_SKIP_LETSENCRYPT}" != "1" ]] && [[ "${COOLIFY_URL_SCHEME}" == "https" ]]; then
      if ss -ltn 2>/dev/null | grep -qE ':443\s'; then
        log "Something is listening on TCP port 443:"
        port_listeners_summary
        die "Free port 443 for TLS or set COOLIFY_IGNORE_PORT_CONFLICT=1."
      fi
    fi
  fi
}

banner() {
  cat <<'BANNER'

***************************************************************************
  Coolify NATIVE installer (Ubuntu 24.04)
  This is NOT the official Docker-based installer.
  You are responsible for TLS, firewall, backups, and upgrades.
***************************************************************************

BANNER
}

apt_install_base() {
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release software-properties-common \
    acl git unzip \
    postgresql redis-server nginx supervisor \
    python3 python3-minimal openssl
  # Certbot (Let's Encrypt) — installed here; run after Nginx site exists unless skipped
  if [[ "${COOLIFY_SKIP_LETSENCRYPT}" != "1" ]] && [[ "${COOLIFY_URL_SCHEME}" == "https" ]]; then
    apt-get install -y --no-install-recommends certbot python3-certbot-nginx
  fi
}

add_php_ppa_and_packages() {
  if ! dpkg -l | grep -q '^ii  php8.4-cli'; then
    log "Adding Ondrej PHP PPA (PHP 8.4)…"
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y
  fi
  apt-get install -y --no-install-recommends \
    php8.4-cli php8.4-fpm php8.4-common \
    php8.4-pgsql php8.4-redis php8.4-mbstring php8.4-xml php8.4-curl \
    php8.4-zip php8.4-intl php8.4-bcmath php8.4-gd php8.4-readline
}

install_composer() {
  if command -v composer >/dev/null 2>&1; then
    return 0
  fi
  log "Installing Composer to /usr/local/bin/composer…"
  php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f /tmp/composer-setup.php
  chmod +x /usr/local/bin/composer
}

install_node_nodesource() {
  if command -v node >/dev/null 2>&1 && [[ "$(node -v 2>/dev/null || true)" == v${NODE_MAJOR}* ]]; then
    return 0
  fi
  log "Installing Node.js ${NODE_MAJOR}.x (NodeSource)…"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
}

ensure_db_password() {
  if [[ -z "${COOLIFY_DB_PASSWORD}" ]]; then
    COOLIFY_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  fi
  export COOLIFY_DB_PASSWORD
}

postgres_setup() {
  local pass_escaped
  pass_escaped="${COOLIFY_DB_PASSWORD//\'/\'\'}"
  systemctl enable --now postgresql

  if [[ "${COOLIFY_RESET_DB}" == "1" ]]; then
    log "COOLIFY_RESET_DB=1: dropping database ${COOLIFY_DB_NAME} (if exists)…"
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${COOLIFY_DB_NAME}\";" || true
  fi

  if ! sudo -u postgres psql -Atqc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='${COOLIFY_DB_USER}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE USER \"${COOLIFY_DB_USER}\" WITH PASSWORD '${pass_escaped}';"
  fi

  if ! sudo -u postgres psql -Atqc "SELECT 1 FROM pg_database WHERE datname='${COOLIFY_DB_NAME}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${COOLIFY_DB_NAME}\" OWNER \"${COOLIFY_DB_USER}\";"
  fi

  # Ensure password matches on re-runs (ALTER if user already existed with old password)
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"${COOLIFY_DB_USER}\" WITH LOGIN PASSWORD '${pass_escaped}';"
}

redis_enable() {
  systemctl enable --now redis-server
}

clone_or_update_app() {
  local parent
  parent="$(dirname "${COOLIFY_INSTALL_DIR}")"
  mkdir -p "${parent}"

  if [[ -d "${COOLIFY_INSTALL_DIR}/.git" ]]; then
    if [[ "${COOLIFY_UPDATE_EXISTING}" == "1" ]]; then
      log "Updating existing clone…"
      git -C "${COOLIFY_INSTALL_DIR}" fetch --all --prune
      git -C "${COOLIFY_INSTALL_DIR}" checkout "${COOLIFY_GIT_REF}"
      git -C "${COOLIFY_INSTALL_DIR}" pull --ff-only || die "git pull failed"
    else
      die "Install directory already exists: ${COOLIFY_INSTALL_DIR}. Set COOLIFY_UPDATE_EXISTING=1 to pull, or remove the directory."
    fi
  elif [[ -e "${COOLIFY_INSTALL_DIR}" ]]; then
    die "Path exists but is not a git repo: ${COOLIFY_INSTALL_DIR}"
  else
    log "Cloning ${COOLIFY_GIT_URL} (${COOLIFY_GIT_REF})…"
    git clone --branch "${COOLIFY_GIT_REF}" --single-branch "${COOLIFY_GIT_URL}" "${COOLIFY_INSTALL_DIR}"
  fi

  chown -R www-data:www-data "${COOLIFY_INSTALL_DIR}"
  if ! sudo -u www-data git -C "${COOLIFY_INSTALL_DIR}" config --global --get-all safe.directory 2>/dev/null | grep -qx "${COOLIFY_INSTALL_DIR}"; then
    sudo -u www-data git config --global --add safe.directory "${COOLIFY_INSTALL_DIR}"
  fi
}

write_env() {
  local pusher_host="${COOLIFY_DOMAIN}"

  local env_src="${COOLIFY_INSTALL_DIR}/.env.development.example"
  [[ -f "${env_src}" ]] || die "Missing ${env_src}"

  sudo -u www-data cp -f "${env_src}" "${COOLIFY_INSTALL_DIR}/.env"

  # Core Laravel / DB / Redis (native loopback)
  sudo -u www-data sed -i \
    -e "s|^APP_ENV=.*|APP_ENV=production|" \
    -e "s|^APP_DEBUG=.*|APP_DEBUG=false|" \
    -e "s#^APP_URL=.*#APP_URL=${COOLIFY_APP_URL}#g" \
    -e "s|^APP_KEY=.*|APP_KEY=|" \
    -e "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" \
    -e "s|^DB_PORT=.*|DB_PORT=5432|" \
    -e "s|^DB_DATABASE=.*|DB_DATABASE=${COOLIFY_DB_NAME}|" \
    -e "s|^DB_USERNAME=.*|DB_USERNAME=${COOLIFY_DB_USER}|" \
    -e "s#^DB_PASSWORD=.*#DB_PASSWORD=${COOLIFY_DB_PASSWORD}#g" \
    -e "s|^REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" \
    -e "s|^REDIS_PORT=.*|REDIS_PORT=6379|" \
    "${COOLIFY_INSTALL_DIR}/.env"

  # Pusher: browser uses public host; PHP uses loopback to Soketi. Scheme matches public site (ws vs wss).
  sudo -u www-data sed -i \
    -e "s|^PUSHER_HOST=.*|PUSHER_HOST=${pusher_host}|" \
    -e "s|^PUSHER_PORT=.*|PUSHER_PORT=6001|" \
    -e "s|^PUSHER_SCHEME=.*|PUSHER_SCHEME=${COOLIFY_URL_SCHEME}|" \
    -e "s|^PUSHER_BACKEND_HOST=.*|PUSHER_BACKEND_HOST=127.0.0.1|" \
    -e "s|^PUSHER_BACKEND_PORT=.*|PUSHER_BACKEND_PORT=6001|" \
    "${COOLIFY_INSTALL_DIR}/.env"

  log "Generating APP_KEY…"
  sudo -u www-data bash -lc "cd '${COOLIFY_INSTALL_DIR}' && php artisan key:generate --force --no-interaction"
}

composer_npm_artisan() {
  local d="${COOLIFY_INSTALL_DIR}"
  log "composer install (production)…"
  sudo -u www-data bash -lc "cd '${d}' && composer install --no-dev --optimize-autoloader --no-interaction"

  log "npm ci && npm run build…"
  sudo -u www-data bash -lc "cd '${d}' && npm ci && npm run build"

  log "Laravel bootstrap…"
  sudo -u www-data bash -lc "cd '${d}' && php artisan storage:link" || true
  sudo -u www-data bash -lc "cd '${d}' && php artisan migrate --force --no-interaction"
  sudo -u www-data bash -lc "cd '${d}' && php artisan config:cache && php artisan route:cache && php artisan view:cache"

  chown -R www-data:www-data "${d}/storage" "${d}/bootstrap/cache"
  chmod -R ug+rwx "${d}/storage" "${d}/bootstrap/cache"
}

install_soketi_global() {
  npm install -g @soketi/soketi
}

write_soketi_env_and_unit() {
  mkdir -p /etc/coolify
  local soketi_bin
  soketi_bin="$(command -v soketi || true)"
  [[ -n "${soketi_bin}" ]] || die "soketi binary not found after npm install -g"

  cat >/etc/coolify/soketi.env <<ENVFILE
SOKETI_DEBUG=false
SOKETI_HOST=0.0.0.0
SOKETI_DEFAULT_APP_ID=coolify
SOKETI_DEFAULT_APP_KEY=coolify
SOKETI_DEFAULT_APP_SECRET=coolify
ENVFILE
  chmod 640 /etc/coolify/soketi.env
  chown root:www-data /etc/coolify/soketi.env

  cat >/etc/systemd/system/coolify-soketi.service <<'UNIT'
[Unit]
Description=Coolify Soketi (Pusher-compatible websocket server)
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
EnvironmentFile=/etc/coolify/soketi.env
ExecStart=/usr/bin/env soketi start
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

  # Replace ExecStart with absolute path (env resolves soketi from PATH for www-data may miss /usr/bin)
  sed -i "s#^ExecStart=.*#ExecStart=${soketi_bin} start#" /etc/systemd/system/coolify-soketi.service

  systemctl daemon-reload
  systemctl enable --now coolify-soketi.service
}

write_nginx_site() {
  local root="${COOLIFY_INSTALL_DIR}/public"
  local sock="/run/php/php8.4-fpm.sock"

  cat >/etc/nginx/sites-available/coolify <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${COOLIFY_DOMAIN};
    root ${root};
    index index.php;
    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${sock};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX

  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  ln -sf /etc/nginx/sites-available/coolify /etc/nginx/sites-enabled/coolify
  nginx -t
  systemctl reload nginx
}

letsencrypt_certify() {
  if [[ "${COOLIFY_SKIP_LETSENCRYPT}" == "1" ]]; then
    log "COOLIFY_SKIP_LETSENCRYPT=1: skipping Let's Encrypt (Certbot)."
    return 0
  fi
  if [[ "${COOLIFY_URL_SCHEME}" != "https" ]]; then
    log "COOLIFY_APP_URL is not https; skipping Certbot."
    return 0
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    log "certbot not installed; skipping TLS obtain step."
    return 0
  fi
  [[ -n "${COOLIFY_LETSENCRYPT_EMAIL}" ]] || die "HTTPS is configured but COOLIFY_LETSENCRYPT_EMAIL is empty. Set it for Let's Encrypt (ACME account) or use COOLIFY_SKIP_LETSENCRYPT=1."

  log "Obtaining TLS certificate via Certbot (nginx plugin) for ${COOLIFY_DOMAIN}…"
  log "Ensure DNS A/AAAA for ${COOLIFY_DOMAIN} points to this server before this step."
  certbot --nginx -d "${COOLIFY_DOMAIN}" --non-interactive --agree-tos --redirect -m "${COOLIFY_LETSENCRYPT_EMAIL}"

  systemctl enable certbot.timer 2>/dev/null || true
  systemctl start certbot.timer 2>/dev/null || true

  log "Refreshing Laravel caches after TLS…"
  sudo -u www-data bash -lc "cd '${COOLIFY_INSTALL_DIR}' && php artisan config:cache && php artisan route:cache && php artisan view:cache"
}

write_supervisor_horizon() {
  cat >/etc/supervisor/conf.d/coolify-horizon.conf <<SUP
[program:coolify-horizon]
process_name=%(program_name)s
command=php ${COOLIFY_INSTALL_DIR}/artisan horizon
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${COOLIFY_INSTALL_DIR}/storage/logs/horizon.log
stopwaitsecs=3600
SUP
  mkdir -p "${COOLIFY_INSTALL_DIR}/storage/logs"
  chown www-data:www-data "${COOLIFY_INSTALL_DIR}/storage/logs"

  supervisorctl reread
  supervisorctl update
  if supervisorctl status coolify-horizon 2>/dev/null | grep -q RUNNING; then
    supervisorctl restart coolify-horizon
  else
    supervisorctl start coolify-horizon || true
  fi
}

write_cron_schedule() {
  local marker="# coolify-native-install-scheduler"
  local cron_file="/etc/cron.d/coolify-scheduler"
  if [[ -f "${cron_file}" ]] && grep -qF "${marker}" "${cron_file}"; then
    return 0
  fi
  cat >"${cron_file}" <<CRON
${marker}
* * * * * www-data cd ${COOLIFY_INSTALL_DIR} && /usr/bin/php artisan schedule:run >> /dev/null 2>&1
CRON
  chmod 644 "${cron_file}"
}

enable_services() {
  systemctl enable --now php8.4-fpm nginx redis-server postgresql supervisor
}

main() {
  banner
  require_root
  preflight_os
  resolve_app_domain
  resolve_conflicts

  log "Installing APT packages and PHP 8.4 (Ondrej PPA)…"
  apt_install_base
  add_php_ppa_and_packages

  install_composer
  install_node_nodesource

  ensure_db_password
  postgres_setup
  redis_enable

  clone_or_update_app
  write_env

  install_soketi_global
  write_soketi_env_and_unit

  composer_npm_artisan

  enable_services
  write_nginx_site
  letsencrypt_certify
  write_supervisor_horizon
  write_cron_schedule

  log "Done. Application URL: ${COOLIFY_APP_URL}"
  log "Database user: ${COOLIFY_DB_USER}  database: ${COOLIFY_DB_NAME}  (password is in ${COOLIFY_INSTALL_DIR}/.env as DB_PASSWORD)"
}

main "$@"

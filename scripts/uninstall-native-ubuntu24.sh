#!/usr/bin/env bash
# =============================================================================
# Reverse Coolify NATIVE installer artifacts (Ubuntu 24.04) — not Docker.
# Run as root: sudo bash scripts/uninstall-native-ubuntu24.sh
#
# Removes Soketi systemd unit, Supervisor Horizon, Nginx coolify site, cron.
# Does NOT remove apt packages (PHP, Postgres, Nginx, Redis, etc.) unless you
# handle that separately.
#
# Optional (destructive):
#   COOLIFY_PURGE_INSTALL_DIR=1     rm -rf COOLIFY_INSTALL_DIR
#   COOLIFY_DROP_DB=1               DROP DATABASE COOLIFY_DB_NAME
#   COOLIFY_CERTBOT_DELETE=1        certbot delete --cert-name <hostname from APP_URL>
#   COOLIFY_REMOVE_SOKETI_GLOBAL=1  npm uninstall -g @soketi/soketi
#
# Same path/URL vars as install-native-ubuntu24.sh:
#   COOLIFY_INSTALL_DIR=/var/www/coolify
#   COOLIFY_APP_URL=https://deploywerk.orbytals.com   (domain used for certbot delete)
#   COOLIFY_DB_NAME=coolify
# =============================================================================
set -euo pipefail

COOLIFY_INSTALL_DIR="${COOLIFY_INSTALL_DIR:-/var/www/coolify}"
COOLIFY_APP_URL="${COOLIFY_APP_URL:-https://deploywerk.orbytals.com}"
COOLIFY_DB_NAME="${COOLIFY_DB_NAME:-coolify}"
COOLIFY_PURGE_INSTALL_DIR="${COOLIFY_PURGE_INSTALL_DIR:-0}"
COOLIFY_DROP_DB="${COOLIFY_DROP_DB:-0}"
COOLIFY_CERTBOT_DELETE="${COOLIFY_CERTBOT_DELETE:-0}"
COOLIFY_REMOVE_SOKETI_GLOBAL="${COOLIFY_REMOVE_SOKETI_GLOBAL:-0}"

COOLIFY_DOMAIN=""
COOLIFY_URL_SCHEME=""

log() { printf '[coolify-uninstall] %s\n' "$*"; }
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

stop_soketi_systemd() {
  if systemctl list-unit-files --type=service 2>/dev/null | grep -qE '^coolify-soketi\.service'; then
    systemctl stop coolify-soketi.service 2>/dev/null || true
    systemctl disable coolify-soketi.service 2>/dev/null || true
  fi
  rm -f /etc/systemd/system/coolify-soketi.service
  rm -f /etc/coolify/soketi.env
  rmdir /etc/coolify 2>/dev/null || true
  systemctl daemon-reload
}

stop_horizon_supervisor() {
  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl stop coolify-horizon 2>/dev/null || true
  fi
  rm -f /etc/supervisor/conf.d/coolify-horizon.conf
  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl reread 2>/dev/null || true
    supervisorctl update 2>/dev/null || true
  fi
}

remove_nginx_site() {
  rm -f /etc/nginx/sites-enabled/coolify
  rm -f /etc/nginx/sites-available/coolify
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t 2>/dev/null; then
      systemctl reload nginx 2>/dev/null || true
    else
      log "nginx -t failed after removing coolify site; fix config manually before reloading nginx."
    fi
  fi
}

remove_cron() {
  rm -f /etc/cron.d/coolify-scheduler
}

certbot_maybe_delete() {
  if [[ "${COOLIFY_CERTBOT_DELETE}" != "1" ]]; then
    return 0
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    log "certbot not installed; skipping certificate delete."
    return 0
  fi
  log "Deleting Let's Encrypt certificate for ${COOLIFY_DOMAIN} (if present)…"
  certbot delete --cert-name "${COOLIFY_DOMAIN}" --non-interactive 2>/dev/null || log "No cert deleted (missing or already removed)."
}

postgres_maybe_drop_db() {
  if [[ "${COOLIFY_DROP_DB}" != "1" ]]; then
    return 0
  fi
  log "Dropping database ${COOLIFY_DB_NAME}…"
  systemctl start postgresql 2>/dev/null || true
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${COOLIFY_DB_NAME}\";" || true
}

maybe_purge_install_dir() {
  if [[ "${COOLIFY_PURGE_INSTALL_DIR}" != "1" ]]; then
    return 0
  fi
  log "Removing install directory ${COOLIFY_INSTALL_DIR}…"
  rm -rf "${COOLIFY_INSTALL_DIR}"
}

maybe_remove_soketi_global() {
  if [[ "${COOLIFY_REMOVE_SOKETI_GLOBAL}" != "1" ]]; then
    return 0
  fi
  if command -v npm >/dev/null 2>&1; then
    log "Removing global @soketi/soketi…"
    npm uninstall -g @soketi/soketi 2>/dev/null || true
  fi
}

banner() {
  cat <<'BANNER'

***************************************************************************
  Coolify NATIVE uninstall helper (Ubuntu 24.04)
  Stops Coolify-specific services and removes their config files.
  Optional flags can drop the database, app tree, certs, or Soketi npm.
***************************************************************************

BANNER
}

main() {
  banner
  require_root
  preflight_os
  resolve_app_domain

  log "Stopping coolify-soketi and removing unit…"
  stop_soketi_systemd

  log "Stopping coolify-horizon and removing Supervisor config…"
  stop_horizon_supervisor

  log "Removing Nginx site coolify…"
  remove_nginx_site

  log "Removing cron /etc/cron.d/coolify-scheduler…"
  remove_cron

  certbot_maybe_delete
  postgres_maybe_drop_db
  maybe_purge_install_dir
  maybe_remove_soketi_global

  log "Done. PHP/Postgres/Nginx/Redis packages were not removed."
}

main "$@"

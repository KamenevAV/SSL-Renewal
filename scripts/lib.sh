#!/usr/bin/env bash

load_config() {
  local cfg="/etc/ssl-renewal/config.env"
  [[ -f "$cfg" ]] || { echo "Config not found: $cfg" >&2; return 1; }
  # shellcheck disable=SC1090
  source "$cfg"
  export ROLE APP_DIR ETC_DIR PRIMARY_DOMAIN EXTRA_DOMAINS_CSV TARGET_DIR TARGET_CERT_FILE TARGET_KEY_FILE CERT_DIR LOG_DIR TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID NODES_FILE DNS_PROPAGATION_SECONDS CLOUDFLARE_CREDENTIALS REGION_WILDCARDS_CSV SSH_IDENTITY_FILE SSH_CONNECT_TIMEOUT SSH_COMMAND_TIMEOUT DEPLOY_RETRIES DEPLOY_RETRY_DELAY MIN_CERT_VALIDITY_SECONDS DEPLOY_LOCK_FILE NGINX_MODE NGINX_CONTAINER
}

banner() {
cat <<'BANNER'
   _____ _____ _        ____                              _
  / ____/ ____| |      |  _ \                            | |
 | (___| (___ | |      | |_) |___ _ __   _____      ____| |
  \___ \\___ \| |      |  _ </ _ \ '_ \ / _ \ \ /\ / / _` |
  ____) |___) | |____  | |_) |  __/ | | |  __/\ V  V / (_| |
 |_____/_____/|______| |____/ \___|_| |_|\___| \_/\_/ \__,_|

 SSL Renewal Toolkit
BANNER
}

log() {
  mkdir -p "${LOG_DIR:-/opt/ssl-renewal/logs}"
  echo "[$(date '+%F %T')] $*" | tee -a "${LOG_DIR:-/opt/ssl-renewal/logs}/ssl-renewal.log"
}

notify_tg() {
  local message="${1:-}"
  [[ "${TELEGRAM_ENABLED:-0}" == "1" ]] || return 0
  [[ -x "${APP_DIR}/telegram-notify.sh" ]] || return 0
  "${APP_DIR}/telegram-notify.sh" "$message" || true
}

detect_certbot_timer_unit() {
  if systemctl list-unit-files | grep -q '^snap\.certbot\.renew\.timer'; then
    echo "snap.certbot.renew.timer"
  elif systemctl list-unit-files | grep -q '^certbot\.timer'; then
    echo "certbot.timer"
  else
    echo ""
  fi
}

detect_certbot_service_unit() {
  if systemctl list-unit-files | grep -q '^snap\.certbot\.renew\.service'; then
    echo "snap.certbot.renew.service"
  elif systemctl list-unit-files | grep -q '^certbot\.service'; then
    echo "certbot.service"
  else
    echo ""
  fi
}

show_paths() {
  cat <<EOF2
ROLE=${ROLE:-unknown}
APP_DIR=${APP_DIR:-}
ETC_DIR=${ETC_DIR:-}
PRIMARY_DOMAIN=${PRIMARY_DOMAIN:-}
EXTRA_DOMAINS_CSV=${EXTRA_DOMAINS_CSV:-}
TARGET_DIR=${TARGET_DIR:-}
CERT_DIR=${CERT_DIR:-}
NODES_FILE=${NODES_FILE:-}
LOG_DIR=${LOG_DIR:-}
CLOUDFLARE_CREDENTIALS=${CLOUDFLARE_CREDENTIALS:-}
EOF2
}

doctor_main() {
  local ok=1
  command -v certbot >/dev/null 2>&1 || { log "certbot not found"; ok=0; }
  command -v flock >/dev/null 2>&1 || { log "flock not found"; ok=0; }
  command -v timeout >/dev/null 2>&1 || { log "timeout not found"; ok=0; }
  command -v openssl >/dev/null 2>&1 || { log "openssl not found"; ok=0; }
  certbot plugins 2>/dev/null | grep -q dns-cloudflare || { log "dns-cloudflare plugin not found"; ok=0; }
  [[ -f "${CERT_DIR}/fullchain.pem" ]] || { log "Missing ${CERT_DIR}/fullchain.pem"; ok=0; }
  [[ -f "${CERT_DIR}/privkey.pem" ]] || { log "Missing ${CERT_DIR}/privkey.pem"; ok=0; }
  [[ -f "${NODES_FILE}" ]] || { log "Missing ${NODES_FILE}"; ok=0; }
  [[ -f "${CLOUDFLARE_CREDENTIALS}" ]] || { log "Missing ${CLOUDFLARE_CREDENTIALS}"; ok=0; }
  if [[ -f "${CLOUDFLARE_CREDENTIALS}" ]] && grep -Eq "PUT_YOUR_TOKEN_HERE|YOUR_TOKEN" "${CLOUDFLARE_CREDENTIALS}"; then
    log "Cloudflare token file still contains placeholder value"
    ok=0
  fi
  local timer
  timer="$(detect_certbot_timer_unit)"
  [[ -n "$timer" ]] || { log "No certbot timer found"; ok=0; }
  [[ "$ok" -eq 1 ]]
}

doctor_node() {
  local ok=1
  command -v nginx >/dev/null 2>&1 || { log "nginx not found"; ok=0; }
  [[ -d "${TARGET_DIR}" ]] || { log "Missing target dir ${TARGET_DIR}"; ok=0; }
  [[ "$ok" -eq 1 ]]
}

trim_csv_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

build_domain_list() {
  local -n _out="$1"
  local -A seen=()
  local domain
  _out=()

  domain="$(trim_csv_value "${PRIMARY_DOMAIN:-}")"
  if [[ -n "$domain" ]]; then
    _out+=("$domain")
    seen["$domain"]=1
  fi

  local IFS=','
  local -a extra_domains=()
  read -r -a extra_domains <<< "${EXTRA_DOMAINS_CSV:-}"
  for domain in "${extra_domains[@]}"; do
    domain="$(trim_csv_value "$domain")"
    [[ -z "$domain" ]] && continue
    [[ -n "${seen[$domain]:-}" ]] && continue
    _out+=("$domain")
    seen["$domain"]=1
  done
}

add_certbot_domains() {
  local -n _cmd="$1"
  local domain="$2"
  local -A added=()
  local san

  for san in "$domain" "*.$domain"; do
    [[ -n "${added[$san]:-}" ]] && continue
    _cmd+=(-d "$san")
    added["$san"]=1
  done

  local IFS=','
  local -a regions=()
  local region
  read -r -a regions <<< "${REGION_WILDCARDS_CSV:-}"
  for region in "${regions[@]}"; do
    region="$(trim_csv_value "$region")"
    [[ -z "$region" ]] && continue
    san="*.${region}.${domain}"
    [[ -n "${added[$san]:-}" ]] && continue
    _cmd+=(-d "$san")
    added["$san"]=1
  done
}

run_issue() {
  local -a cmd domains
  cmd=(certbot certonly --cert-name "${PRIMARY_DOMAIN}" --dns-cloudflare --dns-cloudflare-credentials "${CLOUDFLARE_CREDENTIALS}" --dns-cloudflare-propagation-seconds "${DNS_PROPAGATION_SECONDS:-60}")
  build_domain_list domains
  local domain
  for domain in "${domains[@]}"; do
    add_certbot_domains cmd "$domain"
  done
  "${cmd[@]}"
}

cleanup_legacy_hooks() {
  local timestamp backup_root backup_dir legacy_dir hook_root hook
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  backup_root="/root/old-certs-sync-backup"
  backup_dir="${backup_root}/certs-sync.${timestamp}"
  legacy_dir="/opt/certs-sync"
  hook_root="/etc/letsencrypt/renewal-hooks"

  mkdir -p "$backup_dir/hooks"

  if [[ -e "$legacy_dir" ]]; then
    cp -a "$legacy_dir" "$backup_dir/"
    mv "$legacy_dir" "/opt/certs-sync.disabled.${timestamp}"
    echo "Backed up and disabled ${legacy_dir}: ${backup_dir}/certs-sync"
  else
    echo "No ${legacy_dir} directory found."
  fi

  if [[ -d "$hook_root" ]]; then
    while IFS= read -r -d '' hook; do
      [[ "$hook" == "/etc/letsencrypt/renewal-hooks/deploy/ssl-renewal-deploy.sh" ]] && continue
      mkdir -p "${backup_dir}/hooks/$(dirname "${hook#${hook_root}/}")"
      mv "$hook" "${backup_dir}/hooks/${hook#${hook_root}/}"
      echo "Moved legacy hook to backup: $hook"
    done < <(find "$hook_root" -type f ! -path '/etc/letsencrypt/renewal-hooks/deploy/ssl-renewal-deploy.sh' -print0 | xargs -0 -r grep -ElZ '/opt/certs-sync|certs-sync' || true)
  fi

  echo "Legacy cleanup complete. Backup directory: ${backup_dir}"
}


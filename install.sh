#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SSL Renewal"
APP_SLUG="ssl-renewal"
APP_DIR="/opt/${APP_SLUG}"
ETC_DIR="/etc/${APP_SLUG}"
BIN_LINK="/usr/local/bin/${APP_SLUG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

mkdir -p "${APP_DIR}" "${ETC_DIR}" "${APP_DIR}/logs"

banner() {
cat <<'BANNER'
   _____ _____ _        ____                              _
  / ____/ ____| |      |  _ \                            | |
 | (___| (___ | |      | |_) |___ _ __   _____      ____| |
  \___ \\___ \| |      |  _ </ _ \ '_ \ / _ \ \ /\ / / _` |
  ____) |___) | |____  | |_) |  __/ | | |  __/\ V  V / (_| |
 |_____/_____/|______| |____/ \___|_| |_|\___| \_/\_/ \__,_|

 SSL Renewal Toolkit
 Centralized certificate issuance, sync, and optional Telegram alerts
BANNER
}

say() { printf "\n[%s] %s\n" "$(date '+%F %T')" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die() { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run install.sh as root."
}

ensure_scripts_present() {
  local required=(ssl-renewal lib.sh deploy-certs.sh activate-certs-on-node.sh telegram-notify.sh node-prep.sh node-nginx-patch.sh disable-renew-on-nodes.sh)
  for f in "${required[@]}"; do
    [[ -f "${REPO_SCRIPTS_DIR}/${f}" ]] || die "Missing required file: ${REPO_SCRIPTS_DIR}/${f}"
  done
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  else
    die "Only apt-based systems are supported (Ubuntu/Debian)."
  fi
}

ensure_base_packages() {
  local pm="$1"
  if [[ "$pm" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl openssh-client openssh-server ca-certificates nano grep sed gawk coreutils findutils rsync snapd jq
  fi
}

ensure_certbot_main() {
  say "Checking certbot and Cloudflare DNS plugin..."
  systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  snap install core >/dev/null 2>&1 || true
  snap refresh core >/dev/null 2>&1 || true
  snap install --classic certbot >/dev/null 2>&1 || true
  snap set certbot trust-plugin-with-root=ok >/dev/null 2>&1 || true
  snap install certbot-dns-cloudflare >/dev/null 2>&1 || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
  certbot plugins | grep -q 'dns-cloudflare' || die "dns-cloudflare plugin not found after installation."
}

prompt_default() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value || true
    printf '%s' "${value:-$default}"
  else
    read -r -p "$prompt: " value || true
    printf '%s' "$value"
  fi
}

prompt_secret() {
  local prompt="$1" value
  read -r -s -p "$prompt: " value || true
  echo
  printf '%s' "$value"
}

prompt_yes_no() {
  local prompt="$1" default="${2:-N}" value suffix="[y/N]"
  [[ "$default" =~ ^[Yy]$ ]] && suffix="[Y/n]"
  read -r -p "$prompt $suffix: " value || true
  value="${value:-$default}"
  [[ "$value" =~ ^[Yy]$ ]]
}

collect_nodes() {
  local nodes=()
  echo
  echo "Enter node list as user@host (blank line to finish)."
  while true; do
    local line
    read -r -p "node> " line || true
    [[ -z "$line" ]] && break
    nodes+=("$line")
  done
  printf '%s\n' "${nodes[@]}" | awk '!x[$0]++'
}

deploy_ssh_keys_interactive() {
  local nodes_file="$1"
  [[ -s "$nodes_file" ]] || { warn "nodes.txt is empty, skipping SSH key deployment."; return 0; }

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [[ ! -f /root/.ssh/id_ed25519 ]]; then
    say "Generating SSH keypair on main..."
    ssh-keygen -t ed25519 -C "ssl-renewal@$(hostname -f 2>/dev/null || hostname)" -f /root/.ssh/id_ed25519 -N ""
  fi

  if ! prompt_yes_no "Attempt automatic ssh-copy-id to nodes now?" "Y"; then
    cat <<'EOF2'

Manual onboarding:
1. Show the public key on main:
   cat /root/.ssh/id_ed25519.pub
2. Add it to each node's ~/.ssh/authorized_keys (root or your deploy user).
3. Verify from main:
   ssh user@node1.example.com "hostname"

EOF2
    return 0
  fi

  command -v ssh-copy-id >/dev/null 2>&1 || apt-get install -y openssh-client >/dev/null 2>&1 || true

  while IFS= read -r node || [[ -n "$node" ]]; do
    [[ -z "$node" ]] && continue
    say "Bootstrapping SSH trust for $node"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$node" "echo ok" </dev/null >/dev/null 2>&1; then
      say "SSH key auth already works for $node"
      continue
    fi

    echo "If password auth is enabled, ssh-copy-id will prompt for a password."
    echo "If password auth is disabled, this may fail; manual steps will be shown."
    if ssh-copy-id -i /root/.ssh/id_ed25519.pub "$node"; then
      say "SSH key installed on $node"
    else
      warn "Automatic key install failed for $node."
      cat <<EOF2
Public key (copy this to ${node} -> ~/.ssh/authorized_keys):
$(cat /root/.ssh/id_ed25519.pub)

Manual steps:
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  echo '<PASTE_PUBLIC_KEY_HERE>' >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys

Then verify from main:
  ssh $node "hostname"
EOF2
    fi
  done < "$nodes_file"
}

cloudflare_token_instructions() {
cat <<'EOF2'
How to create a Cloudflare API Token:
  1. Open Cloudflare Dashboard.
  2. Go to My Profile -> API Tokens -> Create Token.
  3. Use "Edit zone DNS" template or create a custom token.
  4. Minimum permissions:
       - Zone -> DNS -> Edit
       - Zone -> Zone -> Read
  5. Zone Resources: include every zone used by SSL Renewal (for example: example.com, example.net, and example.org).
  6. Create token and copy it.

Token file location on this server:
  /root/.secrets/certbot/cloudflare.ini

Required permissions:
  chmod 600 /root/.secrets/certbot/cloudflare.ini
EOF2
}

cloudflare_ini_has_placeholder() {
  local cf_ini="$1"
  [[ -f "$cf_ini" ]] && grep -Eq 'PUT_YOUR_TOKEN_HERE|YOUR_TOKEN' "$cf_ini"
}

cloudflare_ini_has_real_token() {
  local cf_ini="$1"
  [[ -f "$cf_ini" ]] && ! cloudflare_ini_has_placeholder "$cf_ini"
}

write_cloudflare_token_file() {
  local cf_ini="$1" token="$2"
  if [[ -f "$cf_ini" ]]; then
    local backup
    backup="${cf_ini}.bak.$(date '+%Y%m%d-%H%M%S')"
    cp -a "$cf_ini" "$backup"
    say "Backed up existing Cloudflare credentials to ${backup}"
  fi
  printf 'dns_cloudflare_api_token = %s\n' "$token" > "$cf_ini"
  chmod 600 "$cf_ini"
}

write_cloudflare_placeholder_if_missing() {
  local cf_ini="$1"
  if [[ -f "$cf_ini" ]]; then
    if cloudflare_ini_has_real_token "$cf_ini"; then
      say "Existing Cloudflare credentials found, keeping them."
    else
      warn "Existing Cloudflare credentials still contain placeholders; keeping placeholder file."
      chmod 600 "$cf_ini"
    fi
    return 0
  fi
  cat > "$cf_ini" <<'EOF2'
dns_cloudflare_api_token = PUT_YOUR_TOKEN_HERE
EOF2
  chmod 600 "$cf_ini"
}

configure_cloudflare_credentials() {
  local cf_ini="$1" cf_token
  if [[ -f "$cf_ini" ]] && cloudflare_ini_has_real_token "$cf_ini"; then
    say "Existing Cloudflare credentials found, keeping them."
    if prompt_yes_no "Replace existing Cloudflare API Token?" "N"; then
      prompt_yes_no "Confirm replacement and backup of ${cf_ini}?" "N" || die "Cloudflare token replacement cancelled."
      cf_token="$(prompt_secret 'Cloudflare API Token')"
      [[ -n "$cf_token" ]] || die "Cloudflare API Token is required when replacing credentials."
      write_cloudflare_token_file "$cf_ini" "$cf_token"
    fi
    return 0
  fi

  if prompt_yes_no "Add Cloudflare API Token now?" "Y"; then
    cf_token="$(prompt_secret 'Cloudflare API Token')"
    [[ -n "$cf_token" ]] || die "Cloudflare API Token is required when immediate setup is selected."
    write_cloudflare_token_file "$cf_ini" "$cf_token"
  else
    warn "Token skipped for now. Certificate issuance will be skipped until token is set."
    write_cloudflare_placeholder_if_missing "$cf_ini"
  fi
}

write_main_config() {
  local domain="$1" extra_domains_csv="$2" propagation="$3" target_dir="$4" cf_ini="$5" telegram_enabled="$6" bot_token="$7" chat_id="$8" region_csv="$9"
  mkdir -p "${ETC_DIR}" "${APP_DIR}" "${APP_DIR}/logs"
  cat > "${ETC_DIR}/config.env" <<EOF2
ROLE="main"
APP_DIR="${APP_DIR}"
ETC_DIR="${ETC_DIR}"
PRIMARY_DOMAIN="${domain}"
EXTRA_DOMAINS_CSV="${extra_domains_csv}"
TARGET_DIR="${target_dir}"
CERT_DIR="/etc/letsencrypt/live/${domain}"
CLOUDFLARE_CREDENTIALS="${cf_ini}"
DNS_PROPAGATION_SECONDS="${propagation}"
REGION_WILDCARDS_CSV="${region_csv}"
NODES_FILE="${ETC_DIR}/nodes.txt"
LOG_DIR="${APP_DIR}/logs"
TELEGRAM_ENABLED="${telegram_enabled}"
TELEGRAM_BOT_TOKEN="${bot_token}"
TELEGRAM_CHAT_ID="${chat_id}"
SSH_CONNECT_TIMEOUT="10"
SSH_COMMAND_TIMEOUT="60"
DEPLOY_RETRIES="3"
DEPLOY_RETRY_DELAY="5"
MIN_CERT_VALIDITY_SECONDS="86400"
DEPLOY_LOCK_FILE="/run/lock/ssl-renewal-deploy.lock"
EOF2
  chmod 600 "${ETC_DIR}/config.env"
}

write_node_config() {
  local domain="$1" target_dir="$2"
  mkdir -p "${ETC_DIR}" "${APP_DIR}" "${APP_DIR}/logs"
  cat > "${ETC_DIR}/config.env" <<EOF2
ROLE="node"
APP_DIR="${APP_DIR}"
ETC_DIR="${ETC_DIR}"
PRIMARY_DOMAIN="${domain}"
EXTRA_DOMAINS_CSV=""
TARGET_DIR="${target_dir}"
CERT_DIR="${target_dir}"
LOG_DIR="${APP_DIR}/logs"
TELEGRAM_ENABLED="0"
EOF2
  chmod 600 "${ETC_DIR}/config.env"
}

install_runtime_files() {
  install -m 755 "${REPO_SCRIPTS_DIR}/ssl-renewal" "${APP_DIR}/ssl-renewal"
  install -m 755 "${REPO_SCRIPTS_DIR}/lib.sh" "${APP_DIR}/lib.sh"
  install -m 755 "${REPO_SCRIPTS_DIR}/deploy-certs.sh" "${APP_DIR}/deploy-certs.sh"
  install -m 755 "${REPO_SCRIPTS_DIR}/activate-certs-on-node.sh" "${APP_DIR}/activate-certs-on-node.sh"
  install -m 755 "${REPO_SCRIPTS_DIR}/telegram-notify.sh" "${APP_DIR}/telegram-notify.sh"
  install -m 755 "${REPO_SCRIPTS_DIR}/node-prep.sh" "${APP_DIR}/node-prep.sh"
  install -m 755 "${REPO_SCRIPTS_DIR}/node-nginx-patch.sh" "${APP_DIR}/node-nginx-patch.sh"
  install -m 755 "${REPO_SCRIPTS_DIR}/disable-renew-on-nodes.sh" "${APP_DIR}/disable-renew-on-nodes.sh"
  ln -sf "${APP_DIR}/ssl-renewal" "${BIN_LINK}"
}

write_certbot_hook() {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/ssl-renewal-deploy.sh <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
if [[ -x /opt/ssl-renewal/deploy-certs.sh ]]; then
  /opt/ssl-renewal/deploy-certs.sh
fi
EOF2
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/ssl-renewal-deploy.sh
}

trim_csv_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

issue_main_certificate() {
  local domain="$1" extra_domains_csv="$2" propagation="$3" cf_ini="$4" region_csv="$5"
  local -a cmd domains extra_domains regions
  local -A seen_domains=() added_sans=()
  local item region san
  cmd=(certbot certonly --cert-name "$domain" --dns-cloudflare --dns-cloudflare-credentials "$cf_ini" --dns-cloudflare-propagation-seconds "$propagation")
  item="$(trim_csv_value "$domain")"
  if [[ -n "$item" ]]; then
    domains+=("$item")
    seen_domains["$item"]=1
  fi
  IFS=',' read -r -a extra_domains <<< "$extra_domains_csv"
  for item in "${extra_domains[@]}"; do
    item="$(trim_csv_value "$item")"
    [[ -z "$item" || -n "${seen_domains[$item]:-}" ]] && continue
    domains+=("$item")
    seen_domains["$item"]=1
  done
  IFS=',' read -r -a regions <<< "$region_csv"
  for item in "${domains[@]}"; do
    for san in "$item" "*.$item"; do
      [[ -n "${added_sans[$san]:-}" ]] && continue
      cmd+=(-d "$san")
      added_sans["$san"]=1
    done
    for region in "${regions[@]}"; do
      region="$(trim_csv_value "$region")"
      [[ -z "$region" ]] && continue
      san="*.${region}.${item}"
      [[ -n "${added_sans[$san]:-}" ]] && continue
      cmd+=(-d "$san")
      added_sans["$san"]=1
    done
  done
  printf '\nCertificate issue command:\n%s\n\n' "${cmd[*]}"
  if prompt_yes_no "Issue/renew certificate now?" "Y"; then
    "${cmd[@]}"
  else
    warn "Skipping certificate issue. You can run: ssl-renewal issue"
  fi
}

configure_node_host() {
  local target_dir="$1"
  say "Preparing node settings..."
  "${APP_DIR}/node-prep.sh"
  if prompt_yes_no "Patch nginx ssl_certificate paths to ${target_dir} automatically?" "N"; then
    "${APP_DIR}/node-nginx-patch.sh" --apply
  else
    cat <<EOF2

Nginx manual template:
  ssl_certificate     ${target_dir}/fullchain.pem;
  ssl_certificate_key ${target_dir}/privkey.pem;

Then run:
  nginx -t && systemctl reload nginx
EOF2
  fi
}

main_install_flow() {
  ensure_certbot_main

  local domain extra_domains_csv propagation target_dir region_csv cf_ini telegram_enabled="0" bot_token="" chat_id=""
  domain="$(prompt_default 'Primary domain' 'example.com')"
  extra_domains_csv="$(prompt_default 'Extra primary domains, comma-separated, optional' '')"
  propagation="$(prompt_default 'DNS propagation seconds for Cloudflare' '60')"
  target_dir="$(prompt_default 'Certificate path used on nodes' "/etc/letsencrypt/live/${domain}")"
  region_csv="$(prompt_default 'Regional wildcard prefixes (comma-separated, e.g. region1,region2)' 'region1,region2')"

  echo
  echo "Main server requires a Cloudflare API Token with Zone DNS Edit + Zone Read."
  if prompt_yes_no "Show Cloudflare token creation instructions?" "Y"; then
    cloudflare_token_instructions
  fi

  mkdir -p /root/.secrets/certbot
  cf_ini="/root/.secrets/certbot/cloudflare.ini"

  if prompt_yes_no "Add Cloudflare API Token now?" "Y"; then
    cf_token="$(prompt_secret 'Cloudflare API Token')"
    [[ -n "$cf_token" ]] || die "Cloudflare API Token is required when immediate setup is selected."
    printf 'dns_cloudflare_api_token = %s\n' "$cf_token" > "$cf_ini"
    chmod 600 "$cf_ini"
  else
    warn "Token skipped for now. Certificate issuance will be skipped until token is set."
    cat > "$cf_ini" <<'EOF2'
dns_cloudflare_api_token = PUT_YOUR_TOKEN_HERE
EOF2
    chmod 600 "$cf_ini"
  fi

  if prompt_yes_no "Enable Telegram notifications?" "N"; then
    telegram_enabled="1"
    bot_token="$(prompt_default 'Telegram bot token' '')"
    chat_id="$(prompt_default 'Telegram chat ID' '')"
  fi

  write_main_config "$domain" "$extra_domains_csv" "$propagation" "$target_dir" "$cf_ini" "$telegram_enabled" "$bot_token" "$chat_id" "$region_csv"
  install_runtime_files

  collect_nodes > "${ETC_DIR}/nodes.txt"
  chmod 600 "${ETC_DIR}/nodes.txt"
  deploy_ssh_keys_interactive "${ETC_DIR}/nodes.txt"
  write_certbot_hook

  if [[ -s "${ETC_DIR}/nodes.txt" ]] && prompt_yes_no "Disable renewal timers/hooks on nodes after first deploy?" "Y"; then
    touch "${APP_DIR}/.disable_nodes_after_first_deploy"
  else
    rm -f "${APP_DIR}/.disable_nodes_after_first_deploy"
  fi

  if cloudflare_ini_has_placeholder "$cf_ini"; then
    warn "Cloudflare token is not configured yet; skipping certificate issuance."
    cat <<EOF2

Next steps:
  1. Edit ${cf_ini}
  2. Set: dns_cloudflare_api_token = <REAL_TOKEN>
  3. Run:
     ssl-renewal cloudflare-help
     ssl-renewal doctor
     ssl-renewal issue
     ssl-renewal deploy
EOF2
  else
    issue_main_certificate "$domain" "$extra_domains_csv" "$propagation" "$cf_ini" "$region_csv"
  fi

  if [[ -s "${ETC_DIR}/nodes.txt" ]] && prompt_yes_no "Deploy certificates to nodes now?" "Y"; then
    "${APP_DIR}/deploy-certs.sh" || true
    if [[ -f "${APP_DIR}/.disable_nodes_after_first_deploy" ]]; then
      "${APP_DIR}/disable-renew-on-nodes.sh" || true
    fi
  fi

  cat <<'EOF2'

Main installation completed.
Recommended next commands:
  ssl-renewal doctor
  ssl-renewal status
  ssl-renewal dry-run
EOF2
}

node_install_flow() {
  local domain target_dir
  domain="$(prompt_default 'Primary domain handled by main' 'example.com')"
  target_dir="$(prompt_default 'Certificate path on this node' "/etc/letsencrypt/live/${domain}")"

  write_node_config "$domain" "$target_dir"
  install_runtime_files
  configure_node_host "$target_dir"

  cat <<'EOF2'

Node installation completed.
Useful commands:
  ssl-renewal doctor
  ssl-renewal status
  ssl-renewal patch-nginx
  ssl-renewal reload
EOF2
}

main() {
  require_root
  ensure_scripts_present
  banner
  local pm role
  pm="$(detect_pkg_manager)"
  ensure_base_packages "$pm"

  role="${1:-}"
  if [[ -z "$role" ]]; then
    echo
    echo "Select role:"
    echo "  1) main"
    echo "  2) node"
    read -r -p "Role [1/2]: " ans || true
    case "${ans:-1}" in
      1) role="main" ;;
      2) role="node" ;;
      *) die "Invalid role selection." ;;
    esac
  fi

  case "$role" in
    main|--role=main) main_install_flow ;;
    node|--role=node) node_install_flow ;;
    *) die "Usage: ./install.sh [main|node|--role=main|--role=node]" ;;
  esac
}

main "$@"


#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /opt/ssl-renewal/lib.sh ]]; then
  # shellcheck disable=SC1091
  source /opt/ssl-renewal/lib.sh
elif [[ -f "${SELF_DIR}/lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SELF_DIR}/lib.sh"
else
  echo "lib.sh not found (checked /opt/ssl-renewal/lib.sh and ${SELF_DIR}/lib.sh)" >&2
  exit 1
fi
load_config

[[ "${ROLE}" == "main" ]] || { echo "deploy-certs.sh runs only on main." >&2; exit 1; }

SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_COMMAND_TIMEOUT="${SSH_COMMAND_TIMEOUT:-60}"
DEPLOY_RETRIES="${DEPLOY_RETRIES:-3}"
DEPLOY_RETRY_DELAY="${DEPLOY_RETRY_DELAY:-5}"
MIN_CERT_VALIDITY_SECONDS="${MIN_CERT_VALIDITY_SECONDS:-86400}"
LOCK_FILE="${DEPLOY_LOCK_FILE:-/run/lock/ssl-renewal-deploy.lock}"

is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_positive_integer "$SSH_CONNECT_TIMEOUT" || { echo "Invalid SSH_CONNECT_TIMEOUT" >&2; exit 1; }
is_positive_integer "$SSH_COMMAND_TIMEOUT" || { echo "Invalid SSH_COMMAND_TIMEOUT" >&2; exit 1; }
is_positive_integer "$DEPLOY_RETRIES" || { echo "Invalid DEPLOY_RETRIES" >&2; exit 1; }
is_positive_integer "$DEPLOY_RETRY_DELAY" || { echo "Invalid DEPLOY_RETRY_DELAY" >&2; exit 1; }
is_positive_integer "$MIN_CERT_VALIDITY_SECONDS" || { echo "Invalid MIN_CERT_VALIDITY_SECONDS" >&2; exit 1; }
[[ "$TARGET_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "Unsafe TARGET_DIR: ${TARGET_DIR}" >&2; exit 1; }
[[ "$PRIMARY_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid PRIMARY_DOMAIN: ${PRIMARY_DOMAIN}" >&2; exit 1; }

mkdir -p "${LOG_DIR}" "$(dirname "$LOCK_FILE")"
LOG_FILE="${LOG_DIR}/deploy-certs.log"
OK_NODES=()
FAIL_NODES=()

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
notify() { notify_tg "$1"; }

command -v flock >/dev/null 2>&1 || { log "flock not found (install util-linux)"; exit 1; }
exec 9>"$LOCK_FILE"
flock -n 9 || { log "Another certificate deployment is already running"; exit 1; }

for command_name in openssl ssh scp timeout; do
  command -v "$command_name" >/dev/null 2>&1 || { log "Required command not found: ${command_name}"; exit 1; }
done

[[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]] || { log "Certificate files not found in ${CERT_DIR}"; exit 1; }
ACTIVATE_SCRIPT="${SELF_DIR}/activate-certs-on-node.sh"
[[ -f "$ACTIVATE_SCRIPT" ]] || { log "Activation helper not found: ${ACTIVATE_SCRIPT}"; exit 1; }
[[ -f "${NODES_FILE}" ]] || { log "Nodes file not found: ${NODES_FILE}"; exit 1; }
openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend "$MIN_CERT_VALIDITY_SECONDS" >/dev/null || { log "Local certificate is invalid or expires too soon"; exit 1; }
openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkhost "$PRIMARY_DOMAIN" >/dev/null || { log "Local certificate does not cover ${PRIMARY_DOMAIN}"; exit 1; }
cert_key_hash="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)"
private_key_hash="$(openssl pkey -in "${CERT_DIR}/privkey.pem" -pubout -outform DER 2>/dev/null | openssl dgst -sha256)"
[[ -n "$cert_key_hash" && "$cert_key_hash" == "$private_key_hash" ]] || { log "Local certificate and private key do not match"; exit 1; }

SSH_OPTIONS=(-o BatchMode=yes -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}" -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

retry() {
  local attempt=1
  while ! "$@"; do
    if (( attempt >= DEPLOY_RETRIES )); then return 1; fi
    log "Attempt ${attempt}/${DEPLOY_RETRIES} failed; retrying in ${DEPLOY_RETRY_DELAY}s"
    sleep "$DEPLOY_RETRY_DELAY"
    ((attempt++))
  done
}

run_ssh() {
  local node="$1"; shift
  timeout "${SSH_COMMAND_TIMEOUT}s" ssh -n "${SSH_OPTIONS[@]}" "$node" "$@" </dev/null
}

run_scp() {
  timeout "${SSH_COMMAND_TIMEOUT}s" scp -q "${SSH_OPTIONS[@]}" "$@" </dev/null
}

log "=== DEPLOY START on $(hostname -f 2>/dev/null || hostname) ==="

while IFS= read -r NODE || [[ -n "$NODE" ]]; do
  NODE="${NODE%$'\r'}"
  [[ -z "$NODE" || "$NODE" =~ ^[[:space:]]*# ]] && continue
  if [[ ! "$NODE" =~ ^[A-Za-z0-9._-]+@([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\])$ ]]; then
    log "ERROR: invalid node entry: ${NODE}"
    FAIL_NODES+=("$NODE")
    continue
  fi

  log "==> ${NODE}"
  deploy_id="$(date '+%Y%m%d%H%M%S')-$$"
  remote_stage="${TARGET_DIR}/.ssl-renewal-stage-${deploy_id}"

  if ! retry run_ssh "$NODE" "mkdir -p '${TARGET_DIR}' '${remote_stage}' && chmod 700 '${remote_stage}'"; then
    log "ERROR: staging directory creation failed on ${NODE}"
    FAIL_NODES+=("$NODE")
    continue
  fi
  if ! retry run_scp "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" "$ACTIVATE_SCRIPT" "${NODE}:${remote_stage}/"; then
    log "ERROR: certificate copy failed on ${NODE}"
    run_ssh "$NODE" "rm -rf '${remote_stage}'" || true
    FAIL_NODES+=("$NODE")
    continue
  fi

  # The helper validates the candidate and restores the previous pair if the
  # nginx validation or reload fails.
  if ! run_ssh "$NODE" "bash '${remote_stage}/activate-certs-on-node.sh' '${TARGET_DIR}' '${remote_stage}' '${PRIMARY_DOMAIN}' '${MIN_CERT_VALIDITY_SECONDS}'"; then
    log "ERROR: validation/activation failed on ${NODE}; previous certificate restored"
    FAIL_NODES+=("$NODE")
    continue
  fi

  log "OK: ${NODE}"
  OK_NODES+=("$NODE")
done < "${NODES_FILE}"

log "--- SUMMARY ---"
log "OK nodes: ${#OK_NODES[@]}"
for n in "${OK_NODES[@]}"; do log "  OK   $n"; done
log "FAIL nodes: ${#FAIL_NODES[@]}"
for n in "${FAIL_NODES[@]}"; do log "  FAIL $n"; done

if [[ -f "${APP_DIR}/.disable_nodes_after_first_deploy" ]]; then
  /opt/ssl-renewal/disable-renew-on-nodes.sh || true
  rm -f "${APP_DIR}/.disable_nodes_after_first_deploy"
fi

if [[ ${#FAIL_NODES[@]} -gt 0 ]]; then
  notify "SSL Renewal deploy finished with errors. Host: $(hostname -f 2>/dev/null || hostname). OK: ${#OK_NODES[@]}. FAIL: ${#FAIL_NODES[@]}."
  exit 1
fi

notify "SSL Renewal deploy successful. Host: $(hostname -f 2>/dev/null || hostname). Nodes updated: ${#OK_NODES[@]}."
log "=== DEPLOY END ==="


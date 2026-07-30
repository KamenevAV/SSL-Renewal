#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "Running bash syntax checks..."
bash -n install.sh
bash -n bootstrap.sh
bash -n smoke-test.sh
bash -n scripts/*.sh
bash -n scripts/ssl-renewal

echo "Running pre-install CLI checks..."
help_output="$(bash scripts/ssl-renewal help)"
cloudflare_output="$(bash scripts/ssl-renewal cloudflare-help)"
[[ "$help_output" == *"Usage:"* ]] || { echo "help output validation failed" >&2; exit 1; }
[[ "$cloudflare_output" == *"Cloudflare API Token quick guide:"* ]] || { echo "cloudflare-help output validation failed" >&2; exit 1; }
[[ "$help_output" != *"lib.sh not found"* ]] || { echo "help hit lib.sh load error" >&2; exit 1; }
[[ "$cloudflare_output" != *"lib.sh not found"* ]] || { echo "cloudflare-help hit lib.sh load error" >&2; exit 1; }


echo "Checking forbidden runtime Telegram URL-encoded newlines..."
if rg -n '%0A' scripts install.sh bootstrap.sh; then
  echo "Found forbidden %0A in runtime scripts" >&2
  exit 1
fi

echo "Checking multi-domain configuration support..."
[[ "$(< install.sh)" == *"EXTRA_DOMAINS_CSV"* ]] || { echo "install.sh missing EXTRA_DOMAINS_CSV" >&2; exit 1; }
[[ "$(< scripts/lib.sh)" == *"EXTRA_DOMAINS_CSV"* ]] || { echo "scripts/lib.sh missing EXTRA_DOMAINS_CSV" >&2; exit 1; }

echo "Checking hardened deployment safeguards..."
deploy_source="$(< scripts/deploy-certs.sh)"
for marker in 'flock -n' 'ConnectTimeout=' 'MIN_CERT_VALIDITY_SECONDS' 'activate-certs-on-node.sh' 'openssl x509' 'openssl pkey'; do
  [[ "$deploy_source" == *"$marker"* ]] || { echo "deploy-certs.sh missing safeguard: $marker" >&2; exit 1; }
done
activate_source="$(< scripts/activate-certs-on-node.sh)"
for marker in 'ssl-renewal-backups' 'Activation failed; restoring previous certificate' 'nginx -t' 'openssl x509' 'openssl pkey' 'docker exec' 'nginx_mode'; do
  [[ "$activate_source" == *"$marker"* ]] || { echo "activate-certs-on-node.sh missing safeguard: $marker" >&2; exit 1; }
done

echo "Checking executable bits..."
for f in install.sh smoke-test.sh scripts/*.sh scripts/ssl-renewal bootstrap.sh; do
  [[ -x "$f" ]] || echo "  WARN: not executable: $f"
done

echo "Checking repository sanitization markers..."
MARKER_REGEX='DEVELOPER_[A-Z_]+|[[:alnum:]._-]+\.ru'
if command -v rg >/dev/null 2>&1; then
  if rg -n "$MARKER_REGEX" README.md docs install.sh scripts bootstrap.sh; then
    echo "Found disallowed/private markers" >&2
    exit 1
  fi
else
  echo "WARN: rg not found; skipping sanitization marker scan"
fi

echo "Smoke test finished."


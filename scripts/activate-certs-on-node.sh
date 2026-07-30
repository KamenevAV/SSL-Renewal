#!/usr/bin/env bash
set -Eeuo pipefail

target="${1:?target directory is required}"
stage="${2:?staging directory is required}"
domain="${3:?primary domain is required}"
min_validity="${4:?minimum validity is required}"
cert_file="${5:-fullchain.pem}"
key_file="${6:-privkey.pem}"
nginx_mode="${7:-systemd}"
nginx_container="${8:-}"

[[ "$target" =~ ^/[A-Za-z0-9._/-]+$ ]]
[[ "$stage" == "${target}/.ssl-renewal-stage-"* ]]
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]]
[[ "$min_validity" =~ ^[1-9][0-9]*$ ]]
[[ "$cert_file" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$key_file" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$nginx_mode" == systemd || "$nginx_mode" == docker ]]
if [[ "$nginx_mode" == docker ]]; then
  [[ "$nginx_container" =~ ^[A-Za-z0-9._-]+$ ]]
fi

active_cert="${target}/${cert_file}"
active_key="${target}/${key_file}"
next_cert="${target}/.${cert_file}.ssl-renewal-next"
next_key="${target}/.${key_file}.ssl-renewal-next"
backup_root="${target}/.ssl-renewal-backups"
backup="${backup_root}/$(date '+%Y%m%d%H%M%S')-$$"
activated=0
had_cert=0
had_key=0

cleanup() { rm -rf "$stage"; }

nginx_test() {
  if [[ "$nginx_mode" == docker ]]; then
    [[ "$(docker inspect "$nginx_container" --format '{{.State.Running}}')" == true ]]
    docker exec "$nginx_container" nginx -t
  else
    nginx -t
  fi
}

nginx_reload() {
  if [[ "$nginx_mode" == docker ]]; then
    docker exec "$nginx_container" nginx -s reload
  else
    systemctl reload nginx
  fi
}

rollback() {
  local rc=$?
  trap - ERR
  rm -f "$next_cert" "$next_key"
  if (( activated )); then
    echo "Activation failed; restoring previous certificate" >&2
    if (( had_cert )); then install -m 644 "$backup/$cert_file" "$active_cert"; else rm -f "$active_cert"; fi
    if (( had_key )); then install -m 600 "$backup/$key_file" "$active_key"; else rm -f "$active_key"; fi
    nginx_test && nginx_reload || true
    echo "Rollback completed" >&2
  fi
  cleanup
  exit "$rc"
}

trap cleanup EXIT
trap rollback ERR

command -v openssl >/dev/null
if [[ "$nginx_mode" == docker ]]; then command -v docker >/dev/null; else command -v nginx >/dev/null; fi
[[ -f "$stage/fullchain.pem" && -f "$stage/privkey.pem" ]]

openssl x509 -in "$stage/fullchain.pem" -noout -checkend "$min_validity" >/dev/null
openssl x509 -in "$stage/fullchain.pem" -noout -checkhost "$domain" >/dev/null
cert_hash="$(openssl x509 -in "$stage/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)"
key_hash="$(openssl pkey -in "$stage/privkey.pem" -pubout -outform DER 2>/dev/null | openssl dgst -sha256)"
[[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]

mkdir -p "$backup_root" "$backup"
if [[ -f "$active_cert" ]]; then cp -a "$active_cert" "$backup/$cert_file"; had_cert=1; fi
if [[ -f "$active_key" ]]; then cp -a "$active_key" "$backup/$key_file"; chmod 600 "$backup/$key_file"; had_key=1; fi

install -m 644 "$stage/fullchain.pem" "$next_cert"
install -m 600 "$stage/privkey.pem" "$next_key"
activated=1
mv -f "$next_cert" "$active_cert"
mv -f "$next_key" "$active_key"
nginx_test
nginx_reload

trap - ERR
echo "Certificate activated: ${active_cert} (${nginx_mode})"


#!/usr/bin/env bash
set -euo pipefail

target="${1:?target directory is required}"
stage="${2:?staging directory is required}"
domain="${3:?primary domain is required}"
min_validity="${4:?minimum validity is required}"
backup_root="${target}/.ssl-renewal-backups"
backup="${backup_root}/$(date '+%Y%m%d%H%M%S')-$$"

cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

command -v openssl >/dev/null
command -v nginx >/dev/null
[[ "$target" =~ ^/[A-Za-z0-9._/-]+$ ]]
[[ "$stage" == "${target}/.ssl-renewal-stage-"* ]]
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]]
[[ "$min_validity" =~ ^[1-9][0-9]*$ ]]
[[ -f "$stage/fullchain.pem" && -f "$stage/privkey.pem" ]]

openssl x509 -in "$stage/fullchain.pem" -noout -checkend "$min_validity" >/dev/null
openssl x509 -in "$stage/fullchain.pem" -noout -checkhost "$domain" >/dev/null
cert_hash="$(openssl x509 -in "$stage/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)"
key_hash="$(openssl pkey -in "$stage/privkey.pem" -pubout -outform DER 2>/dev/null | openssl dgst -sha256)"
[[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]

mkdir -p "$backup_root" "$backup"
had_cert=0
had_key=0
if [[ -f "$target/fullchain.pem" ]]; then cp -a "$target/fullchain.pem" "$backup/fullchain.pem"; had_cert=1; fi
if [[ -f "$target/privkey.pem" ]]; then cp -a "$target/privkey.pem" "$backup/privkey.pem"; had_key=1; fi

next_cert="${target}/.fullchain.pem.ssl-renewal-next"
next_key="${target}/.privkey.pem.ssl-renewal-next"
install -m 644 "$stage/fullchain.pem" "$next_cert"
install -m 600 "$stage/privkey.pem" "$next_key"
mv -f "$next_cert" "$target/fullchain.pem"
mv -f "$next_key" "$target/privkey.pem"
if nginx -t && systemctl reload nginx; then
  exit 0
fi

echo "Activation failed; restoring previous certificate" >&2
if (( had_cert )); then install -m 644 "$backup/fullchain.pem" "$target/fullchain.pem"; else rm -f "$target/fullchain.pem"; fi
if (( had_key )); then install -m 600 "$backup/privkey.pem" "$target/privkey.pem"; else rm -f "$target/privkey.pem"; fi
nginx -t && systemctl reload nginx || true
exit 1


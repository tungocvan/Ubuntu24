#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
log(){ printf '[%s] %s\n' "$1" "$2"; }
usage(){ echo 'Usage: ssl-env.sh --check | --install'; }
if [[ $# == 0 || ${1:-} == --help ]]; then usage; exit 0; fi
[[ $# == 1 && ( $1 == --check || $1 == --install ) ]] || { usage; exit 2; }
[[ $EUID == 0 ]] || { log ERROR 'Run as root'; exit 1; }
source /etc/os-release
[[ ${ID:-} == ubuntu ]] || { log ERROR 'Ubuntu required'; exit 1; }
check(){
  local missing=0 cmd ca
  printf '=== SSL Environment Check ===\nUbuntu: %s\n' "$VERSION_ID"
  for cmd in mkcert openssl update-ca-certificates flock; do
    if command -v "$cmd" >/dev/null; then log PASS "$cmd"; else log MISSING "$cmd"; missing=1; fi
  done
  if command -v certutil >/dev/null; then log PASS 'NSS tools'; else log WARNING 'NSS tools missing (optional)'; fi
  if [[ -d /etc/.cert && ! -L /etc/.cert && -w /etc/.cert ]]; then log PASS '/etc/.cert'; else log MISSING 'Safe writable /etc/.cert'; missing=1; fi
  if command -v mkcert >/dev/null && ca=$(mkcert -CAROOT) && [[ -s $ca/rootCA.pem && -s $ca/rootCA-key.pem ]] && openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$ca/rootCA.pem" >/dev/null 2>&1; then
    log PASS 'Root CA present and trusted by system'
  else log WARNING 'Root CA missing or not trusted'; missing=1; fi
  if command -v nginx >/dev/null; then
    if nginx -t; then log PASS 'Nginx configuration'; else log WARNING 'Nginx configuration invalid'; missing=1; fi
  else log INFO 'Nginx not installed (optional; SSL deletion requires it)'; fi
  if (( missing )); then log WARNING 'SSL Environment is NOT READY'; return 1; fi
  log SUCCESS 'SSL Environment is READY'
}
if [[ $1 == --check ]]; then check; exit; fi
[[ ! -L /etc/.cert && ( ! -e /etc/.cert || -d /etc/.cert ) ]] || { log ERROR 'Unsafe SSL directory'; exit 1; }
printf 'Install SSL packages and prepare /etc/.cert? Type INSTALL: '
read -r answer || exit 0
[[ $answer == INSTALL ]] || { log INFO 'Cancelled'; exit 0; }
apt-get update
apt-get install -y mkcert openssl ca-certificates libnss3-tools util-linux
if [[ ! -d /etc/.cert ]]; then install -d -m 0755 /etc/.cert; fi
printf 'Install/trust mkcert Root CA on this server? Type TRUST: '
read -r answer || exit 0
if [[ $answer == TRUST ]]; then mkcert -install; fi
check

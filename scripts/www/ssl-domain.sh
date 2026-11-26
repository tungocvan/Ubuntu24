#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
log(){ printf '[%s] %s\n' "$1" "$2"; }
die(){ log ERROR "$*" >&2; exit 1; }
usage(){ cat <<'HELP'
SSL Certificate Manager V2.2
Usage: ssl-domain.sh <root-domain> [--check|--delete]
       ssl-domain.sh --list
Examples:
  ./ssl-domain.sh --list
  ./ssl-domain.sh tungocvan.tk
  ./ssl-domain.sh laravel.tk
  ./ssl-domain.sh tungocvan.tk --check
  ./ssl-domain.sh tungocvan.tk --delete
--list: read-only inventory of PEM files.
--check: read-only; missing SSL returns error.
--delete: backup and delete unused PEM files after confirmation.
Existing certificate: type renew to replace; Enter to cancel.
HELP
}
if [[ $# == 0 || ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
list_ssl(){
  local dir=/etc/.cert f name domain key end start now days status a b host result
  local total=0 valid=0 soon=0 expired=0 invalid=0
  command -v openssl >/dev/null || die 'Install openssl first.'
  [[ ! -L $dir ]] || die 'Unsafe certificate directory.'
  printf 'SSL Certificate Manager V2.2\nDirectory: %s\n\n' "$dir"
  if [[ ! -d $dir ]]; then log INFO 'No certificate directory found.'; return 0; fi
  [[ -r $dir && -x $dir ]] || die 'Cannot read certificate directory.'
  shopt -s nullglob
  local -a files=("$dir"/*.pem)
  printf '%-35s %-12s %8s %s\n' 'Certificate' 'Expires' 'Days' 'Status'
  now=$(date +%s)
  for f in "${files[@]}"; do
    name=${f##*/}
    [[ $name != *-key.pem ]] || continue
    domain=${name%.pem}; domain=${domain%-cert}; key="$dir/$domain-key.pem"
    total=$((total+1)); end=-; days=-; status=INVALID
    if [[ -f $f && ! -L $f ]] && result=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null) && end=$(date -u -d "${result#notAfter=}" +%s 2>/dev/null); then
      days=$(( (end-now)/86400 )); end=$(date -u -d "@$end" +%F)
      if ! openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1; then status=EXPIRED
      elif [[ ! -s $key || -L $key || ! -f $key ]]; then status=MISSING_KEY
      elif a=$(openssl x509 -in "$f" -pubkey -noout 2>/dev/null) && b=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) && [[ $a == "$b" ]]; then
        status=VALID
        start=$(openssl x509 -in "$f" -noout -startdate)
        if ! start=$(date -d "${start#notBefore=}" +%s) || (( start > now )); then status=INVALID; fi
        for host in "$domain" "ssl-check.$domain"; do
          result=$(openssl x509 -in "$f" -noout -checkhost "$host" 2>/dev/null) || result=''
          [[ $result == *'does match certificate' ]] || status=INVALID
        done
        if [[ $status == VALID ]] && (( days < 30 )); then status=EXPIRING; fi
      else status=KEY_MISMATCH; fi
    fi
    case $status in VALID) valid=$((valid+1));; EXPIRING) soon=$((soon+1));; EXPIRED) expired=$((expired+1));; *) invalid=$((invalid+1));; esac
    printf '%-35s %-12s %8s %s\n' "$name" "$end" "$days" "$status"
  done
  printf '\nTotal certificates: %s\nValid: %s\nExpiring soon: %s\nExpired: %s\nInvalid: %s\n' "$total" "$valid" "$soon" "$expired" "$invalid"
  printf '\nPEM files (names only):\n'
  for f in "${files[@]}"; do
    printf '  %s' "${f##*/}"
    if [[ $f == *-key.pem ]]; then
      domain=${f##*/}; domain=${domain%-key.pem}
      if [[ ! -e $dir/$domain.pem && ! -e $dir/$domain-cert.pem ]]; then printf ' [ORPHAN_KEY]'; fi
    fi
    printf '\n'
  done
}
if [[ ${1:-} == --list ]]; then
  [[ $# == 1 ]] || die 'Usage: ssl-domain.sh --list'
  list_ssl
  exit 0
fi
[[ $# == 1 || ( $# == 2 && ( $2 == --check || $2 == --delete ) ) ]] || die 'Invalid arguments; use --help.'
domain=${1,,}; check=${2:-}
[[ ${#domain} -le 251 && $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die 'Invalid domain.'
[[ $EUID == 0 ]] || die 'Run as root.'
command -v openssl >/dev/null || die 'Install openssl first.'
dir=/etc/.cert
cert="$dir/$domain-cert.pem"; key="$dir/$domain-key.pem"
# Match setup-project.sh certificate preference.
if [[ -e "$dir/$domain.pem" || -L "$dir/$domain.pem" ]]; then cert="$dir/$domain.pem"; fi
exists(){ [[ -e $1 || -L $1 ]]; }
for f in "$cert" "$key"; do [[ ! -L $f ]] || die "Refusing symbolic link: $f"; if exists "$f"; then [[ -f $f ]] || die "Not a regular file: $f"; fi; done
info(){
  local c=$1 k=$2 end now days a b
  printf 'Domain: %s\nCertificate: %s\nPrivate key: %s\n' "$domain" "$c" "$k"
  if [[ ! -s $c || ! -s $k ]]; then log WARNING 'Missing or empty PEM file.'; return 1; fi
  openssl x509 -in "$c" -noout -subject -issuer -dates -ext subjectAltName || return 1
  end=$(openssl x509 -in "$c" -noout -enddate) || return 1
  end=$(date -d "${end#notAfter=}" +%s) || return 1
  now=$(date +%s); days=$(( (end-now)/86400 ))
  printf 'Remaining days (approx): %s\n' "$days"
  if (( end <= now )); then log WARNING 'Certificate expired.'; return 1; fi
  if (( days < 30 )); then log WARNING 'Certificate expires within 30 days.'; fi
  a=$(openssl x509 -in "$c" -pubkey -noout) || return 1
  b=$(openssl pkey -in "$k" -passin pass: -pubout) || return 1
  [[ $a == "$b" ]] || { log WARNING 'Certificate/key mismatch.'; return 1; }
  for host in "$domain" "ssl-check.$domain"; do
    a=$(openssl x509 -in "$c" -noout -checkhost "$host") || return 1
    [[ $a == *'does match certificate' ]] || { log WARNING "Hostname mismatch: $host"; return 1; }
  done
  log SUCCESS 'Certificate and key checks passed.'
}
# Dispatch read-only mode before any creation or renewal.
if [[ $check == --check ]]; then
  info "$cert" "$key" || die 'SSL missing or invalid; no changes made.'
  exit 0
fi
if [[ $check == --delete ]]; then
  files=("$dir/$domain.pem" "$dir/$domain-cert.pem" "$key")
  present=()
  for f in "${files[@]}"; do
    if exists "$f"; then
      [[ -f $f && ! -L $f ]] || die "Unsafe file: $f"
      present+=("$f")
    fi
  done
  (( ${#present[@]} )) || { log INFO 'No SSL files found; nothing to delete.'; exit 0; }
  [[ ! -L $dir ]] || die 'Unsafe certificate directory.'
  command -v nginx >/dev/null || die 'Cannot verify Nginx usage: nginx unavailable.'
  exec 9>"$dir/.ssl-domain.lock"; flock -n 9 || die 'Another SSL operation is running.'
  config=$(nginx -T 2>&1) || die 'Cannot verify Nginx configuration; deletion refused.'
  for f in "${present[@]}"; do
    if grep -Fq -- "$f" <<< "$config"; then die "Nginx references $f; disable or reconfigure the site first."; fi
  done
  # Dynamic paths cannot be reliably checked by literal matching.
  if grep -E '^[[:space:]]*ssl_certificate(_key)?[[:space:]]' <<< "$config" | grep -Fq '$'; then
    die 'Dynamic Nginx certificate paths detected; deletion refused.'
  fi
  printf 'Files to remove (Root CA retained):\n'; printf '  %s\n' "${present[@]}"
  read -r -p "Type DELETE $domain to confirm: " answer || exit 0
  [[ $answer == "DELETE $domain" ]] || { log INFO 'Cancelled.'; exit 0; }
  backup=$(mktemp -d "$dir/.deleted-$domain.XXXXXXXX")
  for f in "${present[@]}"; do cp -a -- "$f" "$backup/"; done
  log INFO "Backup: $backup"
  for f in "${present[@]}"; do rm -- "$f"; done
  if ! nginx -t; then
    for f in "${present[@]}"; do cp -a -- "$backup/${f##*/}" "$f"; done
    die 'Nginx validation failed; files restored.'
  fi
  log SUCCESS "SSL removed: $domain"
  exit 0
fi
if exists "$cert" || exists "$key"; then
  info "$cert" "$key" || log WARNING 'Existing SSL failed validation.'
  read -r -p 'Type renew to create a new certificate (Enter to cancel): ' answer || exit 0
  [[ $answer == renew ]] || { log INFO 'Cancelled; SSL unchanged.'; exit 0; }
fi
command -v mkcert >/dev/null || die 'Install mkcert first.'
[[ ! -L $dir ]] || die 'Certificate directory is a symbolic link.'
mkdir -p -- "$dir"
exec 9>"$dir/.ssl-domain.lock"; flock -n 9 || die 'Another SSL operation is running.'
# Do not silently change the trust store: install CA only with explicit consent.
read -r -p 'Install/trust mkcert Root CA on this server? [y/N]: ' answer || exit 1
if [[ $answer == y ]]; then mkcert -install; fi
stage=$(mktemp -d "$dir/.ssl-stage.XXXXXXXX")
trap 'rm -f -- "$stage/cert.pem" "$stage/key.pem"; rmdir -- "$stage"' EXIT
mkcert -cert-file "$stage/cert.pem" -key-file "$stage/key.pem" "*.$domain" "$domain"
info "$stage/cert.pem" "$stage/key.pem" || die 'New certificate failed validation.'
chmod 600 "$stage/key.pem"; chmod 644 "$stage/cert.pem"
backup=$(mktemp -d "$dir/.backup-$domain.XXXXXXXX")
for f in "$cert" "$key"; do if exists "$f"; then cp -a -- "$f" "$backup/"; fi; done
log INFO "Backup: $backup"
restore(){
  local f
  for f in "$cert" "$key"; do
    if [[ -f "$backup/${f##*/}" ]]; then cp -a -- "$backup/${f##*/}" "$f"; else rm -f -- "$f"; fi
  done
}
if ! mv -fT -- "$stage/key.pem" "$key" || ! mv -fT -- "$stage/cert.pem" "$cert"; then restore; die 'Installation failed; restored previous files.'; fi
if command -v nginx >/dev/null; then
  if ! nginx -t; then restore; die 'Nginx validation failed; restored previous files.'; fi
  if systemctl is-active --quiet nginx; then
    if ! systemctl reload nginx; then restore; nginx -t && systemctl reload nginx || log ERROR 'Manual Nginx recovery required.'; die 'Reload failed; restored previous files.'; fi
  fi
fi
log SUCCESS "SSL ready: $domain"
info "$cert" "$key"

#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
trap 'log ERROR "Failed at line $LINENO; inspect partial deployment before retrying." >&2' ERR
usage() { printf 'Usage: %s <subdomain|full-subdomain> [--dry-run|--check-ssl]\n' "${0##*/}"; }
[[ ${1:-} != --help && ${1:-} != -h ]] || { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
[[ $# == 1 || $2 == --dry-run || $2 == --check-ssl ]] || die 'Unknown option'
BASE=/var/www
# V2.2: original project naming, custom domain and SSL preflight.
DEFAULT_DOMAIN=laravel.tk
INPUT=${1,,}
if [[ "$INPUT" == *.* ]]; then
    PROJECT=${INPUT%%.*}
    ROOT_DOMAIN=${INPUT#*.}
else
    PROJECT=$INPUT
    ROOT_DOMAIN=$DEFAULT_DOMAIN
fi
[[ "$PROJECT" =~ ^[a-z0-9]([a-z0-9-]{0,58}[a-z0-9])?$ ]] || die 'Invalid project label (max 60 characters).'
[[ "$ROOT_DOMAIN" == *.* && "$ROOT_DOMAIN" != .* && "$ROOT_DOMAIN" != *. && "$ROOT_DOMAIN" != *..* ]] || die 'Invalid root domain.'
IFS=. read -r -a labels <<< "$ROOT_DOMAIN"
for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die 'Invalid DNS label.'
done
DOMAIN="$PROJECT.$ROOT_DOMAIN"
(( ${#DOMAIN} <= 253 )) || die 'Domain too long.'
CERT_DIR=/etc/.cert
SSL_CERT="$CERT_DIR/$ROOT_DOMAIN.pem"
SSL_KEY="$CERT_DIR/$ROOT_DOMAIN-key.pem"
if [[ ! -e "$SSL_CERT" && -f "$CERT_DIR/$ROOT_DOMAIN-cert.pem" ]]; then
    SSL_CERT="$CERT_DIR/$ROOT_DOMAIN-cert.pem"
fi
APP_URL="https://$DOMAIN"
DB_NAME="db_${PROJECT//-/_}"
PROJECT_ROOT="$BASE/$PROJECT"
TEMPLATE="$BASE/domain.tk"
NEW_FILE="/etc/nginx/sites-available/$DOMAIN"
SYMLINK="/etc/nginx/sites-enabled/$DOMAIN"
REPO=git@github.com:tungocvan/laravel-basic.git
printf 'Project: %s\nDomain: %s\nURL: %s\nDatabase: %s\nDirectory: %s\nNginx: %s\n' "$PROJECT" "$DOMAIN" "$APP_URL" "$DB_NAME" "$PROJECT_ROOT" "$NEW_FILE"
printf 'Root domain: %s\nSSL certificate: %s\nSSL key: %s\n' "$ROOT_DOMAIN" "$SSL_CERT" "$SSL_KEY"
# V2.2 SSL preflight: read-only, also runs in dry-run mode.
check_ssl() {
    local file missing=0 start start_epoch now cert_pub key_pub host_result
    command -v openssl >/dev/null || die 'Install openssl first.'
    log INFO "Checking SSL for $DOMAIN"
    for file in "$SSL_CERT" "$SSL_KEY"; do
        if [[ -f "$file" && -r "$file" && -s "$file" ]]; then
            log SUCCESS "Found: $file"
        else
            log ERROR "Missing, empty or unreadable: $file" >&2
            missing=1
        fi
    done
    (( missing == 0 )) || die "Please create SSL for $ROOT_DOMAIN first. Project creation cancelled."
    openssl x509 -in "$SSL_CERT" -noout >/dev/null 2>&1 || die 'Invalid certificate PEM.'
    start=$(openssl x509 -in "$SSL_CERT" -noout -startdate) || die 'Cannot read certificate start date.'
    start_epoch=$(LC_ALL=C date -u -d "${start#notBefore=}" +%s) || die 'Invalid certificate start date.'
    now=$(date +%s)
    (( now >= start_epoch )) || die 'Certificate is not yet valid.'
    openssl x509 -in "$SSL_CERT" -noout -checkend 0 >/dev/null || die 'Certificate expired.'
    if ! openssl x509 -in "$SSL_CERT" -noout -checkend 2592000 >/dev/null; then
        log WARNING 'Certificate expires within 30 days.'
    fi
    # OpenSSL x509 -checkhost may return zero even on hostname mismatch.
    host_result=$(LC_ALL=C openssl x509 -in "$SSL_CERT" -noout -checkhost "$DOMAIN") || die 'Hostname check failed.'
    [[ "$host_result" == "Hostname $DOMAIN does match certificate" ]] || die "Certificate does not match $DOMAIN."
    cert_pub=$(openssl x509 -in "$SSL_CERT" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256) || die 'Cannot read certificate public key.'
    openssl pkey -in "$SSL_KEY" -passin pass: -check -noout >/dev/null 2>&1 || die 'Invalid or encrypted private key (unattended deployment requires readable unencrypted key).'
    key_pub=$(openssl pkey -in "$SSL_KEY" -passin pass: -pubout -outform DER | openssl dgst -sha256) || die 'Cannot read private key public component.'
    [[ "$cert_pub" == "$key_pub" ]] || die 'Certificate and private key do not match.'
    log SUCCESS "SSL preflight passed for $DOMAIN"
}
check_ssl
if [[ ${2:-} == --dry-run || ${2:-} == --check-ssl ]]; then
    log INFO 'Read-only check complete; no project or database created.'
    exit 0
fi
(( EUID == 0 )) || die 'Run as root or with sudo (Nginx configuration requires root).'
for cmd in git php composer npm python3 mysql nginx systemctl; do command -v "$cmd" >/dev/null || die "Missing: $cmd"; done
[[ -f "$TEMPLATE" && -f "$BASE/db.inc" && ! -L "$BASE/db.inc" ]] || die 'Missing template or unsafe db.inc'
[[ $(pwd -P) == "$BASE" ]] || die "Run from $BASE"
for path in "$PROJECT_ROOT" "$NEW_FILE" "$SYMLINK"; do
    [[ ! -e "$path" && ! -L "$path" ]] || die "Already exists: $path (no overwrite)"
done
for token in __DOMAIN__ __PROJECT_ROOT__ __SSL_CERT__ __SSL_KEY__; do
    grep -Fq -- "$token" "$TEMPLATE" || die "Template missing $token; install updated domain.tk"
done
[[ -S /run/php/php8.4-fpm.sock ]] || die 'PHP 8.4-FPM socket unavailable'
nginx -t
umask 022
OPTS=$(mktemp)
trap 'rm -f -- "$OPTS"' EXIT
# Parse the same literal key=value format used by Ubuntu24 database manager.
python3 - "$BASE/db.inc" "$OPTS" <<'PY'
import sys, pathlib, re
p=pathlib.Path(sys.argv[1]); v={}
if p.stat().st_mode & 0o077: raise SystemExit('db.inc must have mode 600')
for line in p.read_text().splitlines():
    if not line or line.startswith('#'): continue
    k, sep, val=line.partition('=')
    if not sep or k not in ('username','password','hostname','port'): raise SystemExit('Invalid db.inc key')
    v[k]=val
v.setdefault('port','3306')
if not v.get('username') or 'password' not in v or not v.get('hostname') or not v['port'].isdigit() or not 1<=int(v['port'])<=65535: raise SystemExit('Invalid db.inc settings')
def quote(s): return '"'+s.replace('\\','\\\\').replace('"','\\"')+'"'
pathlib.Path(sys.argv[2]).write_text('[client]\n'+''.join(k+'='+quote(v[src])+'\n' for k,src in [('user','username'),('password','password'),('host','hostname'),('port','port')])+'protocol=tcp\n')
PY
mysql --defaults-file="$OPTS" --connect-timeout=5 --execute='SELECT 1;' >/dev/null
existing=$(mysql --defaults-file="$OPTS" --batch --skip-column-names --execute="SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME';")
[[ -z "$existing" ]] || die "Database already exists: $DB_NAME (no automatic reuse)"
# No IF NOT EXISTS: existing database must never be reused or seeded accidentally.
log INFO 'Cloning Laravel template'
git clone "$REPO" "$PROJECT_ROOT"
cd "$PROJECT_ROOT"
[[ -f .env.example && ! -e .env && ! -L .env ]] || die 'Missing .env.example or existing .env'
(umask 077; cp .env.example .env)
python3 - "$BASE/db.inc" "$PROJECT" "$APP_URL" "$DB_NAME" <<'PY'
import sys, pathlib, re
v=dict(line.split('=',1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line and not line.startswith('#'))
p=pathlib.Path('.env'); content=p.read_text()
def quote(s): return '"'+s.replace('\\','\\\\').replace('"','\\"').replace('$','\\$')+'"'
for k,val in {'APP_NAME':sys.argv[2],'APP_URL':sys.argv[3],'DB_CONNECTION':'mysql','DB_DATABASE':sys.argv[4],'DB_HOST':v['hostname'],'DB_PORT':v.get('port','3306'),'DB_USERNAME':v['username'],'DB_PASSWORD':v['password']}.items():
    pattern=rf'(?m)^{k}=.*$'; replacement=k+'='+quote(val)
    content=re.sub(pattern,lambda _:replacement,content) if re.search(pattern,content) else content.rstrip('\n')+'\n'+replacement+'\n'
p.write_text(content); p.chmod(0o600)
PY
# Build as the invoking user when sudo is used; direct root deployments retain original behavior.
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    chown -R "$SUDO_USER" "$PROJECT_ROOT"
    run_app() { sudo -H -u "$SUDO_USER" -- "$@"; }
else
    log WARNING 'Running trusted project build as root.'
    run_app() { "$@"; }
fi
run_app composer install --no-interaction --prefer-dist
run_app php artisan key:generate
mysql --defaults-file="$OPTS" --execute="CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
run_app php artisan migrate --force
run_app php artisan db:seed --force
run_app php artisan optimize:clear
if [[ -f package-lock.json ]]; then run_app npm ci; else run_app npm install; fi
run_app npm run build
run_app php artisan storage:link
chown -R www-data:www-data "$PROJECT_ROOT"
chmod 600 .env
# Render only explicit placeholders; refuse overwrite and roll back newly created site on failed test.
( set -o noclobber; sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__PROJECT_ROOT__|$PROJECT_ROOT|g" -e "s|__SSL_CERT__|$SSL_CERT|g" -e "s|__SSL_KEY__|$SSL_KEY|g" "$TEMPLATE" > "$NEW_FILE" )
if ! ln -s "$NEW_FILE" "$SYMLINK"; then rm -f -- "$NEW_FILE"; die 'Cannot enable site'; fi
if ! nginx -t || ! systemctl reload nginx; then
    rm -f -- "$SYMLINK" "$NEW_FILE"
    nginx -t && systemctl reload nginx || true
    die 'Nginx deployment failed; new site configuration removed, project/database preserved.'
fi
log SUCCESS "Project ready: $APP_URL"

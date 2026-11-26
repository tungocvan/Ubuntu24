#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf '[%s] %s\n' "$1" "$2"; }
die(){ log ERROR "$1" >&2; exit 1; }
usage(){
  cat <<EOF
Usage: ${0##*/} <subdomain|full-domain> [--dry-run]
Examples:
  ./${0##*/} app
  ./${0##*/} app.laravel.tk
  ./${0##*/} app.tungocvan.tk
  ./${0##*/} app.tungocvan.tk --dry-run
  ./${0##*/} --help
Default domain: laravel.tk
Database config: /var/www/db.inc
WARNING: Deletes project files, database and Nginx site after confirmation.
SSL certificates are retained. Back up data first.
EOF
}
[[ $# != 0 ]] || { usage; exit 0; }
[[ ${1:-} != --help && ${1:-} != -h ]] || { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
[[ $# == 1 || $2 == --dry-run ]] || die 'Unknown option'
DOMAIN=${1,,}
[[ $DOMAIN == *.* ]] || DOMAIN+=.laravel.tk
[[ ${#DOMAIN} -le 253 && $DOMAIN == *.*.* && $DOMAIN != *. && $DOMAIN != .* && $DOMAIN != *..* ]] || die 'Invalid domain'
IFS=. read -ra labels <<< "$DOMAIN"
for label in "${labels[@]}"; do
  [[ $label =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die 'Invalid DNS label'
done
PROJECT=${DOMAIN%%.*}
DB_NAME=db_${PROJECT//-/_}
[[ ${#DB_NAME} -le 64 ]] || die 'Database name too long'
PROJECT_PATH=/var/www/$PROJECT
AVAILABLE=/etc/nginx/sites-available/$DOMAIN
ENABLED=/etc/nginx/sites-enabled/$DOMAIN
DB_CONFIG=/var/www/db.inc
printf 'Project: %s\nDomain: %s\nDirectory: %s\nDatabase: %s\nNginx: %s\nEnabled: %s\n' "$PROJECT" "$DOMAIN" "$PROJECT_PATH" "$DB_NAME" "$AVAILABLE" "$ENABLED"
if [[ ${2:-} == --dry-run ]]; then
  log INFO 'Preview only; no changes. Ownership checks run before deletion.'; exit 0
fi
[[ $EUID == 0 ]] || die 'Run as root'
for cmd in nginx systemctl python3 find mktemp; do command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"; done
if command -v mysql >/dev/null; then DB_CLIENT=mysql
elif command -v mariadb >/dev/null; then DB_CLIENT=mariadb
else die 'Missing mysql/mariadb client'; fi
[[ -f $DB_CONFIG && ! -L $DB_CONFIG ]] || die 'Missing or unsafe db.inc'
[[ $(stat -c %u "$DB_CONFIG") == 0 ]] || die 'db.inc must be owned by root'
[[ $(stat -c %a "$DB_CONFIG") == 600 || $(stat -c %a "$DB_CONFIG") == 400 ]] || die 'db.inc must have mode 600 or 400'
umask 077
DB_TEMP=$(mktemp)
trap 'unlink "$DB_TEMP"' EXIT
# Parse literal key=value; never execute db.inc as shell code.
python3 - "$DB_CONFIG" "$DB_TEMP" "$PROJECT_PATH/.env" <<'DBPY'
import pathlib, sys, re
config, temp, env = map(pathlib.Path, sys.argv[1:])
v = {}
for line in config.read_text().splitlines():
    if not line.strip() or line.lstrip().startswith('#'): continue
    k, sep, value = line.partition('=')
    k = k.strip()
    if not sep or k not in ('username','password','hostname','port') or k in v:
        sys.exit('[ERROR] Invalid or duplicate db.inc entry')
    v[k] = value.strip()
if not all(v.get(k) for k in ('username','password','hostname')): sys.exit('[ERROR] Missing DB credentials')
port = v.get('port','3306')
if not port.isascii() or not port.isdigit() or not 1 <= int(port) <= 65535: sys.exit('[ERROR] Invalid DB port')
# Refuse to delete from a different database endpoint than the project uses.
if env.is_symlink() or not env.is_file(): sys.exit('[ERROR] Missing or unsafe .env')
for key, expected in [('DB_HOST',v['hostname']),('DB_PORT',port)]:
    vals = re.findall(r'^'+key+r'=(.*)$',env.read_text(),re.M)
    if len(vals)!=1 or vals[0].strip().strip(chr(34)+chr(39))!=expected:
        sys.exit('[ERROR] Database endpoint mismatch: '+key)
def quote(s):
    if any(ord(c)<32 for c in s): sys.exit('[ERROR] Invalid control character in db.inc')
    return chr(34)+s.replace(chr(92),chr(92)*2).replace(chr(34),chr(92)+chr(34))+chr(34)
temp.write_text('[client]\n'+''.join(k+'='+quote(val)+'\n' for k,val in [('user',v['username']),('password',v['password']),('host',v['hostname']),('port',port)]))
DBPY
db_query(){ "$DB_CLIENT" --defaults-file="$DB_TEMP" --protocol=TCP --connect-timeout=5 --batch --skip-column-names --execute="$1"; }
db_exists(){ db_query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME';"; }
# Check access before disabling Nginx; USE also verifies the target is visible.
[[ $(db_exists) == 1 ]] || die 'Database missing or inaccessible; no changes made'
db_query "USE \`$DB_NAME\`;" >/dev/null
[[ -d $PROJECT_PATH && ! -L $PROJECT_PATH ]] || die 'Project directory missing or symbolic link'
[[ -f $AVAILABLE && ! -L $AVAILABLE ]] || die 'Expected Nginx configuration missing or symbolic link'
[[ ! -e $ENABLED && ! -L $ENABLED || -L $ENABLED && $(readlink -f -- "$ENABLED") == "$AVAILABLE" ]] || die 'Unexpected enabled configuration'
# Require explicit ownership in the generated config and .env; reject other references.
python3 - "$DOMAIN" "$PROJECT_PATH" "$AVAILABLE" "$DB_NAME" <<'PY'
import pathlib,re,sys
host,root,config,db=sys.argv[1:]
def read(p): return p.read_text()
p=pathlib.Path(config)
s=re.sub(r'(?m)#.*$', '', read(p))
if not re.search(r'\bserver_name\s+'+re.escape(host)+r'\s*;',s) or not re.search(r'\broot\s+'+re.escape(root)+r'/public\s*;',s):
    sys.exit('[ERROR] Nginx ownership mismatch')
env=pathlib.Path(root)/'.env'
if env.is_symlink() or not env.is_file(): sys.exit('[ERROR] Missing or unsafe .env')
for key,value in [('APP_URL','https://'+host),('DB_DATABASE',db)]:
    vals=re.findall(r'^'+key+r'=(.*)$',read(env),re.M)
    if len(vals)!=1 or vals[0].strip().strip('"\'')!=value: sys.exit('[ERROR] .env ownership mismatch: '+key)
for directory in ('/etc/nginx/sites-available','/etc/nginx/sites-enabled','/etc/nginx/conf.d'):
    for other in pathlib.Path(directory).glob('*'):
        if other.is_file() and other.resolve()!=p.resolve():
            if re.search(re.escape(root)+r'(?=/|\s|;|["\'])',read(other)):
                sys.exit('[ERROR] Shared project reference: '+str(other))
for other in pathlib.Path('/var/www').glob('*/.env'):
    if other.resolve()!=env.resolve() and other.is_file():
        if any(v.strip().strip('"\'')==db for v in re.findall(r'^DB_DATABASE=(.*)$',read(other),re.M)):
            sys.exit('[ERROR] Possible shared database: '+str(other))
PY
nginx -t
log WARNING 'Permanent deletion of project files and database. Back up both first. SSL files are retained.'
read -r -p "Type DELETE $DOMAIN to confirm: " confirm
[[ $confirm == "DELETE $DOMAIN" ]] || { log INFO 'Cancelled'; exit 0; }
# Keep configuration backup; disable site before removing data.
BACKUP=$(mktemp -d /var/backups/laravel-delete.XXXXXXXX)
cp -a -- "$AVAILABLE" "$BACKUP/config"
was_enabled=0
if [[ -L $ENABLED ]]; then was_enabled=1; cp -a -- "$ENABLED" "$BACKUP/enabled"; unlink "$ENABLED"; fi
if ! nginx -t || ! systemctl reload nginx; then
  if (( was_enabled )); then cp -a -- "$BACKUP/enabled" "$ENABLED"; fi
  nginx -t && systemctl reload nginx || true
  die 'Nginx disable failed; data untouched'
fi
log INFO "Nginx backup: $BACKUP"
# Integrated database deletion; never report success on SQL failure.
if ! db_query "DROP DATABASE \`$DB_NAME\`;"; then
  if (( was_enabled )); then cp -a -- "$BACKUP/enabled" "$ENABLED"; fi
  nginx -t && systemctl reload nginx || log WARNING 'Nginx rollback failed'
  die 'DROP DATABASE failed; project files retained; verify database state'
fi
[[ $(db_exists) == 0 ]] || die 'Cannot verify database deletion; project files retained; site disabled'
log SUCCESS "Database deleted: $DB_NAME"
read -r -p "Type REMOVE $DOMAIN to remove files: " confirm
[[ $confirm == "REMOVE $DOMAIN" ]] || die 'Database deleted; files retained; site disabled'
[[ -d $PROJECT_PATH && ! -L $PROJECT_PATH ]] || die 'Project path changed'
find "$PROJECT_PATH" -xdev -depth -delete
[[ ! -e $PROJECT_PATH ]] || die 'Project removal incomplete'
unlink "$AVAILABLE"
log SUCCESS "Project files and Nginx configuration removed: $DOMAIN"
log INFO 'SSL retained. Remove the Windows hosts entry manually if no longer needed.'

#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/common.sh"
db_pause() { printf '\nPress Enter to continue...'; IFS= read -r _ || true; }
db_test() { db_query 'SELECT VERSION() AS server_version, @@version_comment AS engine;'; }
db_info() { db_query 'SELECT VERSION() AS version, @@version_comment AS engine, @@hostname AS server_hostname, @@port AS server_port, @@version_compile_os AS server_os;'; }
db_list() { db_query 'SHOW DATABASES;'; }
db_tables() {
  local database
  printf 'Database name: '
  IFS= read -r database || return 0
  [[ "$database" =~ ^[A-Za-z0-9_]+$ ]] || { printf '[ERROR] Only simple alphanumeric/underscore database names supported.\n'; return 1; }
  if ! db_query 'SHOW DATABASES;' | tail -n +2 | grep -Fxq -- "$database"; then
    printf '[ERROR] Database not found or not accessible.\n'; return 1
  fi
  local output
  output=$(db_query "SHOW TABLES FROM \`$database\`;") || return 1
  if [[ -z "$output" ]]; then
    printf '[INFO] Database is empty (0 tables): %s\n' "$database"
  else
    printf '%s\n' "$output"
  fi
}
db_sizes() {
  db_query "SELECT s.SCHEMA_NAME AS database_name, COUNT(t.TABLE_NAME) AS table_count, COALESCE(ROUND(SUM(COALESCE(t.DATA_LENGTH,0)+COALESCE(t.INDEX_LENGTH,0))/1024/1024,2),0) AS size_mb FROM information_schema.SCHEMATA AS s LEFT JOIN information_schema.TABLES AS t ON s.SCHEMA_NAME=t.TABLE_SCHEMA GROUP BY s.SCHEMA_NAME ORDER BY size_mb DESC, s.SCHEMA_NAME;"
}
db_connections() { db_query 'SHOW PROCESSLIST;'; }
db_show_grants() {
  printf '[INFO] Grants for current database account:\n'
  db_query 'SHOW GRANTS FOR CURRENT_USER();'
}
db_account_directory_source() {
  # Prefer native system tables when authorized; otherwise use restricted views.
  # Suppress probe errors to avoid misleading ERROR 1049 messages.
  if db_query 'SELECT User, Host FROM mysql.user LIMIT 0;' >/dev/null 2>&1; then
    printf 'mysql.user'
  elif db_query 'SELECT username, allowed_host FROM admin_tools.database_users LIMIT 0;' >/dev/null 2>&1; then
    printf 'admin_tools.database_users'
  else
    printf '[ERROR] Cannot list accounts: no access to mysql.user or admin_tools.database_users.\n' >&2
    return 1
  fi
}
db_list_users() {
  local source
  source=$(db_account_directory_source) || return 1
  printf '[INFO] Listing accounts through %s.\n' "$source"
  if [[ "$source" == mysql.user ]]; then
    db_query 'SELECT User AS username, Host AS allowed_host FROM mysql.user ORDER BY User, Host;'
  else
    db_query 'SELECT username, allowed_host FROM admin_tools.database_users ORDER BY username, allowed_host;'
  fi
}
db_account_exists() {
  local name="$1" host="$2" result source
  source=$(db_account_directory_source) || return 2
  if [[ "$source" == mysql.user ]]; then
    result=$(db_query "SELECT COUNT(*) FROM mysql.user WHERE User='$name' AND Host='$host';") || return 2
  else
    result=$(db_query "SELECT COUNT(*) FROM admin_tools.database_users WHERE username='$name' AND allowed_host='$host';") || return 2
  fi
  [[ "$(printf '%s\n' "$result" | tail -n 1)" == 1 ]]
}
db_delete_user() {
  local name host answer current
  printf 'Database username to delete: '
  IFS= read -r name || return 0
  printf 'Account host [localhost]: '
  IFS= read -r host || return 0
  host="${host:-localhost}"
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ || ! "$host" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    printf '[ERROR] Invalid username or host.\n'
    return 1
  fi
  if [[ "$name" == root || "$name" == mysql || "$name" == mariadb.sys || "$name" == debian-sys-maint || "$name" == tungocvan ]]; then
    printf '[ERROR] Protected administrative/system account.\n'
    return 1
  fi
  current=$(db_query 'SELECT CURRENT_USER();' | tail -n 1) || return 1
  if [[ "$current" == "$name@$host" ]]; then
    printf '[ERROR] Cannot delete the currently authenticated account.\n'
    return 1
  fi
  if db_account_exists "$name" "$host"; then
    :
  else
    printf '[ERROR] Account not found or cannot verify existence.\n'
    return 1
  fi
  printf '[WARNING] DROP USER %s@%s revokes access and may break applications.\n' "$name" "$host"
  printf 'Re-enter exact account (%s@%s) to confirm: ' "$name" "$host"
  IFS= read -r answer || return 0
  [[ "$answer" == "$name@$host" ]] || { printf '[INFO] Cancelled.\n'; return 0; }
  printf 'Type DELETE to permanently drop the database account: '
  IFS= read -r answer || return 0
  [[ "$answer" == DELETE ]] || { printf '[INFO] Cancelled.\n'; return 0; }
  if printf "DROP USER '%s'@'%s';\n" "$name" "$host" | db_exec_stdin; then
    printf '[SUCCESS] Deleted database account %s@%s.\n' "$name" "$host"
  else
    printf '[ERROR] DROP USER failed (privileges or active dependencies).\n'
    return 1
  fi
}
db_create_user() {
  local name host password password_again answer sql_password
  printf 'New database username: '
  IFS= read -r name || return 0
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]]; then
    printf '[ERROR] Invalid username.\n'
    return 1
  fi
  printf 'Allowed host [localhost]: '
  IFS= read -r host || return 0
  host="${host:-localhost}"
  if [[ ! "$host" =~ ^[A-Za-z0-9_.:%_-]+$ || ${#host} -gt 255 ]]; then
    printf '[ERROR] Invalid host.\n'
    return 1
  fi
  printf 'New password: '
  IFS= read -r -s password || return 0
  printf '\nConfirm password: '
  IFS= read -r -s password_again || return 0
  printf '\n'
  if [[ -z "$password" || "$password" != "$password_again" ]]; then
    printf '[ERROR] Password empty or mismatch.\n'
    return 1
  fi
  unset password_again
  if db_account_exists "$name" "$host"; then
    printf '[ERROR] Account %s@%s already exists.\n' "$name" "$host"
    return 1
  else
    local check_status=$?
    if (( check_status == 2 )); then
      printf '[ERROR] Cannot check for duplicate accounts; no changes made.\n'
      return 1
    fi
  fi
  if [[ "$host" == *%* || "$host" == *_* ]]; then
    printf '[WARNING] Wildcard host (%s) may allow authentication from many client addresses if MySQL networking and firewall permit it.\n' "$host"
    printf '[WARNING] Prefer localhost, a specific client IP, or a VPN address for production.\n'
  fi
  printf 'Create %s@%s without database grants? Type YES: ' "$name" "$host"
  IFS= read -r answer || return 0
  [[ "$answer" == YES ]] || { printf '[INFO] Cancelled.\n'; return 0; }
  sql_password="${password//\'/\'\'}"
  unset password
  if printf "SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';\nCREATE USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$name" "$host" "$sql_password" | db_exec_stdin; then
    printf '[SUCCESS] Created %s@%s (no grants).\n' "$name" "$host"
  else
    printf '[ERROR] Create user failed; check CREATE USER privilege or duplicate account.\n'
    return 1
  fi
  unset sql_password
}
db_grant_privileges() {
  local name host database level privileges answer exists status
  printf 'Database username: '
  IFS= read -r name || return 0
  printf 'Account host [localhost]: '
  IFS= read -r host || return 0
  host="${host:-localhost}"
  printf 'Target database: '
  IFS= read -r database || return 0
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ || ! "$host" =~ ^[A-Za-z0-9_.:-]+$ || ${#host} -gt 255 || ! "$database" =~ ^[A-Za-z0-9_]+$ ]]; then
    printf '[ERROR] Invalid account or database name.\n'
    return 1
  fi
  case "$database" in
    mysql|information_schema|performance_schema|sys|admin_tools)
      printf '[ERROR] System and administration databases are protected.\n'
      return 1 ;;
  esac
  if db_account_exists "$name" "$host"; then
    :
  else
    printf '[ERROR] Database user does not exist or cannot be verified.\n'
    return 1
  fi
  exists=$(db_query "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$database';") || return 1
  if [[ "$(printf '%s\n' "$exists" | tail -n 1)" != 1 ]]; then
    printf '[ERROR] Database not found or not visible to this account.\n'
    return 1
  fi
  printf '1) READ ONLY (SELECT)\n2) READ/WRITE (SELECT, INSERT, UPDATE, DELETE)\n3) DEVELOPER (READ/WRITE + CREATE, ALTER, DROP, INDEX, REFERENCES)\n4) FULL DATABASE (ALL PRIVILEGES on selected database)\nChoose [1-4]: '
  IFS= read -r level || return 0
  case "$level" in
    1) privileges='SELECT' ;;
    2) privileges='SELECT, INSERT, UPDATE, DELETE' ;;
    3) privileges='SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES' ;;
    4) privileges='ALL PRIVILEGES' ;;
    *) printf '[WARNING] Invalid privilege level.\n'; return 1 ;;
  esac
  printf '[WARNING] Granting %s on %s.* to %s@%s.\n' "$privileges" "$database" "$name" "$host"
  printf '[INFO] This adds privileges; it does not revoke any existing privileges.\n'
  printf 'Type YES to grant: '
  IFS= read -r answer || return 0
  [[ "$answer" == YES ]] || { printf '[INFO] Cancelled.\n'; return 0; }
  if printf "GRANT %s ON \`%s\`.* TO '%s'@'%s';\n" "$privileges" "$database" "$name" "$host" | db_exec_stdin; then
    printf '[SUCCESS] Granted %s on %s.* to %s@%s.\n' "$privileges" "$database" "$name" "$host"
  else
    printf '[ERROR] GRANT failed. The connected account may lack GRANT OPTION for this database.\n'
    return 1
  fi
}
db_validate_target_account() {
  local name="$1" host="$2"
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ || ! "$host" =~ ^[A-Za-z0-9_.:%_-]+$ || ${#host} -gt 255 ]]; then
    printf '[ERROR] Invalid database username or host.\n'
    return 1
  fi
  if ! db_account_exists "$name" "$host"; then
    printf '[ERROR] Account not found or cannot verify existence.\n'
    return 1
  fi
}
db_show_scoped_privileges() {
  local name="$1" host="$2" result
  if db_query 'SELECT User, Host FROM mysql.db LIMIT 0;' >/dev/null 2>&1; then
    result=$(db_query "SELECT Db AS database_name, Select_priv AS select_priv, Insert_priv AS insert_priv, Update_priv AS update_priv, Delete_priv AS delete_priv, Create_priv AS create_priv, Alter_priv AS alter_priv, Drop_priv AS drop_priv, Index_priv AS index_priv, References_priv AS references_priv, Grant_priv AS grant_priv FROM mysql.db WHERE User='$name' AND Host='$host' ORDER BY Db;") || return 1
    printf '[INFO] Database-level grants from mysql.db.\n'
  elif db_query 'SELECT username, allowed_host FROM admin_tools.database_privileges LIMIT 0;' >/dev/null 2>&1; then
    result=$(db_query "SELECT database_name, select_priv, insert_priv, update_priv, delete_priv, create_priv, alter_priv, drop_priv, index_priv, references_priv, grant_priv FROM admin_tools.database_privileges WHERE username='$name' AND allowed_host='$host' ORDER BY database_name;") || return 1
    printf '[INFO] Database-level grants from admin_tools.database_privileges.\n'
  else
    printf '[ERROR] Cannot inspect database-level privileges: no access to mysql.db or admin_tools.database_privileges.\n'
    return 1
  fi
  printf '%s\n' "$result"
  if [[ "$(printf '%s\n' "$result" | wc -l)" -le 1 ]]; then
    printf '[INFO] No database-level grants found. Global, table-level and role grants are not shown.\n'
  fi
}
db_show_user_grants() {
  local name host
  printf 'Database username: '
  IFS= read -r name || return 0
  printf 'Account host [localhost]: '
  IFS= read -r host || return 0
  host="${host:-localhost}"
  db_validate_target_account "$name" "$host" || return 1
  printf '[INFO] Database-level privileges for %s@%s (Y=yes, N=no):\n' "$name" "$host"
  db_show_scoped_privileges "$name" "$host"
  printf '[INFO] This view excludes global, table-level, column-level and role privileges.\n'
}
db_revoke_privileges() {
  local name host database level privileges answer exists current
  printf 'Database username: '
  IFS= read -r name || return 0
  printf 'Account host [localhost]: '
  IFS= read -r host || return 0
  host="${host:-localhost}"
  db_validate_target_account "$name" "$host" || return 1
  printf 'Target database: '
  IFS= read -r database || return 0
  if [[ ! "$database" =~ ^[A-Za-z0-9_]+$ ]]; then
    printf '[ERROR] Invalid database name.\n'
    return 1
  fi
  case "$database" in
    mysql|information_schema|performance_schema|sys|admin_tools)
      printf '[ERROR] System and administration databases are protected.\n'
      return 1 ;;
  esac
  exists=$(db_query "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$database';") || return 1
  if [[ "$(printf '%s\n' "$exists" | tail -n 1)" != 1 ]]; then
    printf '[ERROR] Database not found or not visible to this account.\n'
    return 1
  fi
  current=$(db_query 'SELECT CURRENT_USER();' | tail -n 1) || return 1
  if [[ "$current" == "$name@$host" ]]; then
    printf '[ERROR] Refusing to revoke privileges from the currently connected account.\n'
    return 1
  fi
  printf '[INFO] Current database-level privileges for %s@%s:\n' "$name" "$host"
  db_show_scoped_privileges "$name" "$host" || return 1
  printf '\n1) Revoke READ ONLY privilege (SELECT)\n2) Revoke READ/WRITE privileges\n3) Revoke DEVELOPER privileges\n4) Revoke ALL privileges on selected database\nChoose [1-4]: '
  IFS= read -r level || return 0
  case "$level" in
    1) privileges='SELECT' ;;
    2) privileges='SELECT, INSERT, UPDATE, DELETE' ;;
    3) privileges='SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES' ;;
    4) privileges='ALL PRIVILEGES' ;;
    *) printf '[WARNING] Invalid privilege level.\n'; return 1 ;;
  esac
  printf '[WARNING] REVOKE %s ON %s.* FROM %s@%s\n' "$privileges" "$database" "$name" "$host"
  printf '[WARNING] This may interrupt running applications. It does not delete data or the account.\n'
  printf 'Type REVOKE to confirm: '
  IFS= read -r answer || return 0
  [[ "$answer" == REVOKE ]] || { printf '[INFO] Cancelled.\n'; return 0; }
  if printf "REVOKE %s ON \`%s\`.* FROM '%s'@'%s';\n" "$privileges" "$database" "$name" "$host" | db_exec_stdin; then
    printf '[SUCCESS] Revocation completed. Database-level privileges now:\n'
    db_show_scoped_privileges "$name" "$host" || printf '[WARNING] Could not refresh privilege view.\n'
  else
    printf '[ERROR] REVOKE failed; check GRANT OPTION and existing privileges. No success reported.\n'
    return 1
  fi
}
DB_CONNECTED=0
DB_ENGINE=''
DB_VERSION=''

db_show_connected_grants() {
  printf '[INFO] Authenticated account and grants:\n'
  db_run db_query 'SELECT USER() AS login_user, CURRENT_USER() AS authenticated_user; SHOW GRANTS FOR CURRENT_USER();' || printf '[WARNING] Unable to show grants.\n'
}
db_connect() {
  local result version action
  while true; do
    if result=$(db_run db_test); then break; fi
    DB_CONNECTED=0; DB_ENGINE=''; DB_VERSION=''
    printf '[ERROR] Connection failed; db.inc was not modified.\n'
    printf '1) Retry\n2) Configure connection\n0) Cancel\nChoose [0-2]: '
    IFS= read -r action || return 1
    case "$action" in
      1) continue ;;
      2) db_configure_connection; return $? ;;
      *) return 1 ;;
    esac
  done
  version=$(printf '%s\n' "$result" | tail -n 1 | cut -f1)
  DB_VERSION="$version"
  if [[ "$version" == *MariaDB* ]]; then DB_ENGINE=MariaDB
  elif [[ "$version" =~ ^[0-9]+\.[0-9]+ ]]; then DB_ENGINE=MySQL
  else DB_ENGINE=Unknown; fi
  DB_CONNECTED=1
  printf '[SUCCESS] Connected: %s %s\n' "$DB_ENGINE" "$DB_VERSION"
  printf '[INFO] Connection is validated per query; no persistent TCP session.\n'
  db_show_connected_grants
}
db_configure_connection() {
  local host port username password confirm answer opts candidate backup oldmask mode owner escaped
  printf '[INFO] Existing db.inc remains unchanged until test and SAVE.\n'
  printf 'Hostname [127.0.0.1]: '; IFS= read -r host || return 0
  host="${host:-127.0.0.1}"
  printf 'Port [3306]: '; IFS= read -r port || return 0
  port="${port:-3306}"
  printf 'Username: '; IFS= read -r username || return 0
  printf 'Password (hidden): '; IFS= read -r -s password || return 0; printf '\n'
  printf 'Confirm password (hidden): '; IFS= read -r -s confirm || return 0; printf '\n'
  if [[ -z "$username" || "$password" != "$confirm" || ! "$port" =~ ^[0-9]{1,5}$ ]]; then
    printf '[ERROR] Invalid credentials or password mismatch.\n'; return 1
  fi
  unset confirm
  (( 10#$port >= 1 && 10#$port <= 65535 )) || { printf '[ERROR] Invalid port.\n'; return 1; }
  [[ "$username" =~ ^[A-Za-z0-9_-]+$ && "$host" =~ ^[A-Za-z0-9_.:-]+$ ]] || { printf '[ERROR] Invalid username or host.\n'; return 1; }
  [[ "$password" != *$'\n'* && "$password" != *$'\r'* ]] || return 1
  if command -v mariadb >/dev/null 2>&1; then DB_CLIENT=mariadb
  elif command -v mysql >/dev/null 2>&1; then DB_CLIENT=mysql
  else printf '[ERROR] mariadb/mysql client not found.\n'; return 1; fi
  [[ ! -L "$DB_CONFIG" ]] || { printf '[ERROR] Refusing symlink db.inc.\n'; return 1; }
  if [[ -e "$DB_CONFIG" ]]; then
    [[ -f "$DB_CONFIG" ]] || return 1
    mode=$(stat -c %a -- "$DB_CONFIG") || return 1
    owner=$(stat -c %u -- "$DB_CONFIG") || return 1
    (( (8#$mode & 8#077) == 0 )) || { printf '[ERROR] db.inc has unsafe permissions.\n'; return 1; }
    [[ "$owner" == 0 || "$owner" == "${SUDO_UID:-$EUID}" ]] || { printf '[ERROR] Unsafe db.inc owner.\n'; return 1; }
  fi
  oldmask=$(umask); umask 077
  opts=$(mktemp) || { umask "$oldmask"; return 1; }
  if ! candidate=$(mktemp "$PROJECT_DIR/.db.inc.new.XXXXXXXX"); then
    umask "$oldmask"; rm -f -- "$opts"; return 1
  fi
  umask "$oldmask"
  escaped="${password//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '[client]\nuser="%s"\npassword="%s"\nhost="%s"\nport=%s\nprotocol=tcp\n' "$username" "$escaped" "$host" "$port" > "$opts"
  if ! "$DB_CLIENT" --defaults-extra-file="$opts" --batch --execute='SELECT 1;' >/dev/null 2>&1; then
    rm -f -- "$opts" "$candidate"
    printf '[ERROR] Connection test failed. db.inc unchanged.\n'
    return 1
  fi
  rm -f -- "$opts"
  printf '[SUCCESS] Connection test passed.\nType SAVE to update db.inc: '
  IFS= read -r answer || { rm -f -- "$candidate"; return 0; }
  if [[ "$answer" != SAVE ]]; then rm -f -- "$candidate"; printf '[INFO] Cancelled.\n'; return 0; fi
  printf 'username=%s\npassword=%s\nhostname=%s\nport=%s\n' "$username" "$password" "$host" "$port" > "$candidate"
  unset password escaped
  chmod 600 "$candidate"
  if [[ -f "$DB_CONFIG" ]]; then
    backup=$(mktemp "$PROJECT_DIR/.db.inc.backup.XXXXXXXX") || { rm -f -- "$candidate"; return 1; }
    if ! cp -p -- "$DB_CONFIG" "$backup"; then rm -f -- "$candidate" "$backup"; return 1; fi
    chmod 600 "$backup"
    printf '[INFO] Private credential backup: %s\n' "$backup"
  fi
  if ! mv -- "$candidate" "$DB_CONFIG"; then
    rm -f -- "$candidate"; printf '[ERROR] Unable to save db.inc.\n'; return 1
  fi
  DB_CONNECTED=0
  printf '[SUCCESS] db.inc updated. Reconnecting...\n'
  db_connect
}
db_enable_remote_user() {
  local name host database level privileges password confirm answer exists status
  printf '[INFO] Creates a separate MariaDB account for an explicitly allowed remote IPv4 address.\n'
  printf '[WARNING] Does not change bind-address, firewall, or server networking.\n'
  printf 'Existing local username: '; IFS= read -r name || return 0
  printf 'Existing account host [localhost]: '; local source_host; IFS= read -r source_host || return 0
  source_host="${source_host:-localhost}"
  db_validate_target_account "$name" "$source_host" || return 1
  printf 'Allowed remote IPv4 (single IP, no wildcard): '; IFS= read -r host || return 0
  if [[ ! "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '[ERROR] Specify one IPv4 address, not a wildcard or subnet.\n'; return 1
  fi
  local octet; local -a octets
  IFS='.' read -r -a octets <<< "$host"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  [[ "$host" != 0.* && "$host" != 127.* && "$host" != 255.* ]] || { printf '[ERROR] Invalid remote address.\n'; return 1; }
  if db_account_exists "$name" "$host"; then
    printf '[ERROR] Remote account already exists. No changes made.\n'; return 1
  else
    status=$?
    (( status == 1 )) || { printf '[ERROR] Cannot verify remote account availability.\n'; return 1; }
  fi
  printf 'Database to allow: '; IFS= read -r database || return 0
  [[ "$database" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  case "$database" in mysql|information_schema|performance_schema|sys|admin_tools) printf '[ERROR] Protected database.\n'; return 1 ;; esac
  exists=$(db_query "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$database';") || return 1
  [[ "$(printf '%s\n' "$exists" | tail -n 1)" == 1 ]] || { printf '[ERROR] Database not found or not visible.\n'; return 1; }
  printf '1) SELECT only\n2) SELECT, INSERT, UPDATE, DELETE\nChoose [1-2]: '
  IFS= read -r level || return 0
  case "$level" in 1) privileges='SELECT' ;; 2) privileges='SELECT, INSERT, UPDATE, DELETE' ;; *) return 1 ;; esac
  printf 'New remote account password (hidden): '; IFS= read -r -s password || return 0; printf '\n'
  printf 'Confirm password (hidden): '; IFS= read -r -s confirm || return 0; printf '\n'
  [[ -n "$password" && "$password" == "$confirm" ]] || { printf '[ERROR] Password mismatch or empty.\n'; return 1; }
  unset confirm
  printf '[WARNING] Create %s@%s and grant %s on %s.* only.\n' "$name" "$host" "$privileges" "$database"
  printf 'Type ENABLE to confirm: '; IFS= read -r answer || return 0
  [[ "$answer" == ENABLE ]] || { printf '[INFO] Cancelled.\n'; return 0; }
  local sql_password
  sql_password="${password//\'/\'\'}"
  unset password
  if ! printf "SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';\nCREATE USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$name" "$host" "$sql_password" | db_exec_stdin; then
    unset sql_password
    printf '[ERROR] CREATE USER failed. No privileges granted.\n'; return 1
  fi
  unset sql_password
  if ! printf "GRANT %s ON \`%s\`.* TO '%s'@'%s';\n" "$privileges" "$database" "$name" "$host" | db_exec_stdin; then
    printf '[ERROR] User created, but GRANT failed. Account remains without database privileges; review it manually.\n'; return 1
  fi
  printf '[SUCCESS] Remote account created and database permissions granted.\n'
  printf '[INFO] Verify bind-address, UFW allowlist, network route, and TLS separately before testing remote access.\n'
}
db_disconnect() {
  DB_CONNECTED=0
  DB_ENGINE=''
  DB_VERSION=''
  printf '[INFO] Disconnected from database menu session.\n'
}
db_action() {
  if (( DB_CONNECTED != 1 )); then
    printf '[WARNING] Please select 1) Connect Database first.\n'
    return 0
  fi
  if ! db_run "$@"; then
    printf '[ERROR] Database query failed; check connection and permissions.\n'
    return 1
  fi
}
main() {
  [[ -t 0 && -t 1 ]] || { printf '[ERROR] Interactive terminal required.\n' >&2; exit 1; }
  local choice
  while true; do
    printf '\n=== Manage Database (MariaDB/MySQL TCP) ===\n'
    if (( DB_CONNECTED )); then
      printf 'Connection: CONNECTED (%s %s; verified at login)\n' "$DB_ENGINE" "$DB_VERSION"
    else
      printf 'Connection: DISCONNECTED\n'
    fi
    printf '1) Connect Database\n2) Disconnect Database\n3) Server Information\n4) List Databases\n5) List Tables\n6) Database Sizes\n7) Active Connections\n8) Create Database User\n9) List Database Users\n10) Delete Database User\n11) Show My Database Grants\n12) Grant Database Privileges\n13) Show Database User Privileges\n14) Revoke Database Privileges\n15) Configure Database Connection\n16) Enable Remote Access for User\n0) Back\nChoose [0-16]: '
    IFS= read -r choice || break
    case "$choice" in
      1) db_connect || true; db_pause ;;
      2) db_disconnect; db_pause ;;
      3) db_action db_info || true; db_pause ;;
      4) db_action db_list || true; db_pause ;;
      5) db_action db_tables || true; db_pause ;;
      6) db_action db_sizes || true; db_pause ;;
      7) db_action db_connections || true; db_pause ;;
      8) db_action db_create_user || true; db_pause ;;
      9) db_action db_list_users || true; db_pause ;;
      10) db_action db_delete_user || true; db_pause ;;
      11) db_action db_show_grants || true; db_pause ;;
      12) db_action db_grant_privileges || true; db_pause ;;
      13) db_action db_show_user_grants || true; db_pause ;;
      14) db_action db_revoke_privileges || true; db_pause ;;
      15) db_configure_connection || true; db_pause ;;
      16) db_action db_enable_remote_user || true; db_pause ;;
      0) break ;;
      *) printf '[WARNING] Invalid selection.\n' ;;
    esac
  done
}
main "$@"

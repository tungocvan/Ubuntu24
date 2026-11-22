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
db_list_users() {
  printf '[INFO] Listing accounts through admin_tools.database_users.\n'
  if ! db_query 'SELECT username, allowed_host FROM admin_tools.database_users ORDER BY username,allowed_host;'; then
    printf '[ERROR] Cannot read admin_tools.database_users.\n'
    printf '[INFO] Ask an administrator to create the restricted view and grant SELECT on it.\n'
    return 1
  fi
}
db_account_exists() {
  local name="$1" host="$2" result
  # Use the restricted account directory view; fail closed when unavailable.
  result=$(db_query "SELECT COUNT(*) FROM admin_tools.database_users WHERE username='$name' AND allowed_host='$host';") || {
    printf '[ERROR] Cannot verify account existence (admin_tools.database_users access required).\n' >&2
    return 2
  }
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
  if [[ ! "$host" =~ ^[A-Za-z0-9_.:-]+$ || ${#host} -gt 255 ]]; then
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
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ || ! "$host" =~ ^[A-Za-z0-9_.:-]+$ || ${#host} -gt 255 ]]; then
    printf '[ERROR] Invalid database username or host.\n'
    return 1
  fi
  if ! db_account_exists "$name" "$host"; then
    printf '[ERROR] Account not found or cannot verify existence.\n'
    return 1
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
  printf '[INFO] Grants for %s@%s:\n' "$name" "$host"
  if ! db_query "SHOW GRANTS FOR '$name'@'$host';"; then
    printf '[ERROR] MariaDB denied SHOW GRANTS for another account.\n'
    printf '[INFO] Run as an administrator: sudo mariadb -e "SHOW GRANTS FOR '\''%s'\''@'\''%s'\'';"\n' "$name" "$host"
    return 1
  fi
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
  printf '[INFO] Current grants for %s@%s:\n' "$name" "$host"
  db_query "SHOW GRANTS FOR '$name'@'$host';" || return 1
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
  if printf "REVOKE %s ON `%s`.* FROM '%s'@'%s';\n" "$privileges" "$database" "$name" "$host" | db_exec_stdin; then
    printf '[SUCCESS] Revocation completed. Verify remaining grants below:\n'
    if ! db_query "SHOW GRANTS FOR '$name'@'$host';"; then
      printf '[WARNING] Revocation succeeded, but this account cannot display target grants.\n'
      printf '[INFO] Verify with sudo mariadb -e "SHOW GRANTS FOR '\''%s'\''@'\''%s'\'';"\n' "$name" "$host"
    fi
  else
    printf '[ERROR] REVOKE failed; check GRANT OPTION and existing privileges. No success reported.\n'
    return 1
  fi
}
DB_CONNECTED=0
DB_ENGINE=''
DB_VERSION=''
db_connect() {
  local result version
  if ! result=$(db_run db_test); then
    DB_CONNECTED=0
    DB_ENGINE=''
    DB_VERSION=''
    printf '[ERROR] Connection failed; check db.inc, credentials, service and port.\n'
    return 1
  fi
  version=$(printf '%s\n' "$result" | tail -n 1 | cut -f1)
  DB_VERSION="$version"
  if [[ "$version" == *MariaDB* ]]; then
    DB_ENGINE=MariaDB
  elif [[ "$version" =~ ^[0-9]+\.[0-9]+ ]]; then
    DB_ENGINE=MySQL
  else
    DB_ENGINE=Unknown
  fi
  DB_CONNECTED=1
  printf '[SUCCESS] Connected: %s %s\n' "$DB_ENGINE" "$DB_VERSION"
  printf '[INFO] Connection is validated per query; no persistent TCP session.\n'
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
    printf '1) Connect Database\n2) Disconnect Database\n3) Server Information\n4) List Databases\n5) List Tables\n6) Database Sizes\n7) Active Connections\n8) Create Database User\n9) List Database Users\n10) Delete Database User\n11) Show My Database Grants\n12) Grant Database Privileges\n13) Show Database User Grants\n14) Revoke Database Privileges\n0) Back\nChoose [0-14]: '
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
      0) break ;;
      *) printf '[WARNING] Invalid selection.\n' ;;
    esac
  done
}
main "$@"

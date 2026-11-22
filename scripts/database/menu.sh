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
db_create_user() {
  local name host password confirm_password answer sql_name sql_host sql_password
  printf 'New database username: '
  IFS= read -r name || return 0
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]]; then
    printf '[ERROR] Username must contain 1-32 letters, digits, _ or -, starting with a letter or _.\n'
    return 1
  fi
  printf 'Allowed client host [localhost]: '
  IFS= read -r host || return 0
  host="${host:-localhost}"
  if [[ ! "$host" =~ ^[A-Za-z0-9_.:-]+$ || "${#host}" -gt 255 ]]; then
    printf '[ERROR] Invalid host. Wildcard hosts are not supported in this menu.\n'
    return 1
  fi
  printf 'New password: '
  IFS= read -r -s password || return 0
  printf '\nConfirm password: '
  IFS= read -r -s confirm_password || return 0
  printf '\n'
  if [[ -z "$password" || "$password" != "$confirm_password" || "$password" == *
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
    printf '1) Connect Database\n2) Disconnect Database\n3) Server Information\n4) List Databases\n5) List Tables\n6) Database Sizes\n7) Active Connections\n8) Create Database User\n0) Back\nChoose [0-8]: '
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
      0) break ;;
      *) printf '[WARNING] Invalid selection.\n' ;;
    esac
  done
}
main "$@"
\r'* ]]; then
    printf '[ERROR] Password is empty, mismatched, or contains unsupported characters.\n'
    return 1
  fi
  unset confirm_password
  printf 'Create database account %s@%s with no database privileges? Type YES: ' "$name" "$host"
  IFS= read -r answer || return 0
  if [[ "$answer" != YES ]]; then
    printf '[INFO] Cancelled.\n'
    return 0
  fi
  # Escape SQL string literals, using the standard backslash escape mode.
  sql_name="${name//\\/\\\\}"; sql_name="${sql_name//\'/\\\'}"
  sql_host="${host//\\/\\\\}"; sql_host="${sql_host//\'/\\\'}"
  sql_password="${password//\\/\\\\}"; sql_password="${sql_password//\'/\\\'}"
  unset password
  # Never pass the password as a CLI argument or print SQL containing it.
  if printf "SET SESSION sql_mode=REPLACE(@@SESSION.sql_mode,'NO_BACKSLASH_ESCAPES','');\nCREATE USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$sql_name" "$sql_host" "$sql_password" | db_exec_stdin; then
    printf '[SUCCESS] Created database user: %s@%s (no privileges granted).\n' "$name" "$host"
  else
    printf '[ERROR] Could not create user. Account may exist, or current DB user lacks CREATE USER privilege.\n'
    return 1
  fi
  unset sql_password
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
    printf '1) Connect Database\n2) Disconnect Database\n3) Server Information\n4) List Databases\n5) List Tables\n6) Database Sizes\n7) Active Connections\n0) Back\nChoose [0-7]: '
    IFS= read -r choice || break
    case "$choice" in
      1) db_connect || true; db_pause ;;
      2) db_disconnect; db_pause ;;
      3) db_action db_info || true; db_pause ;;
      4) db_action db_list || true; db_pause ;;
      5) db_action db_tables || true; db_pause ;;
      6) db_action db_sizes || true; db_pause ;;
      7) db_action db_connections || true; db_pause ;;
      0) break ;;
      *) printf '[WARNING] Invalid selection.\n' ;;
    esac
  done
}
main "$@"

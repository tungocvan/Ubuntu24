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
main() {
  [[ -t 0 && -t 1 ]] || { printf '[ERROR] Interactive terminal required.\n' >&2; exit 1; }
  local choice
  while true; do
    printf '\n=== Manage Database (MariaDB/MySQL TCP) ===\n'
    printf '1) Test Connection\n2) Server Information\n3) List Databases\n4) List Tables\n5) Database Sizes\n6) Active Connections\n0) Back\nChoose [0-6]: '
    IFS= read -r choice || break
    case "$choice" in
      1) db_run db_test || printf '[ERROR] Connection failed.\n'; db_pause ;;
      2) db_run db_info || printf '[ERROR] Query failed.\n'; db_pause ;;
      3) db_run db_list || printf '[ERROR] Query failed.\n'; db_pause ;;
      4) db_run db_tables || printf '[ERROR] Query failed.\n'; db_pause ;;
      5) db_run db_sizes || printf '[ERROR] Query failed.\n'; db_pause ;;
      6) db_run db_connections || printf '[ERROR] Query failed or insufficient privileges.\n'; db_pause ;;
      0) break ;;
      *) printf '[WARNING] Invalid selection.\n' ;;
    esac
  done
}
main "$@"

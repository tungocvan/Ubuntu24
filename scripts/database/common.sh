#!/usr/bin/env bash
# Source from scripts/database/menu.sh only.
DB_CONFIG="$PROJECT_DIR/db.inc"
DB_TEMP=""
db_cleanup() { if [[ -n "$DB_TEMP" && -f "$DB_TEMP" ]]; then rm -f -- "$DB_TEMP"; fi; }
db_init() {
  local key value username='' password='' hostname='' port='' mode owner
  [[ -f "$DB_CONFIG" && ! -L "$DB_CONFIG" ]] || { printf '[ERROR] Missing db.inc: %s\n' "$DB_CONFIG" >&2; return 1; }
  mode=$(stat -c %a -- "$DB_CONFIG")
  owner=$(stat -c %u -- "$DB_CONFIG")
  if (( (8#$mode & 8#077) != 0 )); then
    printf '[ERROR] db.inc must not be accessible to group/others (chmod 600).\n' >&2; return 1
  fi
  if [[ "$owner" != 0 && "$owner" != "${SUDO_UID:-$EUID}" ]]; then
    printf '[ERROR] db.inc owner must be root or invoking user.\n' >&2; return 1
  fi
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    value="${value%$'\r'}"
    case "$key" in
      username) username="$value" ;;
      password) password="$value" ;;
      hostname) hostname="$value" ;;
      port) port="$value" ;;
      ''|'#'*) ;;
      *) printf '[ERROR] Unsupported db.inc key: %s\n' "$key" >&2; return 1 ;;
    esac
  done < "$DB_CONFIG"
  [[ -n "$username" && -n "$hostname" && "$port" =~ ^[0-9]+$ ]] || { printf '[ERROR] Invalid db.inc settings.\n' >&2; return 1; }
  ((10#$port >= 1 && 10#$port <= 65535)) || return 1
  [[ "$username" != *$'\n'* && "$password" != *$'\n'* && "$hostname" != *$'\n'* ]] || return 1
  [[ "$username" != *$'\r'* && "$password" != *$'\r'* && "$hostname" != *$'\r'* ]] || return 1
  command -v mariadb >/dev/null || { printf '[ERROR] mariadb client not installed.\n' >&2; return 1; }
  DB_TEMP=$(mktemp)
  chmod 600 "$DB_TEMP"
  # Escape characters that have meaning in MariaDB option files.
  local escaped
  escaped="${password//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '[client]\nuser="%s"\npassword="%s"\nhost="%s"\nport=%s\nprotocol=tcp\n' "$username" "$escaped" "$hostname" "$port" > "$DB_TEMP"
}
db_query() { mariadb --defaults-extra-file="$DB_TEMP" --batch --raw --execute="$1"; }
db_run() {
  DB_TEMP=""
  trap db_cleanup RETURN
  db_init || { db_cleanup; trap - RETURN; return 1; }
  "$@"
  local status=$?
  db_cleanup
  trap - RETURN
  return "$status"
}

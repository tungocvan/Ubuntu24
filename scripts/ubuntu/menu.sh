#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root'; exit 1; }
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
log(){ printf '[%s] %s\n' "$1" "$2"; }
pause(){ printf '\nPress Enter to continue...'; read -r _ || true; }
source "$dir/users.sh"
source "$dir/sessions.sh"
while true; do
 printf '\n=== Manage Ubuntu ===\nCurrent User: %s\nLogin User: %s\nHostname: %s\n' "$(id -un)" "$(login_user)" "$(hostname)"
 printf '1) List Users\n2) List Groups\n3) Change Password\n4) Create User\n5) Delete User\n6) Create Group\n7) Manage User Sessions\n8) Manage Directory Permissions\n0) Back\nChoose [0-8]: '
 read -r choice || exit 0
 case "$choice" in
  1) list_users_menu ;;
  2) list_groups_menu ;;
  3) change_password; pause ;;
  4) create_user; pause ;;
  5) delete_user; pause ;;
  6) create_group; pause ;;
  7) session_menu ;;
  8) bash "$dir/permissions.sh" || { log ERROR 'Permission menu failed'; pause; } ;;
  0) exit 0 ;;
  *) log WARNING 'Invalid selection' ;;
 esac
done

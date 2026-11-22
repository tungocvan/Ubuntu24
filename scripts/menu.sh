#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
trap 'log ERROR "Command failed at line $LINENO" >&2' ERR

usage() {
  cat <<'HELP'
Usage: sudo bash scripts/menu.sh [--help]
Manage Ubuntu users/groups, native databases and WireGuard VPN.
HELP
}
check_environment() {
  [[ -r /etc/os-release ]] || die 'Cannot detect OS'
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die 'Ubuntu required'
  case "${VERSION_ID:-}" in 24.04|26.04) ;; *) log WARNING "Ubuntu version not validated" ;; esac
  [[ $EUID -eq 0 ]] || die 'Run with sudo/root'
  [[ -t 0 && -t 1 ]] || die 'Interactive terminal required'
  local cmd
  for cmd in getent awk id passwd useradd userdel groupadd usermod; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd"
  done
}
pause() { printf '\nPress Enter to continue...'; IFS= read -r _ || true; }
valid_name() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*\$?$ && ${#1} -le 32 ]]; }
ask_name() {
  local input
  printf '%s: ' "$1" >&2
  IFS= read -r input || return 1
  valid_name "$input" || { log ERROR 'Invalid name' >&2; return 1; }
  printf '%s' "$input"
}
confirm() {
  local answer
  printf 'Type YES to confirm: '
  IFS= read -r answer || return 1
  [[ "$answer" == YES ]]
}
regular_uid_min() {
  local value
  value=$(awk '$1 == "UID_MIN" {print $2; exit}' /etc/login.defs)
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '1000'
}
regular_gid_min() {
  local value
  value=$(awk '$1 == "GID_MIN" {print $2; exit}' /etc/login.defs)
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '1000'
}
list_users_menu() {
  local choice
  while true; do
    printf '\n--- List Users ---\n1) Regular Users\n2) All Users\n0) Back\nChoose: '
    IFS= read -r choice || return
    case "$choice" in
      1) list_users regular; pause ;;
      2) list_users all; pause ;;
      0) return ;;
      *) log WARNING 'Invalid selection' ;;
    esac
  done
}
list_groups_menu() {
  local choice
  while true; do
    printf '\n--- List Groups ---\n1) Regular Groups\n2) All Groups\n0) Back\nChoose: '
    IFS= read -r choice || return
    case "$choice" in
      1) list_groups regular; pause ;;
      2) list_groups all; pause ;;
      0) return ;;
      *) log WARNING 'Invalid selection' ;;
    esac
  done
}
list_users() {
  printf '\n%-25s %-8s %-8s %-30s %s\n' USER UID GID HOME SHELL
  local min=0
  [[ "${1:-all}" == regular ]] && min=$(regular_uid_min)
  getent passwd | awk -F: -v min="$min" '($3 >= min && $1 != "nobody") {printf "%-25s %-8s %-8s %-30s %s\n",$1,$3,$4,$6,$7}'
}
list_groups() {
  printf '\n%-25s %-8s %s\n' GROUP GID MEMBERS
  local min=0
  [[ "${1:-all}" == regular ]] && min=$(regular_gid_min)
  getent group | awk -F: -v min="$min" '($3 >= min && $1 != "nogroup") {printf "%-25s %-8s %s\n",$1,$3,$4}'
  log INFO 'MEMBERS excludes users whose primary group is this group.'
}
change_password() {
  local username
  username=$(ask_name 'Existing username (root allowed)') || return 0
  getent passwd "$username" >/dev/null || { log ERROR 'User not found'; return 0; }
  log WARNING "Changing password for $username"
  confirm || { log INFO 'Cancelled'; return 0; }
  if passwd -- "$username"; then log SUCCESS 'Password updated'; else log ERROR 'Password change failed'; fi
}
delete_user() {
  local username uid home shell confirm_name
  username=$(ask_name 'Username to delete') || return 0
  if ! getent passwd "$username" >/dev/null; then log ERROR 'User not found'; return 0; fi
  uid=$(id -u "$username")
  if [[ "$username" == root || "$uid" -eq 0 || "$uid" -lt "$(regular_uid_min)" ]]; then
    log ERROR 'Refusing to delete root or a system account'; return 0
  fi
  if [[ "${SUDO_USER:-}" == "$username" || "${USER:-}" == "$username" ]]; then
    log ERROR 'Refusing to delete the current administrative account'; return 0
  fi
  home=$(getent passwd "$username" | awk -F: '{print $6}')
  shell=$(getent passwd "$username" | awk -F: '{print $7}')
  printf 'User: %s | UID: %s | Home: %s | Shell: %s\n' "$username" "$uid" "$home" "$shell"
  log WARNING 'userdel will remove the account, but NOT its home directory or files.'
  printf 'Re-enter the exact username to confirm deletion: '
  IFS= read -r confirm_name || return 0
  [[ "$confirm_name" == "$username" ]] || { log INFO 'Cancelled'; return 0; }
  confirm || { log INFO 'Cancelled'; return 0; }
  if userdel -- "$username"; then
    log SUCCESS "Deleted account: $username (home directory preserved)"
  else
    log ERROR 'Deletion failed; check active processes or account dependencies'
  fi
}
create_group() {
  local groupname
  groupname=$(ask_name 'New group name') || return 0
  if getent group "$groupname" >/dev/null; then log WARNING 'Group already exists'; return 0; fi
  confirm || { log INFO 'Cancelled'; return 0; }
  if groupadd -- "$groupname"; then log SUCCESS "Created group: $groupname"; else log ERROR 'Group creation failed'; fi
}
create_user() {
  local username extra answer
  username=$(ask_name 'New username') || return 0
  if getent passwd "$username" >/dev/null; then log WARNING 'User already exists'; return 0; fi
  printf 'Optional existing supplementary group (blank to skip): '
  IFS= read -r extra || return 0
  if [[ -n "$extra" ]]; then
    valid_name "$extra" || { log ERROR 'Invalid group'; return 0; }
    getent group "$extra" >/dev/null || { log ERROR 'Group not found'; return 0; }
  fi
  printf 'Create %s with home directory and /bin/bash?\n' "$username"
  confirm || { log INFO 'Cancelled'; return 0; }
  if ! useradd -m -s /bin/bash -- "$username"; then log ERROR 'User creation failed'; return 0; fi
  log SUCCESS "Created user: $username"
  if [[ -n "$extra" ]]; then
    if usermod -aG "$extra" -- "$username"; then log SUCCESS "Added to group: $extra"; else log ERROR 'Group assignment failed'; fi
  fi
  printf 'Set password now? [y/N]: '
  IFS= read -r answer || answer=''
  if [[ "$answer" == y || "$answer" == Y ]]; then
    if passwd -- "$username"; then log SUCCESS 'Password set'; else log WARNING 'Password not set'; fi
  else log WARNING 'Password not set; account may remain locked'; fi
}
manage_ubuntu() {
  local choice
  while true; do
    printf '\n=== Manage Ubuntu ===\n'
    printf '1) List Users\n2) List Groups\n3) Change Password\n4) Create User\n5) Delete User\n6) Create Group\n0) Back\nChoose [0-6]: '
    IFS= read -r choice || return
    case "$choice" in
      1) list_users_menu ;;
      2) list_groups_menu ;;
      3) change_password; pause ;;
      4) create_user; pause ;;
      5) delete_user; pause ;;
      6) create_group; pause ;;
      0) return ;;
      *) log WARNING 'Invalid selection' ;;
    esac
  done
}
manage_database() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  bash "$script_dir/database/menu.sh"
}
manage_vpn() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local choice endpoint client
  while true; do
    printf '\n=== Manage WireGuard VPN ===\n1) Status\n2) Setup Server\n3) Add Client\n0) Back\nChoose [0-3]: '
    IFS= read -r choice || return
    case "$choice" in
      1) bash "$script_dir/vpn/wireguard.sh" status; pause ;;
      2) printf 'Server public IPv4 or DNS: '; IFS= read -r endpoint || return
         bash "$script_dir/vpn/wireguard.sh" setup "$endpoint" || true; pause ;;
      3) printf 'New client name: '; IFS= read -r client || return
         bash "$script_dir/vpn/wireguard.sh" add-client "$client" || true; pause ;;
      0) return ;;
      *) log WARNING 'Invalid selection' ;;
    esac
  done
}
main() {
  if (($#)); then
    if (($# == 1)) && [[ "$1" == --help || "$1" == -h ]]; then usage; return; fi
    usage >&2; return 2
  fi
  check_environment
  local choice
  while true; do
    printf '\n=== Ubuntu24 DevOps Main Menu ===\n1) Manage Ubuntu\n2) Manage Database\n3) Manage WireGuard VPN\n0) Exit\nChoose [0-3]: '
    IFS= read -r choice || { printf '\n'; break; }
    case "$choice" in
      1) manage_ubuntu ;;
      2) manage_database ;;
      3) manage_vpn ;;
      0) break ;;
      *) log WARNING 'Invalid selection' ;;
    esac
  done
}
main "$@"

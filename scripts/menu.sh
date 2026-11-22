#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
trap 'log ERROR "Command failed at line $LINENO" >&2' ERR

usage() {
  cat <<'HELP'
Usage: sudo bash scripts/menu.sh [--help]
Manage local Ubuntu users/groups interactively. No deletion or SSH changes.
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
  for cmd in getent awk id passwd useradd groupadd usermod; do
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
list_users() {
  printf '\n%-25s %-8s %-8s %-30s %s\n' USER UID GID HOME SHELL
  getent passwd | awk -F: '{printf "%-25s %-8s %-8s %-30s %s\n",$1,$3,$4,$6,$7}'
}
list_groups() {
  printf '\n%-25s %-8s %s\n' GROUP GID MEMBERS
  getent group | awk -F: '{printf "%-25s %-8s %s\n",$1,$3,$4}'
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
main() {
  if (($#)); then
    if (($# == 1)) && [[ "$1" == --help || "$1" == -h ]]; then usage; return; fi
    usage >&2; return 2
  fi
  check_environment
  local choice
  while true; do
    printf '\n=== Ubuntu User & Group Manager ===\n'
    printf '1) List users\n2) List groups\n3) Change password (including root)\n4) Create user\n5) Create group\n0) Exit\n'
    printf 'Choose [0-5]: '
    IFS= read -r choice || { printf '\n'; break; }
    case "$choice" in
      1) list_users; pause ;;
      2) list_groups; pause ;;
      3) change_password; pause ;;
      4) create_user; pause ;;
      5) create_group; pause ;;
      0) break ;;
      *) log WARNING 'Invalid selection' ;;
    esac
  done
}
main "$@"

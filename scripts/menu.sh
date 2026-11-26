#!/usr/bin/env bash
set -Eeuo pipefail

# Re-execute under sudo for interactive administration; preserve script arguments.
if (( EUID != 0 )); then
  exec sudo -- bash "$(realpath -- "${BASH_SOURCE[0]}")" "$@"
fi

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
trap 'log ERROR "Command failed at line $LINENO" >&2' ERR

usage() {
  cat <<'HELP'
Usage: sudo bash scripts/menu.sh [--help]
Manage Ubuntu users/groups, native databases, WireGuard VPN, GitHub repositories and SSL certificates.
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
manage_ubuntu() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  if ! bash "$script_dir/ubuntu/menu.sh"; then
    log ERROR 'Ubuntu menu failed'; pause
  fi
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
    printf '\n=== Manage WireGuard VPN ===\n1) Status\n2) Setup Server\n3) Add Client\n4) Enable VPN-only MariaDB Proxy\n5) Disable VPN-only MariaDB Proxy\n0) Back\nChoose [0-5]: '
    IFS= read -r choice || return
    case "$choice" in
      1) bash "$script_dir/vpn/wireguard.sh" status; pause ;;
      2) printf 'Server public IPv4 or DNS: '; IFS= read -r endpoint || return
         bash "$script_dir/vpn/wireguard.sh" setup "$endpoint" || true; pause ;;
      3) printf 'New client name: '; IFS= read -r client || return
         bash "$script_dir/vpn/wireguard.sh" add-client "$client" || true; pause ;;
      4) bash "$script_dir/vpn/mariadb-proxy.sh" enable || true; pause ;;
      5) bash "$script_dir/vpn/mariadb-proxy.sh" disable || true; pause ;;
      0) return ;;
      *) log WARNING 'Invalid selection' ;;
    esac
  done
}
manage_github() {
  local script_dir entry
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  entry="$script_dir/../repo-duplica.sh"
  [[ -r "$entry" ]] || { log ERROR "Missing: $entry"; pause; return 0; }
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    if ! sudo -H -u "$SUDO_USER" -- bash "$entry"; then
      log ERROR 'GitHub repository menu failed'; pause
    fi
  else
    log WARNING 'Running GitHub menu as root; using root GitHub authentication.'
    if ! bash "$entry"; then
      log ERROR 'GitHub repository menu failed'; pause
    fi
  fi
}
manage_ssl() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  if ! bash "$script_dir/www/menu.sh"; then
    log ERROR 'SSL menu failed'; pause
  fi
}
main() {
  if (($#)); then
    if (($# == 1)) && [[ "$1" == --help || "$1" == -h ]]; then usage; return; fi
    usage >&2; return 2
  fi
  check_environment
  local choice
  while true; do
    printf '\n=== Ubuntu24 DevOps Main Menu ===\n1) Manage Ubuntu\n2) Manage Database\n3) Manage WireGuard VPN\n4) Manage GitHub Repository\n5) Manage SSL Certificates\n0) Exit\nChoose [0-5]: '
    IFS= read -r choice || { printf '\n'; break; }
    case "$choice" in
      1) manage_ubuntu ;;
      2) manage_database ;;
      3) manage_vpn ;;
      4) manage_github ;;
      5) manage_ssl ;;
      0) break ;;
      *) log WARNING 'Invalid selection' ;;
    esac
  done
}
main "$@"

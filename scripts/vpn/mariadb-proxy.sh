#!/usr/bin/env bash
set -Eeuo pipefail
# Opt-in VPN-only TCP proxy to an existing loopback MariaDB listener.
UNIT=/etc/systemd/system/ubuntu24-mariadb-vpn-proxy.service
WG_IF=wg-ubuntu24
VPN_IP=10.77.0.1
log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
usage() {
  printf 'Usage: sudo bash scripts/vpn/mariadb-proxy.sh <enable|status|disable>\n'
  printf 'enable: install socat and VPN-only proxy after explicit YES; disable: stop proxy, retain unit.\n'
}
confirm() { local a; printf 'Type YES to confirm: '; IFS= read -r a || return 1; [[ "$a" == YES ]]; }
check() {
  (( EUID == 0 )) || die 'Root required.'
  [[ -f /etc/os-release ]] || die 'OS detection failed.'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die 'Ubuntu required.'
}
enable_proxy() {
  [[ ! -e "$UNIT" && ! -L "$UNIT" ]] || die 'Service file already exists; refusing to overwrite.'
  command -v ss >/dev/null || die 'ss missing.'
  ip -4 addr show dev "$WG_IF" 2>/dev/null | grep -Fq "$VPN_IP/" || die 'WireGuard interface/IP not active.'
  # Require MariaDB bound specifically to localhost, not wildcard or VPN IP.
  ss -H -lnt '( sport = :3306 )' | grep -Eq '127\\.0\\.0\\.1:3306[[:space:]]' || die 'No 127.0.0.1:3306 listener; inspect ss -lntp.'
  if ss -H -lnt '( sport = :3306 )' | grep -Eq '(0\\.0\\.0\\.0|10\\.77\\.0\\.1|\\[::\\]|\\*):3306'; then
    die '3306 already exposed on wildcard/VPN interface; refusing proxy.'
  fi
  printf '[WARNING] Install socat and enable TCP %s:3306 -> 127.0.0.1:3306.\n' "$VPN_IP"
  printf '[WARNING] MariaDB will see connections from local proxy, not the VPN client IP.\n'
  confirm || { log INFO 'Cancelled'; return 0; }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y socat
  local tmp
  tmp=$(mktemp /etc/systemd/system/.ubuntu24-mariadb-proxy.XXXXXXXX)
  cat > "$tmp" <<'UNITFILE'
[Unit]
Description=Ubuntu24 MariaDB WireGuard-only TCP proxy
After=network-online.target wg-quick@wg-ubuntu24.service mariadb.service
Wants=network-online.target
Requires=wg-quick@wg-ubuntu24.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:3306,bind=10.77.0.1,reuseaddr,fork TCP4:127.0.0.1:3306
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNITFILE
  chmod 644 "$tmp"
  mv -n -- "$tmp" "$UNIT"
  systemctl daemon-reload
  if ! systemctl enable --now ubuntu24-mariadb-vpn-proxy.service; then
    log ERROR 'Proxy start failed. Unit retained; inspect journalctl.'
    return 1
  fi
  log SUCCESS 'VPN-only MariaDB TCP proxy enabled.'
  log WARNING 'Verify UFW rules: do not expose 3306 publicly; consider sudo ufw allow in on wg-ubuntu24 to any port 3306 proto tcp.'
}
disable_proxy() {
  [[ -f "$UNIT" ]] || die 'Proxy unit not found.'
  printf '[WARNING] Disabling proxy interrupts active VPN database connections.\n'
  confirm || { log INFO 'Cancelled'; return 0; }
  systemctl disable --now ubuntu24-mariadb-vpn-proxy.service
  log SUCCESS 'Proxy stopped and disabled; unit retained.'
}
main() {
  (( $# == 1 )) || { usage; return 2; }
  case "$1" in
    -h|--help) usage ;;
    enable) check; enable_proxy ;;
    disable) check; disable_proxy ;;
    status) check; systemctl --no-pager status ubuntu24-mariadb-vpn-proxy.service || true ;;
    *) usage; return 2 ;;
  esac
}
main "$@"

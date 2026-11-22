#!/usr/bin/env bash
set -Eeuo pipefail
# WireGuard split-tunnel for MariaDB; never exposes TCP/3306 publicly.
WG_IF=wg-ubuntu24
WG_DIR=/etc/wireguard
WG_CONF="$WG_DIR/$WG_IF.conf"
CLIENT_DIR=/var/lib/ubuntu24/wireguard/clients
WG_SERVER_IP=10.77.0.1
WG_PORT=51820
log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage: sudo bash scripts/vpn/wireguard.sh <setup|add-client|status> [arguments]
  setup <public-ip-or-dns>   Install WireGuard and configure a VPN server (confirmation required)
  add-client <name>          Create one client profile, stored privately (confirmation required)
  status                     Show service and peers (no private keys)
WireGuard: UDP 51820, server 10.77.0.1/24, clients 10.77.0.2-254.
No UFW, NAT, router, MariaDB or SSH settings are changed automatically.
HELP
}
check_root() {
  (( EUID == 0 )) || die 'Run as root (sudo).'
  [[ -r /etc/os-release ]] || die 'Missing /etc/os-release'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die 'Ubuntu required'
}
confirm() {
  local a
  printf 'Type YES to continue: '
  IFS= read -r a || return 1
  [[ "$a" == YES ]]
}
valid_endpoint() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ && "$1" != *..* ]]; }
ensure_private_dirs() {
  install -d -m 700 "$WG_DIR" "$CLIENT_DIR"
}
setup() {
  local endpoint="${1:-}" private public tmp
  [[ -n "$endpoint" ]] && valid_endpoint "$endpoint" || die 'Provide public IPv4 or DNS (no URL/port).'
  [[ ! -e "$WG_CONF" && ! -L "$WG_CONF" ]] || die "Existing config at $WG_CONF. Refusing to overwrite."
  printf '[WARNING] Installs wireguard, writes %s and enables wg-quick@%s.\n' "$WG_CONF" "$WG_IF"
  printf '[INFO] UDP %s must be allowed to server and forwarded by router if behind NAT.\n' "$WG_PORT"
  confirm || { log INFO 'Cancelled'; return 0; }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard
  command -v wg >/dev/null || die 'wg missing after installation'
  ensure_private_dirs
  umask 077
  tmp=$(mktemp "$WG_DIR/.wg-ubuntu24.XXXXXXXX")
  private=$(wg genkey)
  public=$(printf '%s' "$private" | wg pubkey)
  {
    printf '[Interface]\nAddress = %s/24\nListenPort = %s\nPrivateKey = %s\nSaveConfig = false\n' "$WG_SERVER_IP" "$WG_PORT" "$private"
  } > "$tmp"
  chmod 600 "$tmp"
  if [[ -e "$WG_CONF" || -L "$WG_CONF" ]]; then
    rm -f -- "$tmp"
    die 'Configuration appeared concurrently; aborting.'
  fi
  mv -n -- "$tmp" "$WG_CONF"
  printf '%s\n' "$endpoint" > "$WG_DIR/$WG_IF.endpoint"
  chmod 600 "$WG_DIR/$WG_IF.endpoint"
  if ! systemctl enable --now "wg-quick@$WG_IF"; then
    log ERROR 'WireGuard failed to start; configuration preserved for inspection.'
    return 1
  fi
  log SUCCESS "VPN ready: $WG_SERVER_IP, UDP $WG_PORT"
  log INFO "Server public key: $public"
  log WARNING 'Firewall/router port 51820/UDP is NOT configured; see README.'
}
add_client() {
  local name="${1:-}" endpoint server_pub server_priv client_priv client_pub ip n profile tmp
  [[ "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]] || die 'Client name: 1-32 letters/numbers/_/-, starting with letter.'
  [[ -f "$WG_CONF" && ! -L "$WG_CONF" ]] || die 'Run setup first.'
  command -v wg >/dev/null || die 'WireGuard not installed.'
  ensure_private_dirs
  profile="$CLIENT_DIR/$name.conf"
  [[ ! -e "$profile" && ! -L "$profile" ]] || die 'Client profile exists; refusing overwrite.'
  endpoint=$(cat "$WG_DIR/$WG_IF.endpoint")
  valid_endpoint "$endpoint" || die 'Invalid stored endpoint.'
  server_priv=$(sed -n 's/^PrivateKey = //p' "$WG_CONF" | head -n 1)
  [[ -n "$server_priv" ]] || die 'Missing server key.'
  server_pub=$(printf '%s' "$server_priv" | wg pubkey)
  unset server_priv
  ip=''
  for ((n=2; n<=254; n++)); do
    if ! grep -Eq "AllowedIPs = 10\\.77\\.0\\.$n/32([[:space:]]|$)" "$WG_CONF"; then
      ip="10.77.0.$n"; break
    fi
  done
  [[ -n "$ip" ]] || die 'No free VPN address.'
  printf 'Create VPN client %s (%s)?\n' "$name" "$ip"
  confirm || { log INFO 'Cancelled'; return 0; }
  umask 077
  client_priv=$(wg genkey)
  client_pub=$(printf '%s' "$client_priv" | wg pubkey)
  tmp=$(mktemp "$CLIENT_DIR/.client.XXXXXXXX")
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\n\n' "$client_priv" "$ip"
    printf '[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = %s/32\nPersistentKeepalive = 25\n' "$server_pub" "$endpoint" "$WG_PORT" "$WG_SERVER_IP"
  } > "$tmp"
  chmod 600 "$tmp"
  unset client_priv
  # Persist peer before activating; keep a copy of the original server config.
  cp -p -- "$WG_CONF" "$WG_CONF.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  printf '\n[Peer]\n# client: %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$name" "$client_pub" "$ip" >> "$WG_CONF"
  mv -n -- "$tmp" "$profile"
  if ! wg set "$WG_IF" peer "$client_pub" allowed-ips "$ip/32"; then
    log WARNING 'Peer saved but not activated; run systemctl restart wg-quick@wg-ubuntu24 after checking config.'
    return 1
  fi
  log SUCCESS "Client profile: $profile (mode 600)"
  log WARNING 'Profile contains a PRIVATE KEY. Transfer securely, never commit to Git or share in chat.'
  log INFO "On client, connect to $WG_SERVER_IP and use MariaDB port 3306 after configuring a VPN-only DB listener."
}
status() {
  systemctl --no-pager --full status "wg-quick@$WG_IF" || true
  if command -v wg >/dev/null; then wg show "$WG_IF" || true; fi
  log INFO 'Database connectivity: verify MariaDB listens on VPN IP and TCP/3306 is restricted to wg-ubuntu24.'
}
main() {
  (( $# > 0 )) || { usage; return 2; }
  case "$1" in
    -h|--help) usage ;;
    setup) check_root; (( $# == 2 )) || die 'Usage: setup <public-ip-or-dns>'; setup "$2" ;;
    add-client) check_root; (( $# == 2 )) || die 'Usage: add-client <name>'; add_client "$2" ;;
    status) check_root; status ;;
    *) usage; return 2 ;;
  esac
}
main "$@"

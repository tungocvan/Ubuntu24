#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

OUTPUT_DIR="${UBUNTU24_INVENTORY_DIR:-/var/local/ubuntu24/inventory}"
usage() {
  cat <<'EOF'
Usage: sudo ./scripts/collect-os-config.sh [--output-dir ABSOLUTE_PATH] [--help]
Collect read-only Ubuntu host inventory into a NEW timestamped local snapshot.
Existing snapshots are never overwritten. Does not collect secret file contents.
EOF
}
log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --output-dir) (($# >= 2)) || die "Missing --output-dir value"; OUTPUT_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ $EUID -eq 0 ]] || die "Run with sudo/root to protect snapshots"
[[ -r /etc/os-release ]] || die "Missing /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Only Ubuntu is supported (detected: ${ID:-unknown})"
case "${VERSION_ID:-unknown}" in
  24.04|26.04) log INFO "Supported Ubuntu release: ${VERSION_ID}" ;;
  *) log WARNING "Ubuntu ${VERSION_ID:-unknown} is not explicitly tested; collecting best-effort inventory" ;;
esac
[[ "$OUTPUT_DIR" == /* && "$OUTPUT_DIR" != "/" ]] || die "Output directory must be an absolute path other than /"
[[ ! -L "$OUTPUT_DIR" ]] || die "Output directory must not be a symlink"
install -d -m 0700 -- "$OUTPUT_DIR"
chmod 0700 -- "$OUTPUT_DIR"
[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || die "Unsafe output directory"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPSHOT=""
for ((i=0; i<1000; i++)); do
  printf -v suffix '%03d' "$i"
  candidate="$OUTPUT_DIR/${STAMP}_${suffix}"
  if mkdir -m 0700 -- "$candidate" 2>/dev/null; then SNAPSHOT="$candidate"; break; fi
  [[ ! -e "$candidate" && ! -L "$candidate" ]] || continue
  die "Cannot create snapshot: $candidate"
done
[[ -n "$SNAPSHOT" ]] || die "Unable to allocate unique snapshot name"
trap 'log ERROR "Collection interrupted; partial snapshot remains at: $SNAPSHOT"' ERR
run() {
  local label="$1"; shift
  local target="$SNAPSHOT/$label.txt"
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Unavailable command: %s\n' "$1" > "$target"
    log WARNING "$1 unavailable"
    return 0
  fi
  if "$@" > "$target" 2>&1; then
    log INFO "Collected $label"
  else
    log WARNING "Command failed ($label); see $target"
  fi
}
log INFO "Collecting local inventory: $SNAPSHOT"
{
  printf 'collected_utc=%s\n' "$(date -u -Is)"
  printf 'hostname=%s\n' "$(hostname)"
  printf 'os=%s\n' "$PRETTY_NAME"
  printf 'kernel=%s\n' "$(uname -r)"
  printf 'snapshot=%s\n' "$SNAPSHOT"
} > "$SNAPSHOT/manifest.txt"
cp -- /etc/os-release "$SNAPSHOT/os-release.txt"
run kernel uname -a
run cpu lscpu
run memory free -h
run block_devices lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
run disk_usage df -hT
run mounts findmnt -r
run network_addresses ip -brief address
run network_routes ip route show table main
run network_links ip -brief link
run dns resolvectl status
run hostname hostnamectl
run time timedatectl
run uptime uptime
run services systemctl list-units --type=service --all --no-pager
run failed_services systemctl --failed --no-pager
run enabled_services systemctl list-unit-files --type=service --no-pager
run listening_ports ss -lntup
run ufw ufw status verbose
run packages dpkg-query -W -f='${binary:Package}\t${Version}\n'
run apt_sources grep -R -h -E '^[[:space:]]*(deb |URIs:|Suites:|Components:)' /etc/apt/sources.list /etc/apt/sources.list.d
run docker_version docker version
run docker_compose docker compose version
run docker_containers docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
run docker_networks docker network ls
run docker_volumes docker volume ls
run docker_info docker info --format '{{json .ServerVersion}}'
run cron_services systemctl list-timers --all --no-pager
run users getent passwd
run groups getent group
run environment_limits systemctl show --property=DefaultLimitNOFILE
chmod 0600 "$SNAPSHOT"/*.txt
log SUCCESS "Snapshot created: $SNAPSHOT"
log WARNING "May contain hostnames, usernames, network addresses and service metadata; review before sharing."

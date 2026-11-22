#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
BACKUP_DIR="${UBUNTU24_BACKUP_DIR:-/var/local/ubuntu24/backups}"
usage() { echo "Usage: sudo $0 [--output-dir ABSOLUTE_PATH] [--help]"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --output-dir) (($# >= 2)) || die "Missing path"; BACKUP_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ $EUID -eq 0 ]] || die "Requires root"
[[ "$BACKUP_DIR" == /* && "$BACKUP_DIR" != "/" && ! -L "$BACKUP_DIR" ]] || die "Unsafe output path"
install -d -m 0700 -- "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
[[ ! -L "$BACKUP_DIR" ]] || die "Output is symlink"
files=()
for path in /etc/os-release /etc/fstab /etc/hostname /etc/hosts /etc/ssh/sshd_config /etc/docker/daemon.json /etc/ufw/ufw.conf; do
  [[ -f "$path" && ! -L "$path" ]] && files+=("${path#/}")
done
(("${#files[@]}" > 0)) || die "No eligible config files"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest=""
for ((i=0; i<1000; i++)); do
  printf -v suffix '%03d' "$i"
  candidate="$BACKUP_DIR/config_${stamp}_${suffix}.tar.gz"
  if (set -o noclobber; : > "$candidate") 2>/dev/null; then dest="$candidate"; break; fi
done
[[ -n "$dest" ]] || die "Cannot allocate new backup filename"
if tar -C / -czf "$dest" -- "${files[@]}"; then
  chmod 0600 "$dest"
  printf '[SUCCESS] Config backup: %s\n' "$dest"
  printf '[INFO] Verify: sudo tar -tzf %q\n' "$dest"
else
  die "Backup failed; inspect partial archive: $dest"
fi

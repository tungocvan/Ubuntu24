#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
log() { printf '[INFO] %s\n' "$*"; }
if [[ "${1:-}" == "--help" ]]; then echo "Usage: $0 (read-only system status)"; exit 0; fi
if [[ $# -ne 0 ]]; then echo "Unknown argument; use --help" >&2; exit 2; fi
log "Timestamp: $(date -Is)"
log "OS:"
cat /etc/os-release 2>/dev/null || true
log "Kernel: $(uname -srmo)"
log "Uptime:"; uptime || true
log "Memory:"; free -h || true
log "Filesystems:"; df -hT -x tmpfs -x devtmpfs || true
log "Failed systemd units:"
if command -v systemctl >/dev/null 2>&1; then systemctl --failed --no-pager || true; else log "systemctl unavailable"; fi

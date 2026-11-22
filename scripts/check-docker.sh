#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "--help" ]]; then echo "Usage: $0 (read-only Docker checks)"; exit 0; fi
if [[ $# -ne 0 ]]; then echo "Unknown argument; use --help" >&2; exit 2; fi
if ! command -v docker >/dev/null 2>&1; then echo "[WARNING] Docker CLI not installed"; exit 0; fi
echo "[INFO] Docker version:"
docker --version
echo "[INFO] Compose V2:"
docker compose version || echo "[WARNING] Compose V2 unavailable"
echo "[INFO] Docker daemon:"
if docker info --format '{{.ServerVersion}}' 2>/dev/null; then
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
else
  echo "[WARNING] Docker daemon inaccessible; check service and permissions"
fi

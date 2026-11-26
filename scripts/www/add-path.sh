#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
usage() { printf 'Usage: %s <directory>\n' "${0##*/}"; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
[[ -d "$1" ]] || die "Directory not found: $1"
[[ -z ${SUDO_USER:-} ]] || die 'Run without sudo to update your own .bashrc.'

TARGET=$(realpath -e -- "$1")
[[ "$TARGET" != *:* && "$TARGET" != *$'\n'* && "$TARGET" != *$'\r'* ]] || die 'Unsupported characters in PATH directory.'
BASHRC="$HOME/.bashrc"
[[ ! -L "$BASHRC" ]] || die 'Refusing to modify a symbolic link.'
[[ ! -e "$BASHRC" || -f "$BASHRC" ]] || die 'Invalid .bashrc file type.'

printf -v QUOTED '%q' "$TARGET"
printf -v LINE 'case ":$PATH:" in *:%s:*) ;; *) export PATH="$PATH":%s ;; esac' "$QUOTED" "$QUOTED"

if [[ -f "$BASHRC" ]] && grep -Fxq -- "$LINE" "$BASHRC"; then
    log INFO 'Directory already configured in .bashrc.'
    exit 0
fi

if [[ -f "$BASHRC" ]]; then
    BACKUP=$(mktemp "$HOME/.bashrc.backup.XXXXXXXX")
    cp -- "$BASHRC" "$BACKUP"
    log INFO "Backup: $BACKUP"
fi
umask 077
printf '\n# Added by add-path.sh\n%s\n' "$LINE" >> "$BASHRC"
log SUCCESS "Added to PATH: $TARGET"
log INFO 'Run: source ~/.bashrc'

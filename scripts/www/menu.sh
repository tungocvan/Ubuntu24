#!/usr/bin/env bash
set -Eeuo pipefail
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ $EUID == 0 ]] || { echo '[ERROR] Run as root'; exit 1; }
pause(){ printf '\nPress Enter to continue...'; read -r _ || true; }
run(){ if ! bash "$@"; then echo '[WARNING] Operation failed; see output above.'; fi; }
while true; do
  printf '\n=== SSL Certificate Manager ===\nSSL Directory: /etc/.cert\n1) Check SSL Environment\n2) Install SSL Dependencies\n3) List SSL Certificates\n4) Create SSL Certificate\n5) Check SSL Certificate\n6) Renew SSL Certificate\n7) Delete SSL Certificate\n0) Back to Main Menu\nChoose [0-7]: '
  read -r choice || exit 0
  case "$choice" in
    1) if ! bash "$dir/ssl-env.sh" --check; then
         printf 'Install missing dependencies now? [y/N]: '; read -r answer || exit 0
         if [[ $answer == y || $answer == Y ]]; then run "$dir/ssl-env.sh" --install; fi
       fi; pause ;;
    2) run "$dir/ssl-env.sh" --install; pause ;;
    3) run "$dir/ssl-domain.sh" --list; pause ;;
    4|5|6|7)
      printf 'Root domain: '; read -r domain || exit 0
      domain=${domain,,}
      if [[ ! $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ || ${#domain} -gt 251 ]]; then echo '[ERROR] Invalid domain'; pause; continue; fi
      present=0
      for f in "/etc/.cert/$domain.pem" "/etc/.cert/$domain-cert.pem" "/etc/.cert/$domain-key.pem"; do
        if [[ -e $f || -L $f ]]; then present=1; fi
      done
      case "$choice" in
        4) if (( present )); then echo '[WARNING] SSL already exists; use Renew.'; else run "$dir/ssl-domain.sh" "$domain"; fi ;;
        5) run "$dir/ssl-domain.sh" "$domain" --check ;;
        6) if (( present )); then run "$dir/ssl-domain.sh" "$domain"; else echo '[WARNING] SSL not found; use Create.'; fi ;;
        7) run "$dir/ssl-domain.sh" "$domain" --delete ;;
      esac
      pause ;;
    0) exit 0 ;;
    *) echo '[WARNING] Invalid selection' ;;
  esac
done

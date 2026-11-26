#!/usr/bin/env bash
login_user(){ logname 2>/dev/null || printf '%s\n' "${SUDO_USER:-unknown}"; }
session_menu(){
 local choice name sid service
 while true; do
  printf '\n=== Manage User Sessions ===\n1) Show Current User\n2) List Logged-in Users\n3) List Active SSH Sessions\n4) Show User Login History\n5) Show Failed Login Attempts\n6) Show User Groups and Privileges\n0) Back\nChoose [0-6]: '
  read -r choice || return 0
  case "$choice" in
   1) printf 'Login User: %s\nEffective User: %s\nSudo User: %s\nHostname: %s\n' "$(login_user)" "$(id -un)" "${SUDO_USER:-none}" "$(hostname)"; id ;;
   2) who; w ;;
   3) if command -v loginctl >/dev/null; then
        while read -r sid; do
          service=$(loginctl show-session "$sid" -p Service --value 2>/dev/null) || continue
          if [[ $service == sshd* ]]; then loginctl show-session "$sid" -p Name -p RemoteHost -p State -p TTY || true; echo; fi
        done < <(loginctl list-sessions --no-legend | awk '{print $1}')
       fi
       echo 'SSH TCP connections (not necessarily authenticated):'; ss -tnp state established '( sport = :22 )' || true ;;
   4) if command -v last >/dev/null; then last -n 30 || true; else journalctl -u ssh.service -n 50 --no-pager || true; fi ;;
   5) if command -v lastb >/dev/null; then lastb -n 30 || true; fi
       journalctl -u ssh.service --no-pager -n 100 | grep -Ei 'failed|invalid user|authentication failure' || true ;;
   6) name=$(ask_name 'Username') || continue
       if getent passwd "$name" >/dev/null; then id "$name"; sudo -l -U "$name" || true; else log ERROR 'User not found'; fi ;;
   0) return 0 ;;
   *) log WARNING 'Invalid selection'; continue ;;
  esac
  pause
 done
}

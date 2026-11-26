#!/usr/bin/env bash
# Resolve the login identity independently of the effective UID.
login_identity(){
 local name uid terminal sid session_tty service remote
 LOGIN_NAME=unknown LOGIN_SOURCE=none LOGIN_SESSION=unknown LOGIN_TYPE=unknown
 terminal=$(tty 2>/dev/null) || terminal=''
 LOGIN_TERMINAL=${terminal:-unknown}
 if command -v loginctl >/dev/null && [[ $terminal == /dev/* ]]; then
  while read -r sid; do
   [[ -n $sid ]] || continue
   session_tty=$(loginctl show-session "$sid" -p TTY --value 2>/dev/null) || continue
   [[ $session_tty == "${terminal#/dev/}" ]] || continue
   name=$(loginctl show-session "$sid" -p Name --value 2>/dev/null) || continue
   [[ -n $name ]] && getent passwd "$name" >/dev/null || continue
   LOGIN_NAME=$name LOGIN_SOURCE=loginctl LOGIN_SESSION=$sid
   service=$(loginctl show-session "$sid" -p Service --value 2>/dev/null) || service=''
   remote=$(loginctl show-session "$sid" -p Remote --value 2>/dev/null) || remote=''
   if [[ $service == sshd* ]]; then LOGIN_TYPE=SSH
   elif [[ $remote == yes ]]; then LOGIN_TYPE=Remote
   elif [[ $remote == no ]]; then LOGIN_TYPE=Local
   fi
   return 0
  done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
 fi
 if name=$(logname 2>/dev/null) && [[ -n $name ]] && getent passwd "$name" >/dev/null; then
  LOGIN_NAME=$name LOGIN_SOURCE=logname
 elif [[ -r /proc/self/loginuid ]] && uid=$(cat /proc/self/loginuid) && [[ $uid =~ ^[0-9]+$ && $uid != 4294967295 ]] && name=$(getent passwd "$uid") && [[ -n $name ]]; then
  LOGIN_NAME=${name%%:*} LOGIN_SOURCE=audit-loginuid
 elif [[ $terminal == /dev/* ]] && name=$(who | awk -v t="${terminal#/dev/}" '$2 == t {print $1; exit}') && [[ -n $name ]] && getent passwd "$name" >/dev/null; then
  LOGIN_NAME=$name LOGIN_SOURCE=who
 elif [[ -n ${SUDO_USER:-} ]] && getent passwd "$SUDO_USER" >/dev/null; then
  LOGIN_NAME=$SUDO_USER LOGIN_SOURCE=SUDO_USER
 fi
 if [[ -n ${SSH_TTY:-} && $SSH_TTY == "$terminal" ]]; then LOGIN_TYPE=SSH; fi
 return 0
}
login_user(){ login_identity; printf '%s\n' "$LOGIN_NAME"; }
show_current_user(){
 login_identity
 printf 'Login User: %s\nLogin Source: %s\nEffective User: %s\nSudo User: %s\nHostname: %s\nSession ID: %s\nSession Type: %s\nTerminal: %s\n' "$LOGIN_NAME" "$LOGIN_SOURCE" "$(id -un)" "${SUDO_USER:-none}" "$(hostname)" "$LOGIN_SESSION" "$LOGIN_TYPE" "$LOGIN_TERMINAL"
 id
}
session_menu(){
 local choice name sid service
 while true; do
  printf '\n=== Manage User Sessions ===\n1) Show Current User\n2) List Logged-in Users\n3) List Active SSH Sessions\n4) Show User Login History\n5) Show Failed Login Attempts\n6) Show User Groups and Privileges\n0) Back\nChoose [0-6]: '
  read -r choice || return 0
  case "$choice" in
   1) show_current_user ;;
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

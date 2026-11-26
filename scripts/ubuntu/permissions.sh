#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run as root'; exit 1; }
log(){ printf '[%s] %s\n' "$1" "$2"; }
pause(){ printf '\nPress Enter to continue...'; read -r _ || true; }
ask(){ printf '%s: ' "$1" >&2; read -r REPLY; }
acl_ready(){
 if command -v getfacl >/dev/null && command -v setfacl >/dev/null; then return 0; fi
 ask 'ACL tools missing. Type INSTALL to install acl' || return 1
 [[ $REPLY == INSTALL ]] || return 1
 apt-get update && apt-get install -y acl
}
target(){
 ask 'Absolute directory path' || return 1
 [[ $REPLY == /* && ! -L $REPLY ]] || { log ERROR 'Absolute non-symlink path required' >&2; return 1; }
 path=$(realpath -e -- "$REPLY") || return 1
 [[ -d $path && $path != *$'\n'* ]] || return 1
 # Restrict writes to project directories, never system roots or this repository.
 if [[ $choice != 1 && $choice != 2 ]]; then
  case "$path" in /var/www/*|/srv/*|/home/*) ;; *) log ERROR 'Writes allowed only below /var/www, /srv or /home' >&2; return 1;; esac
  case "$path" in /var/www/Ubuntu24|/var/www/Ubuntu24/*|*/.ssh|*/.ssh/*|*/.gnupg|*/.gnupg/*) log ERROR 'Protected path' >&2; return 1;; esac
 fi
 stat -c 'Path: %n | Owner: %U | Group: %G | Mode: %a (%A)' -- "$path"
}
backup(){
 [[ ! -L /root/ubuntu24-permission-backups ]] || return 1
 install -d -m 700 /root/ubuntu24-permission-backups || return 1
 backup_file=$(mktemp /root/ubuntu24-permission-backups/acl.XXXXXXXX) || return 1
 # Save only the exact selected entries, excluding links and other filesystems.
 if ! find -P "$path" -xdev \( -type d -o -type f \) -exec getfacl -p -- {} + > "$backup_file"; then
  log ERROR 'Backup failed; no changes made'; return 1
 fi
 log INFO "Backup: $backup_file"
}
scope(){
 ask 'Scope: 1=directory only, 2=recursive directories, 3=recursive files, 4=both' || return 1
 case "$REPLY" in 1|2|3|4) selected=$REPLY;; *) return 1;; esac
}
apply(){
 case "$selected" in
  1) "$@" -- "$path";;
  2) find -P "$path" -xdev -type d -exec "$@" -- {} +;;
  3) find -P "$path" -xdev -type f -exec "$@" -- {} +;;
  4) find -P "$path" -xdev \( -type d -o -type f \) -exec "$@" -- {} +;;
 esac
}
approve(){
 printf 'Target: %q | Scope: %s\n' "$path" "${selected:-recursive}"
 printf 'Planned operation:'; printf ' %q' "$@"; printf '\n'
 ask 'Type APPLY to execute (Enter cancels; preview only)' || return 1
 [[ $REPLY == APPLY ]] || return 1
 acl_ready && backup
}
change(){
 local value
 scope || return 0
 case "$choice" in
  3) ask 'New owner' || return 0; value=$REPLY; getent passwd "$value" >/dev/null || return 1
     approve chown --no-dereference "$value" && apply chown --no-dereference "$value";;
  4) ask 'New group' || return 0; value=$REPLY; getent group "$value" >/dev/null || return 1
     approve chgrp --no-dereference "$value" && apply chgrp --no-dereference "$value";;
  5) ask 'Octal mode (3 digits, e.g. 750)' || return 0; value=$REPLY
     [[ $value =~ ^[0-7]{3}$ && $value != 777 ]] || { log ERROR 'Invalid or unsafe mode'; return 1; }
     approve chmod "$value" && apply chmod "$value";;
 esac
}
laravel(){
 local owner group writable
 [[ -f $path/artisan && -f $path/composer.json && -d $path/storage && -d $path/bootstrap/cache ]] || { log ERROR 'Not a Laravel project'; return 1; }
 for writable in "$path/storage" "$path/bootstrap/cache" "$path/.env"; do
  [[ ! -L $writable ]] || { log ERROR 'Unsafe symlink'; return 1; }
 done
 ask 'Deployment owner' || return 0; owner=$REPLY
 getent passwd "$owner" >/dev/null || return 1
 ask 'PHP-FPM group (verify pool configuration first)' || return 0; group=$REPLY
 getent group "$group" >/dev/null || return 1
 ps -eo user,group,args | grep '[p]hp-fpm' || true
 selected=4
 approve 'Laravel: preserve source modes; owner/group on source; writable storage/cache; .env 640' "$owner:$group" || return 0
 apply chown --no-dereference "$owner:$group" || return 1
 for writable in "$path/storage" "$path/bootstrap/cache"; do
  find -P "$writable" -xdev -type d -exec chmod 2775 -- {} + || return 1
  find -P "$writable" -xdev -type f -exec chmod 664 -- {} + || return 1
 done
 if [[ -f $path/.env ]]; then chmod 640 -- "$path/.env" || return 1; fi
}
shared(){
 local group
 ask 'Shared group' || return 0; group=$REPLY
 getent group "$group" >/dev/null || return 1
 selected=1
 approve chgrp "$group" 'and chmod 2770' || return 0
 chgrp --no-dereference "$group" -- "$path" && chmod 2770 -- "$path"
}
acl_menu(){
 local user perms
 acl_ready || return 1
 getfacl -p -- "$path" || return 1
 ask 'ACL username (blank cancels)' || return 0; user=$REPLY
 [[ -n $user ]] || return 0
 getent passwd "$user" >/dev/null || return 1
 ask 'Permissions (rwx, r-x, rw-, ---) or REMOVE' || return 0; perms=$REPLY
 selected=1
 if [[ $perms == REMOVE ]]; then
  approve setfacl -x "u:$user" && setfacl -x "u:$user" -- "$path"
 else
  [[ $perms =~ ^[r-][w-][x-]$ ]] || return 1
  approve setfacl -m "u:$user:$perms" && setfacl -m "u:$user:$perms" -- "$path"
 fi
}
restore(){
 local file entry resolved
 acl_ready || return 1
 ask 'Backup filename (acl.XXXXXXXX)' || return 0
 [[ $REPLY =~ ^acl\.[a-zA-Z0-9]{8}$ ]] || return 1
 file="/root/ubuntu24-permission-backups/$REPLY"
 [[ -f $file && ! -L $file && $(stat -c %u "$file") == 0 ]] || return 1
 # Validate every recorded path is still inside selected tree and not a symlink.
 while IFS= read -r entry; do
  entry=${entry#\# file: }
  [[ $entry != *\\* ]] || return 1
  resolved=$(realpath -e -- "$entry") || return 1
  [[ $resolved == "$entry" && ! -L $entry && ( $entry == "$path" || $entry == "$path/"* ) ]] || return 1
 done < <(grep '^# file: ' "$file")
 setfacl --test --restore="$file" || return 1
 selected=4
 approve setfacl --restore="$file" || return 0
 setfacl --restore="$file"
}
while true; do
 printf '\n=== Manage Directory Permissions ===\n1) Show Directory Information\n2) List Directory Permissions\n3) Change Directory Owner\n4) Change Directory Group\n5) Change Directory Permissions\n6) Apply Laravel Permissions\n7) Apply Shared Directory Permissions\n8) Manage Directory ACL\n9) Backup Directory Permissions\n10) Restore Directory Permissions\n0) Back\nChoose [0-10]: '
 read -r choice || exit 0
 case "$choice" in 0) exit 0;; 1|2|3|4|5|6|7|8|9|10) ;; *) continue;; esac
 target || { pause; continue; }
 case "$choice" in
  1) if command -v getfacl >/dev/null; then getfacl -p -- "$path" || true; fi;;
  2) find -P "$path" -maxdepth 2 -xdev -printf '%M %u:%g %p\n' || true;;
  3|4|5) change || log WARNING 'Cancelled or failed; check backup if changes started';;
  6) laravel || log WARNING 'Laravel operation failed; check backup';;
  7) shared || log WARNING 'Shared directory operation failed';;
  8) acl_menu || log WARNING 'ACL operation cancelled or failed';;
  9) if acl_ready; then backup || log ERROR 'Backup failed'; fi;;
  10) restore || log WARNING 'Restore refused or failed';;
 esac
 pause
done

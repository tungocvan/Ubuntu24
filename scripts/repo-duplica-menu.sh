#!/usr/bin/env bash
# Interactive GitHub repository manager. Invoked by repo-duplica.sh without arguments.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
say() { printf '\n[repo-duplica V4] %s\n' "$*"; }
pause_menu() { printf '\nPress Enter to return to menu... '; IFS= read -r _ || true; }
valid_repo() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; }
valid_owner() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; }
valid_full_repo() {
  [[ "$1" == */* ]] && [[ "${1#*/}" != */* ]] || return 1
  local o="${1%%/*}" n="${1#*/}"
  valid_owner "$o" && valid_repo "$n"
}
clean_repo_input() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}
current_owner() { gh api user --jq .login; }
require_auth() {
  command -v gh >/dev/null 2>&1 || { say 'Missing GitHub CLI (gh).'; return 1; }
  gh auth status >/dev/null 2>&1 || { say 'Not authenticated. Choose menu 4 to log in.'; return 1; }
}
normalize_repo() {
  local input="$1" owner
  if [[ "$input" == */* ]]; then
    valid_full_repo "$input" || return 1
    printf '%s\n' "$input"
  else
    valid_repo "$input" || return 1
    owner=$(current_owner) || return 1
    valid_owner "$owner" || return 1
    printf '%s/%s\n' "$owner" "$input"
  fi
}
check_connection() {
  require_auth || return 0
  say 'GitHub authentication status:'
  gh auth status || true
  say 'Active account:'
  gh api user --jq '{login, id}' || true
  say 'Git protocol configured in gh:'
  gh config get git_protocol --host github.com || true
  say 'This menu uses authenticated HTTPS for repository duplication.'
}
duplicate_repo() {
  require_auth || return 0
  local src dst src_owner dst_owner src_name dst_name dry visibility answer
  printf 'Source repository (name or owner/name): '
  IFS= read -r src || return 0
  src=$(normalize_repo "$(clean_repo_input "$src")") || { say 'Invalid source repository.'; return 0; }
  printf 'Destination repository (name or owner/name): '
  IFS= read -r dst || return 0
  dst=$(normalize_repo "$(clean_repo_input "$dst")") || { say 'Invalid destination repository.'; return 0; }
  src_owner="${src%%/*}"; dst_owner="${dst%%/*}"
  src_name="${src#*/}"; dst_name="${dst#*/}"
  if [[ "$src_owner" != "$dst_owner" ]]; then
    say 'V4 duplication currently supports source and destination in the same authenticated account only.'
    return 0
  fi
  if [[ "$src_owner" != "$(current_owner)" ]]; then
    say 'Source and destination must belong to the active GitHub account.'
    return 0
  fi
  printf 'Mode [1=Dry Run (default), 2=Create repository]: '
  IFS= read -r answer || return 0
  case "$answer" in
    ''|1) dry=true ;;
    2) dry=false ;;
    *) say 'Invalid mode.'; return 0 ;;
  esac
  printf 'Visibility [1=Private (default), 2=Public]: '
  IFS= read -r visibility || return 0
  local args=("$src_name" "$dst_name")
  case "$visibility" in
    ''|1) ;;
    2) args+=(--public) ;;
    *) say 'Invalid visibility.'; return 0 ;;
  esac
  [[ "$dry" == true ]] && args+=(--dry-run)
  bash "$ROOT_DIR/repo-duplica.sh" "${args[@]}" || say 'Duplication failed. Inspect output; do not retry blindly.'
}
delete_repo() {
  require_auth || return 0
  local target details permission confirm final
  say 'DANGER: This permanently deletes a GitHub repository, including its code and history.'
  printf 'Repository to DELETE (exact owner/name): '
  IFS= read -r target || return 0
  target=$(clean_repo_input "$target")
  valid_full_repo "$target" || { say 'Invalid repository name; owner/name required.'; return 0; }
  # Require explicit target owner; never delete based on a guessed account.
  details=$(gh api "repos/$target" --jq '{full_name,private,default_branch,archived}' 2>/dev/null) ||
    { say 'Cannot inspect repository; no deletion performed.'; return 0; }
  say "Repository details: $details"
  permission=$(gh api "repos/$target" --jq '.permissions.admin // false' 2>/dev/null) || {
    say 'Cannot verify admin permission; no deletion performed.'; return 0;
  }
  [[ "$permission" == true ]] || { say 'Admin permission is required; no deletion performed.'; return 0; }
  printf 'Type the EXACT repository name (%s) to continue: ' "$target"
  IFS= read -r confirm || return 0
  [[ "$confirm" == "$target" ]] || { say 'Confirmation mismatch; cancelled.'; return 0; }
  printf 'Type DELETE PERMANENTLY to execute irreversible GitHub deletion: '
  IFS= read -r final || return 0
  [[ "$final" == 'DELETE PERMANENTLY' ]] || { say 'Final confirmation mismatch; cancelled.'; return 0; }
  # No -F, no --silent, no automatic scope escalation. API returns an error if
  # the active token lacks delete_repo scope or GitHub policy forbids deletion.
  if gh api -X DELETE "repos/$target" >/dev/null; then
    say "GitHub deletion request succeeded for $target."
  else
    say 'GitHub deletion failed. Check delete_repo permission and repository policies.'
  fi
}
configure_account() {
  command -v gh >/dev/null 2>&1 || { say 'Install GitHub CLI (gh) first.'; return 0; }
  local option account target answer
  while true; do
    printf '\n=== Configure GitHub Account V4 ===\n1) List GitHub Accounts\n2) Add GitHub Account (Login)\n3) Switch Active Account\n4) View Git Protocol\n5) Grant Full Repository Token Scopes\n6) Check Token Permissions\n7) Logout GitHub Account\n0) Back\nChoose [0-7]: '
    IFS= read -r option || return 0
    case "$option" in
      1) gh auth status --hostname github.com || true ;;
      2) gh auth login --hostname github.com --git-protocol https --web || say 'Login failed or cancelled.' ;;
      3) gh auth switch --hostname github.com || say 'Account switch failed or cancelled.' ;;
      4) gh config get git_protocol --host github.com || true ;;
      5)
        if require_auth; then
          account=$(current_owner) || continue
          say "Active account: $account"
          say 'WARNING: repo, workflow and delete_repo scopes allow broad repository access, including deletion where account permissions permit.'
          printf 'Type GRANT to request these scopes: '
          IFS= read -r answer || return 0
          if [[ "$answer" == GRANT ]]; then
            gh auth refresh --hostname github.com --scopes repo,workflow,delete_repo && gh auth status --hostname github.com || say 'Scope refresh or verification failed.'
          else
            say 'Cancelled.'
          fi
        fi ;;
      6)
        if require_auth; then
          gh auth status --hostname github.com || true
          printf 'Repository to inspect (name or owner/name; blank to skip): '
          IFS= read -r target || return 0
          if [[ -n "$target" ]]; then
            if target=$(normalize_repo "$(clean_repo_input "$target")"); then
              gh api "repos/$target" --jq '{full_name, permissions}' || say 'Cannot inspect repository permissions.'
            else
              say 'Invalid repository name.'
            fi
          fi
          say 'Token scopes and repository permissions are separate; organization policies may further restrict operations.'
        fi ;;
      7)
        gh auth status --hostname github.com || true
        printf 'GitHub username to log out: '
        IFS= read -r account || return 0
        if valid_owner "$account"; then
          printf 'Type LOGOUT to remove local authentication for %s: ' "$account"
          IFS= read -r answer || return 0
          if [[ "$answer" == LOGOUT ]]; then
            gh auth logout --hostname github.com --user "$account" || say 'Logout failed.'
          else
            say 'Cancelled.'
          fi
        else
          say 'Invalid account name.'
        fi ;;
      0) return 0 ;;
      *) say 'Invalid option.' ;;
    esac
    pause_menu
  done
}

main() {
  while true; do
    printf '\n========== REPO DUPLICA V4 ==========\n'
    printf '1) Check GitHub connection\n2) Duplicate repository\n3) DELETE GitHub repository\n4) Configure GitHub account\n0) Back\nSelect: '
    local choice
    IFS= read -r choice || return 0
    case "$choice" in
      1) check_connection; pause_menu ;;
      2) duplicate_repo; pause_menu ;;
      3) delete_repo; pause_menu ;;
      4) configure_account; pause_menu ;;
      0) return 0 ;;
      *) say 'Invalid option.' ;;
    esac
  done
}
main "$@"

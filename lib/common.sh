#!/usr/bin/env bash
# Shared helpers for omarchy-scripts. Source this, do not execute it.

# Guard against double-sourcing.
[[ -n "${OMARCHY_COMMON_SH:-}" ]] && return 0
OMARCHY_COMMON_SH=1

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  readonly C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_DIM=$'\e[2m'
else
  readonly C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM=''
fi

# DRY_RUN=1 makes run() print commands instead of executing them.
DRY_RUN="${DRY_RUN:-0}"

log()   { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
skip()  { printf '%sskip%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s err%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# run <cmd...> — execute, or echo under DRY_RUN=1.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  dry%s %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

require_not_root() {
  [[ ${EUID:-$(id -u)} -ne 0 ]] || die "Run this as your normal user, not root."
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    have "$cmd" || die "Required command not found: $cmd"
  done
}

confirm() {
  local prompt="${1:-Continue?}" reply
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# write_file <path> <<<content — writes only when content differs; respects DRY_RUN.
write_file() {
  local path="$1" content
  content="$(cat)"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    skip "$path already up to date"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  dry%s would write %s\n' "$C_DIM" "$C_RESET" "$path"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  [[ -f "$path" ]] && cp -a "$path" "$path.bak.$(date +%Y%m%d%H%M%S)"
  printf '%s\n' "$content" > "$path"
  ok "wrote $path"
}

#!/usr/bin/env bash
# Omarchy-safe drop-in helpers. Source after lib/common.sh; do not execute.

[[ -n "${OMARCHY_OMARCHY_SH:-}" ]] && return 0
OMARCHY_OMARCHY_SH=1

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

OMARCHY_SCRIPTS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_SCRIPTS_ROOT="$(cd -- "$OMARCHY_SCRIPTS_LIB_DIR/.." && pwd)"

omarchy_scripts_repo_file() {
  printf '%s' "${OMARCHY_SCRIPTS_REPO_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-scripts/repo}"
}

omarchy_hooks_dir() {
  printf '%s' "${OMARCHY_HOOKS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/hooks}"
}

hypr_toggles_dir() {
  printf '%s' "${OMARCHY_HYPR_TOGGLES_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr}"
}

# remember_repo_root — write this clone's path so hooks can find bin/ later.
remember_repo_root() {
  write_file "$(omarchy_scripts_repo_file)" <<< "$OMARCHY_SCRIPTS_ROOT"
}

# write_hypr_toggle <name> <file> — install a Lua drop-in Omarchy auto-loads
# from ~/.local/state/omarchy/toggles/hypr without editing hyprland.lua.
write_hypr_toggle() {
  local name="$1" source="$2"
  [[ -n "$name" && -n "$source" ]] || die "write_hypr_toggle needs a name and a source file"
  [[ -f "$source" ]] || die "write_hypr_toggle source not found: $source"
  [[ "$name" == *.lua ]] || name="${name}.lua"
  write_file "$(hypr_toggles_dir)/$name" < "$source"
}

# install_omarchy_hook <type> <src> — copy a hook into the same layout as
# `omarchy hook install`, skipping an identical file. Implemented here so tests
# with a fake HOME do not need a live omarchy CLI.
install_omarchy_hook() {
  local type="$1" src="$2" dest
  [[ -n "$type" && -n "$src" ]] || die "install_omarchy_hook needs a type and a source file"
  [[ -f "$src" ]] || die "hook source not found: $src"
  dest="$(omarchy_hooks_dir)/${type}.d/$(basename -- "$src")"
  write_file "$dest" < "$src"
  if [[ "$DRY_RUN" != "1" && -f "$dest" ]]; then
    chmod 0755 -- "$dest"
  fi
}

# install_setup_hook <type> <name> — record the repo path and install a
# wrapper from config/hooks/<type>.d/<name>.
install_setup_hook() {
  local type="$1" name="$2" src
  [[ -n "$type" && -n "$name" ]] || die "install_setup_hook needs a type and a name"
  src="$OMARCHY_SCRIPTS_ROOT/config/hooks/${type}.d/${name}"
  remember_repo_root
  install_omarchy_hook "$type" "$src"
}

# strip_marked_block <file> <begin> <end> — drop the inclusive region from the
# first line containing <begin> through the first following line containing
# <end>. Used to migrate off shipped files we used to edit in place.
strip_marked_block() {
  local file="$1" begin="$2" end="$3" tmp
  [[ -n "$file" && -n "$begin" && -n "$end" ]] || die "strip_marked_block needs a file, begin, and end"
  [[ -f "$file" ]] || return 0
  if ! grep -qF -- "$begin" "$file"; then
    skip "$file has no marked block to strip"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  dry%s would strip marked block from %s\n' "$C_DIM" "$C_RESET" "$file"
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/omarchy-strip.XXXXXX")"
  awk -v b="$begin" -v e="$end" '
    index($0, b) { skipping = 1; next }
    skipping && index($0, e) { skipping = 0; next }
    skipping { next }
    { print }
  ' "$file" > "$tmp"
  if cmp -s "$file" "$tmp"; then
    rm -f -- "$tmp"
    skip "$file already has no marked block"
    return 0
  fi
  cp -a -- "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
  mv -- "$tmp" "$file"
  ok "stripped marked block from $file"
}

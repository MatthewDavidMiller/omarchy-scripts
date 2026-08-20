#!/usr/bin/env bash
# Thin TUI layer for omarchy-scripts. Source this, do not execute it.
#
# Prefers gum (shipped with omarchy) and degrades to a plain numbered menu when
# it is missing, so nothing here is a hard dependency.

[[ -n "${OMARCHY_TUI_SH:-}" ]] && return 0
OMARCHY_TUI_SH=1

TUI_ACCENT="${TUI_ACCENT:-212}"   # gum colour for headers and selections
TUI_DIM="${TUI_DIM:-244}"

# TUI_NO_GUM=1 forces the plain menu (useful for testing, or if you dislike gum).
tui_gum() {
  [[ -z "${TUI_NO_GUM:-}" ]] && command -v gum >/dev/null 2>&1
}

# True when we can actually drive an interactive UI.
tui_interactive() { [[ -t 0 && -t 1 ]]; }

# tui_title <title> [subtitle]
tui_title() {
  local title="$1" subtitle="${2:-}"
  if tui_gum; then
    gum style --border rounded --border-foreground "$TUI_ACCENT" \
      --padding "0 2" --margin "1 0 0 0" --align center \
      "$title" ${subtitle:+"$(gum style --foreground "$TUI_DIM" "$subtitle")"}
  else
    printf '\n%s┌─ %s ─┐%s\n' "$C_BLUE" "$title" "$C_RESET"
    [[ -n "$subtitle" ]] && printf '%s   %s%s\n' "$C_DIM" "$subtitle" "$C_RESET"
  fi
}

# tui_banner <text> — section header shown between scripts.
tui_banner() {
  if tui_gum; then
    gum style --foreground "$TUI_ACCENT" --bold --margin "1 0 0 0" "▸ $1"
  else
    printf '\n%s▸ %s%s\n' "$C_BLUE" "$1" "$C_RESET"
  fi
}

# tui_menu <header> <option>... — echoes the chosen option, exit 1 if cancelled.
tui_menu() {
  local header="$1"; shift
  local options=("$@")

  if tui_gum; then
    gum choose --header "$header" --header.foreground "$TUI_ACCENT" \
      --cursor "› " --height 12 "${options[@]}"
    return $?
  fi

  local i choice
  printf '\n%s%s%s\n' "$C_BLUE" "$header" "$C_RESET" >&2
  for i in "${!options[@]}"; do
    printf '  %2d) %s\n' $((i + 1)) "${options[$i]}" >&2
  done
  read -r -p "Choice [1-${#options[@]}, q to quit]: " choice >&2 || return 1
  [[ "$choice" == "q" ]] && return 1
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )) || return 1
  printf '%s\n' "${options[$((choice - 1))]}"
}

# tui_multiselect <header> <option>... — echoes chosen options, one per line.
# Everything starts selected; exit 1 if cancelled.
tui_multiselect() {
  local header="$1"; shift
  local options=("$@")

  if tui_gum; then
    local selected
    selected="$(IFS=,; printf '%s' "${options[*]}")"
    gum choose --no-limit --selected="$selected" \
      --header "$header" --header.foreground "$TUI_ACCENT" \
      --cursor "› " --height 12 "${options[@]}"
    return $?
  fi

  local i input token
  printf '\n%s%s%s\n' "$C_BLUE" "$header" "$C_RESET" >&2
  for i in "${!options[@]}"; do
    printf '  %2d) %s\n' $((i + 1)) "${options[$i]}" >&2
  done
  read -r -p "Numbers (space/comma separated, blank = all): " input >&2 || return 1
  if [[ -z "${input// /}" ]]; then
    printf '%s\n' "${options[@]}"
    return 0
  fi
  for token in ${input//,/ }; do
    [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#options[@]} )) \
      && printf '%s\n' "${options[$((token - 1))]}"
  done
}

# tui_confirm <prompt> — exit 0 for yes.
tui_confirm() {
  local prompt="$1"
  if tui_gum; then
    gum confirm "$prompt"
    return $?
  fi
  local reply
  read -r -p "$prompt [y/N] " reply >&2 || return 1
  [[ "$reply" =~ ^[Yy]$ ]]
}

# tui_pause — wait for the user before redrawing a menu.
tui_pause() {
  tui_interactive || return 0
  printf '\n'
  read -r -p "Press Enter to continue… " _ >&2 || true
}

#!/usr/bin/env bash
# lib/tui.sh — the plain-bash fallback path, which needs no gum and no tty.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

export TUI_NO_GUM=1
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/tui.sh
source "$REPO_ROOT/lib/tui.sh"

it "TUI_NO_GUM forces the fallback even where gum is installed"
tui_gum
assert_status 1 $?

it "tui_interactive is false when stdin is not a terminal"
tui_interactive </dev/null
assert_status 1 $?

it "tui_menu returns the option matching the number entered"
choice="$(tui_menu "pick" alpha beta gamma <<<"2" 2>/dev/null)"
assert_eq "beta" "$choice"

it "tui_menu treats q as cancel"
tui_menu "pick" alpha beta <<<"q" >/dev/null 2>&1
assert_status 1 $?

it "tui_menu rejects an out-of-range choice"
tui_menu "pick" alpha beta <<<"99" >/dev/null 2>&1
assert_status 1 $?

it "tui_menu rejects a non-numeric choice"
tui_menu "pick" alpha beta <<<"banana" >/dev/null 2>&1
assert_status 1 $?

it "tui_multiselect returns every option when the answer is blank"
picked="$(tui_multiselect "pick" a b c <<<"" 2>/dev/null | tr '\n' ' ')"
assert_eq "a b c " "$picked"

it "tui_multiselect accepts space-separated numbers"
picked="$(tui_multiselect "pick" a b c <<<"1 3" 2>/dev/null | tr '\n' ' ')"
assert_eq "a c " "$picked"

it "tui_multiselect accepts comma-separated numbers"
picked="$(tui_multiselect "pick" a b c <<<"2,3" 2>/dev/null | tr '\n' ' ')"
assert_eq "b c " "$picked"

it "tui_multiselect ignores out-of-range numbers"
picked="$(tui_multiselect "pick" a b c <<<"1 99" 2>/dev/null | tr '\n' ' ')"
assert_eq "a " "$picked"

it "tui_confirm accepts y"
tui_confirm "ok?" <<<"y" >/dev/null 2>&1
assert_status 0 $?

it "tui_confirm defaults to no on a blank answer"
tui_confirm "ok?" <<<"" >/dev/null 2>&1
assert_status 1 $?

finish

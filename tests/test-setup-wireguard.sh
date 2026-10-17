#!/usr/bin/env bash
# bin/setup-wireguard — against a throwaway HOME with stubbed omarchy, nmcli,
# sudo and omarchy-shell. Stub state lives in files under $HOME.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"
PLUGIN_ID=omarchy-scripts.wireguard

# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
case "$*" in
  "pkg present wireguard-tools") [[ -f "$HOME/.pkg-installed" ]] ;;
  "pkg add wireguard-tools")
    [[ "${OMARCHY_ADD_FAIL:-0}" != 1 ]] || exit 42
    touch "$HOME/.pkg-installed"
    ;;
  "plugin list --json")
    [[ "${SHELL_DOWN:-0}" != 1 ]] || exit 1
    enabled=false
    [[ -f "$HOME/.plugin-enabled" ]] && enabled=true
    printf "[{\"id\":\"omarchy.audio\",\"enabled\":true},{\"id\":\"omarchy-scripts.wireguard\",\"enabled\":%s}]\n" "$enabled"
    ;;
  "plugin enable omarchy-scripts.wireguard --section right") touch "$HOME/.plugin-enabled" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" nmcli '
conns="$HOME/.nm-connections"
touch "$conns"
case "$*" in
  "-t -f NAME,TYPE connection show") cat "$conns" ;;
  "-t -f NAME connection show --active") [[ -f "$HOME/.nm-active" ]] && cat "$HOME/.nm-active"; true ;;
  "connection import type wireguard file "*)
    name="$(basename -- "$6" .conf)"
    printf "%s:wireguard\n" "$name" >> "$conns"
    printf "%s\n" "$name" > "$HOME/.nm-active"
    ;;
  "connection modify "*" connection.autoconnect no") ;;
  "connection down id "*) rm -f "$HOME/.nm-active" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" sudo 'exec "$@"'
# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy-shell '[[ "${SHELL_DOWN:-0}" != 1 ]]'

wg_setup() {
  local home="$1"; shift
  env HOME="$home" PATH="$STUBS:$PATH" "$REPO_ROOT/bin/setup-wireguard" "$@" </dev/null 2>&1
}

write_conf() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'CONF'
[Interface]
PrivateKey = aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tPQ=
Address = 10.0.0.2/32
DNS = 10.0.0.1

[Peer]
PublicKey = d29ybGQtd29ybGQtd29ybGQtd29ybGQtd29ybGQ9PQ=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
CONF
}

count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

# --- dry run ---------------------------------------------------------------

FAKE_HOME="$(make_fake_home)"
write_conf "$FAKE_HOME/wg0.conf"
out="$(wg_setup "$FAKE_HOME" --dry-run --yes --config "$FAKE_HOME/wg0.conf")"

it "--dry-run says it would install wireguard-tools"
assert_contains "$out" "omarchy pkg add wireguard-tools"

it "--dry-run says it would import the config"
assert_contains "$out" "sudo nmcli connection import type wireguard file $FAKE_HOME/wg0.conf"

it "--dry-run installs nothing"
assert_no_file "$FAKE_HOME/.pkg-installed"

it "--dry-run imports nothing"
assert_eq "" "$(cat "$FAKE_HOME/.nm-connections" 2>/dev/null)" "connections"

it "--dry-run writes no plugin files"
assert_no_file "$FAKE_HOME/.config/omarchy/plugins/$PLUGIN_ID"

it "--dry-run does not enable the widget"
assert_no_file "$FAKE_HOME/.plugin-enabled"

# --- first run -------------------------------------------------------------

out="$(wg_setup "$FAKE_HOME" --yes --config "$FAKE_HOME/wg0.conf")"
status=$?

it "first run succeeds"
assert_status 0 "$status"

it "installs wireguard-tools through omarchy"
assert_file_contains "$STUBS/omarchy.log" "pkg add wireguard-tools"

it "imports the config through sudo nmcli"
assert_file_contains "$STUBS/sudo.log" "nmcli connection import type wireguard file $FAKE_HOME/wg0.conf"

it "turns autoconnect off"
assert_file_contains "$STUBS/nmcli.log" "connection modify wg0 connection.autoconnect no"

it "leaves the tunnel down after import"
assert_no_file "$FAKE_HOME/.nm-active"

it "warns that the source config holds a private key"
assert_contains "$out" "private key"

it "installs the plugin manifest"
assert_file_contains "$FAKE_HOME/.config/omarchy/plugins/$PLUGIN_ID/manifest.json" "\"id\": \"$PLUGIN_ID\""

it "installs the plugin widget"
assert_file "$FAKE_HOME/.config/omarchy/plugins/$PLUGIN_ID/Widget.qml"

it "rescans plugins after copying them"
assert_file_contains "$STUBS/omarchy-shell.log" "shell rescanPlugins"

it "enables the bar widget"
assert_file "$FAKE_HOME/.plugin-enabled"

# --- second run is a no-op -------------------------------------------------

before_add="$(count "pkg add" "$STUBS/omarchy.log")"
before_import="$(count "connection import" "$STUBS/nmcli.log")"
before_enable="$(count "plugin enable" "$STUBS/omarchy.log")"
before_rescan="$(count "rescanPlugins" "$STUBS/omarchy-shell.log")"
out2="$(wg_setup "$FAKE_HOME" --yes --config "$FAKE_HOME/wg0.conf")"

it "second run does not reinstall the package"
assert_eq "$before_add" "$(count "pkg add" "$STUBS/omarchy.log")" "pkg add calls"

it "second run does not re-import the tunnel"
assert_eq "$before_import" "$(count "connection import" "$STUBS/nmcli.log")" "import calls"

it "second run does not re-enable the widget"
assert_eq "$before_enable" "$(count "plugin enable" "$STUBS/omarchy.log")" "enable calls"

it "second run does not rescan unchanged plugins"
assert_eq "$before_rescan" "$(count "rescanPlugins" "$STUBS/omarchy-shell.log")" "rescan calls"

it "second run reports the tunnel as already imported"
assert_contains "$out2" "wg0 already imported"

it "second run reports the widget as already enabled"
assert_contains "$out2" "already enabled"

it "a run without --config skips when a WireGuard connection exists"
assert_contains "$(wg_setup "$FAKE_HOME" --yes)" "WireGuard connection already present: wg0"

# --- no config, no terminal ------------------------------------------------

BARE_HOME="$(make_fake_home)"
out="$(wg_setup "$BARE_HOME" --yes)"
status=$?

it "without --config or a terminal it skips the import and succeeds"
assert_status 0 "$status"

it "explains how to import later"
assert_contains "$out" "re-run with --config PATH"

it "still installs the bar widget"
assert_file "$BARE_HOME/.plugin-enabled"

# --- shell not running -----------------------------------------------------

DOWN_HOME="$(make_fake_home)"
out="$(env SHELL_DOWN=1 HOME="$DOWN_HOME" PATH="$STUBS:$PATH" \
  "$REPO_ROOT/bin/setup-wireguard" --yes </dev/null 2>&1)"
status=$?

it "a missing omarchy-shell is a warning, not a failure"
assert_status 0 "$status"

it "says to re-run from the desktop session"
assert_contains "$out" "desktop session"

# --- invalid configs -------------------------------------------------------

BAD_HOME="$(make_fake_home)"
printf 'not a wireguard file\n' > "$BAD_HOME/wg0.conf"
out="$(wg_setup "$BAD_HOME" --yes --config "$BAD_HOME/wg0.conf")"
status=$?

it "rejects a file without an [Interface] section"
assert_status 1 "$status"

it "explains the rejected file"
assert_contains "$out" "no [Interface] section"

write_conf "$BAD_HOME/this-name-is-far-too-long.conf"
out="$(wg_setup "$BAD_HOME" --yes --config "$BAD_HOME/this-name-is-far-too-long.conf")"
status=$?

it "rejects a file name that cannot be an interface name"
assert_status 1 "$status"

it "suggests renaming the file"
assert_contains "$out" "rename the file"

out="$(wg_setup "$BAD_HOME" --yes --config "$BAD_HOME/missing.conf")"
status=$?

it "rejects a missing file"
assert_status 1 "$status"

# --- failures and arguments ------------------------------------------------

FAIL_HOME="$(make_fake_home)"
env OMARCHY_ADD_FAIL=1 HOME="$FAIL_HOME" PATH="$STUBS:$PATH" \
  "$REPO_ROOT/bin/setup-wireguard" --yes </dev/null >/dev/null 2>&1
status=$?

it "propagates a package installation failure"
assert_status 42 "$status"

it "help text is available"
assert_contains "$(wg_setup "$FAKE_HOME" --help)" "Usage: setup-wireguard"

it "rejects unknown arguments"
wg_setup "$FAKE_HOME" --not-a-flag >/dev/null
assert_status 1 $?

it "rejects --config without a path"
wg_setup "$FAKE_HOME" --config >/dev/null
assert_status 1 $?

finish

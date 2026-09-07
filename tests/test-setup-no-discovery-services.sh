#!/usr/bin/env bash
# bin/setup-no-discovery-services — against a stubbed systemctl backed by a
# directory of unit-state files, so "is the unit actually disabled" is a real
# check rather than an assertion about which command was called.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"

stub_bin "$STUBS" sudo 'exec "$@"'

# A unit is installed when $FAKE_UNITS/<unit> exists; its contents are the
# enabled/disabled state. `disable --now` and `enable --now` flip it, so a
# later is-enabled sees what the script actually did.
# shellcheck disable=SC2016
stub_bin "$STUBS" systemctl '
dir="${FAKE_UNITS:?}"
case "$1" in
  list-unit-files)
    # Real systemctl prints a header and a footer around the match. Print them
    # too: the script has to pick its unit out of the noise.
    printf "UNIT FILE STATE PRESET\n"
    [[ -f "$dir/$2" ]] && printf "%s %s disabled\n" "$2" "$(cat "$dir/$2")"
    printf "\n1 unit files listed.\n"
    ;;
  is-enabled)
    unit="${*: -1}"
    [[ -f "$dir/$unit" && "$(cat "$dir/$unit")" == enabled ]]
    ;;
  is-active)
    unit="${*: -1}"
    [[ -f "$dir/$unit" && "$(cat "$dir/$unit")" == enabled ]]
    ;;
  disable)
    unit="${*: -1}"
    [[ -f "$dir/$unit" ]] || exit 1
    printf disabled > "$dir/$unit"
    ;;
  enable)
    unit="${*: -1}"
    [[ -f "$dir/$unit" ]] || exit 1
    printf enabled > "$dir/$unit"
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# A stock Omarchy machine: every unit installed, cups and avahi enabled.
make_units() {
  local dir="$TEST_TMP/units.$RANDOM" unit
  mkdir -p "$dir"
  for unit in cups.path cups.socket cups.service \
              avahi-daemon.socket avahi-daemon.service; do
    printf enabled > "$dir/$unit"
  done
  printf '%s' "$dir"
}

run_setup() {
  env HOME="$HOME_DIR" \
      PATH="$STUBS:$PATH" \
      FAKE_UNITS="$UNITS" \
      PRINT_APPLET="$HOME_DIR/.config/autostart/print-applet.desktop" \
      NSSWITCH_CONF="$HOME_DIR/nsswitch.conf" \
      "$REPO_ROOT/bin/setup-no-discovery-services" "$@" 2>&1
}

state() { cat "$UNITS/$1"; }

# --- dry run changes nothing -----------------------------------------------

HOME_DIR="$(make_fake_home)"
UNITS="$(make_units)"

out="$(run_setup --dry-run)"

it "--dry-run leaves cups.service enabled"
assert_eq "enabled" "$(state cups.service)"

it "--dry-run leaves avahi-daemon.service enabled"
assert_eq "enabled" "$(state avahi-daemon.service)"

it "--dry-run still says what it would do"
assert_contains "$out" "cups.service"

# --- the real run ----------------------------------------------------------

HOME_DIR="$(make_fake_home)"
UNITS="$(make_units)"

out="$(run_setup)"

it "disables cups.service"
assert_eq "disabled" "$(state cups.service)"

# The socket and path units are the whole point: leaving either enabled means
# the next print-queue access starts the service straight back up.
it "disables cups.socket, which would otherwise reactivate the service"
assert_eq "disabled" "$(state cups.socket)"

it "disables cups.path, which would otherwise reactivate the service"
assert_eq "disabled" "$(state cups.path)"

it "disables avahi-daemon.service"
assert_eq "disabled" "$(state avahi-daemon.service)"

it "disables avahi-daemon.socket"
assert_eq "disabled" "$(state avahi-daemon.socket)"

it "takes the activators away before the service they activate"
cups_path_line="$(printf '%s\n' "$out" | grep -n 'disabled and stopped cups.path' | cut -d: -f1)"
cups_service_line="$(printf '%s\n' "$out" | grep -n 'disabled and stopped cups.service' | cut -d: -f1)"
if (( cups_path_line < cups_service_line )); then
  pass
else
  fail "cups.service was disabled before cups.path"
fi

it "explains that .local names stop resolving"
assert_contains "$out" ".local"

it "names the packages it deliberately did not remove"
assert_contains "$out" "pipewire-pulse"

# --- idempotence -----------------------------------------------------------

out="$(run_setup)"

it "a second run reports every unit as already handled"
assert_contains "$out" "already stopped and disabled"

it "a second run does not disable anything again"
assert_not_contains "$out" "disabled and stopped"

it "a second run exits successfully"
run_setup >/dev/null 2>&1
assert_status 0 $?

it "a second run leaves cups.service disabled"
assert_eq "disabled" "$(state cups.service)"

# --- revert ----------------------------------------------------------------

out="$(run_setup --revert)"

it "--revert re-enables cups.service"
assert_eq "enabled" "$(state cups.service)"

it "--revert re-enables cups.socket"
assert_eq "enabled" "$(state cups.socket)"

it "--revert re-enables avahi-daemon.service"
assert_eq "enabled" "$(state avahi-daemon.service)"

it "--revert says .local names work again"
assert_contains "$out" "resolve again"

it "a second --revert changes nothing"
out="$(run_setup --revert)"
assert_contains "$out" "already enabled"

# --- narrowing flags -------------------------------------------------------

HOME_DIR="$(make_fake_home)"
UNITS="$(make_units)"
out="$(run_setup --keep-cups)"

it "--keep-cups leaves cups.service alone"
assert_eq "enabled" "$(state cups.service)"

it "--keep-cups still disables avahi"
assert_eq "disabled" "$(state avahi-daemon.service)"

it "--keep-cups says why cups was skipped"
assert_contains "$out" "leaving CUPS alone"

HOME_DIR="$(make_fake_home)"
UNITS="$(make_units)"
out="$(run_setup --keep-avahi)"

it "--keep-avahi leaves avahi alone"
assert_eq "enabled" "$(state avahi-daemon.service)"

it "--keep-avahi still disables cups"
assert_eq "disabled" "$(state cups.service)"

# --- a machine that never had these ----------------------------------------

HOME_DIR="$(make_fake_home)"
UNITS="$TEST_TMP/units.empty"
mkdir -p "$UNITS"

it "a machine without the units reports them as not installed"
out="$(run_setup)"
assert_contains "$out" "is not installed"

it "and still exits successfully"
run_setup >/dev/null 2>&1
assert_status 0 $?

# --- the printer tray applet -----------------------------------------------

HOME_DIR="$(make_fake_home)"
UNITS="$(make_units)"
mkdir -p "$HOME_DIR/.config/autostart"
printf '[Desktop Entry]\nHidden=true\n' > "$HOME_DIR/.config/autostart/print-applet.desktop"

it "recognises an already-suppressed printer applet"
out="$(run_setup)"
assert_contains "$out" "already suppressed"

HOME_DIR="$(make_fake_home)"
UNITS="$(make_units)"

it "reports an applet that still autostarts, rather than writing one"
out="$(run_setup)"
assert_contains "$out" "still autostarts"

it "does not create the autostart entry itself"
assert_no_file "$HOME_DIR/.config/autostart/print-applet.desktop"

# --- interface -------------------------------------------------------------

it "help text is available without touching the system"
out="$(run_setup --help)"
assert_contains "$out" "Usage: setup-no-discovery-services"

it "accepts --yes, which setup-all passes to every script"
run_setup --yes --dry-run >/dev/null 2>&1
assert_status 0 $?

it "rejects unknown arguments"
run_setup --nope >/dev/null 2>&1
assert_status 1 $?

finish

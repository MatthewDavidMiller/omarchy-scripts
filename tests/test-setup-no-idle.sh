#!/usr/bin/env bash
# bin/setup-no-idle — against a throwaway HOME with a stubbed omarchy.
# The stub mirrors omarchy-toggle-idle and omarchy-toggle: both are just state
# files under ~/.local/state/omarchy, so the real ones are never needed.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

FAKE_HOME="$(make_fake_home)"
STUBS="$TEST_TMP/stubs"

# Stub bodies are literal shell, expanded when the stub runs, not now.
# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
awake="$HOME/.local/state/omarchy/indicators/stay-awake"
flag="$HOME/.local/state/omarchy/toggles/screensaver-off"
case "$*" in
  "toggle idle status")
    if [[ -f $awake ]]; then echo "{\"enabled\":true,\"class\":\"enabled\"}"
    else echo "{\"enabled\":false,\"class\":\"disabled\"}"; fi ;;
  "toggle idle stay-awake")      mkdir -p "$(dirname "$awake")"; touch "$awake"; echo disabled ;;
  "toggle idle allow-idle")      rm -f "$awake"; echo enabled ;;
  "toggle enabled screensaver-off") [[ -f $flag ]] ;;
  "toggle screensaver-off on")   mkdir -p "$(dirname "$flag")"; touch "$flag" ;;
  "toggle screensaver-off off")  rm -f "$flag" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

no_idle_setup() {
  env HOME="$FAKE_HOME" PATH="$STUBS:$PATH" \
      "$REPO_ROOT/bin/setup-no-idle" "$@" 2>&1
}

AWAKE="$FAKE_HOME/.local/state/omarchy/indicators/stay-awake"
SCREENSAVER_OFF="$FAKE_HOME/.local/state/omarchy/toggles/screensaver-off"

# --- dry run changes nothing -----------------------------------------------

out="$(no_idle_setup --dry-run --yes)"

it "--dry-run does not set stay-awake"
assert_no_file "$AWAKE"

it "--dry-run does not disable the screensaver"
assert_no_file "$SCREENSAVER_OFF"

it "--dry-run still says what it would do"
assert_contains "$out" "omarchy toggle idle stay-awake"

# --- real run ---------------------------------------------------------------

out="$(no_idle_setup --yes)"

it "sets stay-awake, which gates the whole idle cycle"
if [[ -f "$AWAKE" ]]; then pass; else fail "expected $AWAKE to exist"; fi

it "disables the screensaver outright"
if [[ -f "$SCREENSAVER_OFF" ]]; then pass; else fail "expected $SCREENSAVER_OFF to exist"; fi

it "never zeroes the shell.json timeouts, which would lock immediately"
assert_no_file "$FAKE_HOME/.config/omarchy/shell.json"

it "reports the resulting state"
assert_contains "$out" "idle:        disabled (staying awake)"

# --- second run is a no-op --------------------------------------------------

before="$(wc -l < "$STUBS/omarchy.log")"
out2="$(no_idle_setup --yes)"

it "a second run skips the idle toggle"
assert_contains "$out2" "already staying awake"

it "a second run skips the screensaver toggle"
assert_contains "$out2" "screensaver already disabled"

it "a second run issues no toggle commands, only status checks"
after_writes="$(grep -cE 'toggle (idle (stay-awake|allow-idle)|screensaver-off (on|off))' "$STUBS/omarchy.log" || true)"
assert_eq "2" "$after_writes" "cumulative write commands"
# Guards the count above against a stub that stopped logging entirely.
it "the second run did call omarchy"
if [[ "$(wc -l < "$STUBS/omarchy.log")" -gt "$before" ]]; then pass; else fail "no calls logged"; fi

# --- reversing --------------------------------------------------------------

out3="$(no_idle_setup --allow-idle --yes)"

it "--allow-idle clears stay-awake"
assert_no_file "$AWAKE"

it "--allow-idle re-enables the screensaver"
assert_no_file "$SCREENSAVER_OFF"

it "--allow-idle reports the stock timings are back"
assert_contains "$out3" "stock timings"

it "--allow-idle a second time changes nothing"
assert_contains "$(no_idle_setup --allow-idle --yes)" "idle already allowed"

# --- --keep-screensaver -----------------------------------------------------

KEEP_HOME="$(make_fake_home)"
keep_out="$(env HOME="$KEEP_HOME" PATH="$STUBS:$PATH" \
  "$REPO_ROOT/bin/setup-no-idle" --keep-screensaver --yes 2>&1)"

it "--keep-screensaver still stops the idle timers"
if [[ -f "$KEEP_HOME/.local/state/omarchy/indicators/stay-awake" ]]; then
  pass
else
  fail "expected stay-awake to be set"
fi

it "--keep-screensaver leaves the screensaver launchable by hand"
assert_no_file "$KEEP_HOME/.local/state/omarchy/toggles/screensaver-off"

it "--keep-screensaver says so"
assert_contains "$keep_out" "launchable by hand"

# --- argument handling ------------------------------------------------------

it "help text is available without touching the system"
assert_contains "$(no_idle_setup --help)" "Usage: setup-no-idle"

it "rejects unknown arguments"
no_idle_setup --not-a-flag >/dev/null 2>&1
assert_status 1 $?

it "dies when omarchy is not installed"
# A PATH with just enough to start the script — bash for the shebang, dirname
# to resolve SCRIPT_DIR — and nothing else, so require_cmd is what stops it.
MINIMAL="$TEST_TMP/minimal-path"
mkdir -p "$MINIMAL"
for cmd in bash dirname; do ln -sf "$(command -v "$cmd")" "$MINIMAL/$cmd"; done
env HOME="$FAKE_HOME" PATH="$MINIMAL" "$REPO_ROOT/bin/setup-no-idle" --yes >/dev/null 2>&1
assert_status 1 $?

finish

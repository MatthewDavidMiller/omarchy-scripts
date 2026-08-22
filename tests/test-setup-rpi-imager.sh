#!/usr/bin/env bash
# bin/setup-rpi-imager — against a throwaway HOME with a stubbed omarchy.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

FAKE_HOME="$(make_fake_home)"
STUBS="$TEST_TMP/stubs"

# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
state="$HOME/.rpi-imager-installed"
case "$*" in
  "pkg present rpi-imager") [[ -f "$state" ]] ;;
  "pkg add rpi-imager")
    [[ "${OMARCHY_ADD_FAIL:-0}" != 1 ]] || exit 42
    [[ "${OMARCHY_ADD_NOOP:-0}" == 1 ]] || touch "$state"
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

rpi_setup() {
  env HOME="$FAKE_HOME" PATH="$STUBS:$PATH" \
      "$REPO_ROOT/bin/setup-rpi-imager" "$@" 2>&1
}

# --- dry run ---------------------------------------------------------------

out="$(rpi_setup --dry-run --yes)"

it "--dry-run does not install the package"
assert_no_file "$FAKE_HOME/.rpi-imager-installed"

it "--dry-run says which official package it would install"
assert_contains "$out" "omarchy pkg add rpi-imager"

it "--dry-run never invokes the package add command"
assert_eq "0" "$(grep -c '^pkg add rpi-imager$' "$STUBS/omarchy.log" || true)" "add calls"

# --- install and idempotence ----------------------------------------------

out="$(rpi_setup --yes)"

it "installs rpi-imager through Omarchy"
assert_file_contains "$STUBS/omarchy.log" "pkg add rpi-imager"

it "verifies and reports a successful install"
assert_contains "$out" "Raspberry Pi Imager installed"

before_adds="$(grep -c '^pkg add rpi-imager$' "$STUBS/omarchy.log")"
out2="$(rpi_setup --yes)"
after_adds="$(grep -c '^pkg add rpi-imager$' "$STUBS/omarchy.log")"

it "a second run reports that the package is already installed"
assert_contains "$out2" "already installed"

it "a second run does not call the installer"
assert_eq "$before_adds" "$after_adds" "add calls"

# --- failures --------------------------------------------------------------

FAIL_HOME="$(make_fake_home)"
env HOME="$FAIL_HOME" PATH="$STUBS:$PATH" OMARCHY_ADD_FAIL=1 \
  "$REPO_ROOT/bin/setup-rpi-imager" --yes >/dev/null 2>&1
status=$?

it "propagates a package installation failure"
assert_status 42 "$status"

NOOP_HOME="$(make_fake_home)"
noop_out="$(env HOME="$NOOP_HOME" PATH="$STUBS:$PATH" OMARCHY_ADD_NOOP=1 \
  "$REPO_ROOT/bin/setup-rpi-imager" --yes 2>&1)"
status=$?

it "fails if the package is still missing after installation"
assert_status 1 "$status"

it "explains a failed post-install verification"
assert_contains "$noop_out" "was not registered as installed"

# --- argument handling -----------------------------------------------------

it "help text is available without touching the system"
assert_contains "$(rpi_setup --help)" "Usage: setup-rpi-imager"

it "rejects unknown arguments"
rpi_setup --not-a-flag >/dev/null 2>&1
assert_status 1 $?

it "dies when omarchy is not installed"
MINIMAL="$TEST_TMP/minimal-path"
mkdir -p "$MINIMAL"
for cmd in bash dirname; do ln -sf "$(command -v "$cmd")" "$MINIMAL/$cmd"; done
env HOME="$FAKE_HOME" PATH="$MINIMAL" \
  "$REPO_ROOT/bin/setup-rpi-imager" --yes >/dev/null 2>&1
assert_status 1 $?

finish

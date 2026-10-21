#!/usr/bin/env bash
# bin/setup-no-lid-sleep — against a fixture drop-in path with a stubbed logind.
# The busctl stub answers from what the systemctl stub last "reloaded", so a
# drop-in that was written but never reloaded reads as not yet applied, the
# same way the real logind behaves.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"
DROPIN="$TEST_TMP/etc/systemd/logind.conf.d/90-omarchy-scripts-lid-ignore.conf"
LOGIND_STATE="$TEST_TMP/logind-applied"

stub_bin "$STUBS" sudo 'exec "$@"'

# Stub bodies are literal shell, expanded when the stub runs, not now.
# shellcheck disable=SC2016
stub_bin "$STUBS" systemctl '
case "$*" in
  "reload systemd-logind")
    if [[ -f ${LOGIND_DROPIN:?} ]]; then : > "${LOGIND_STATE:?}"; else rm -f "${LOGIND_STATE:?}"; fi ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" busctl '
property="${!#}"
if [[ -f ${LOGIND_STATE:?} ]]; then echo "s \"ignore\""; exit 0; fi
case "$property" in
  HandleLidSwitch)              echo "s \"suspend\"" ;;
  HandleLidSwitchExternalPower) echo "s \"\"" ;;
  HandleLidSwitchDocked)        echo "s \"ignore\"" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

lid_setup() {
  env PATH="$STUBS:$PATH" LOGIND_DROPIN="$DROPIN" LOGIND_STATE="$LOGIND_STATE" \
      "$REPO_ROOT/bin/setup-no-lid-sleep" "$@" 2>&1
}

reloads() {
  if [[ -f "$STUBS/systemctl.log" ]]; then
    grep -c 'reload systemd-logind' "$STUBS/systemctl.log" || true
  else
    echo 0
  fi
}

# --- dry run changes nothing -----------------------------------------------

out="$(lid_setup --dry-run --yes)"

it "--dry-run does not install the drop-in"
assert_no_file "$DROPIN"

it "--dry-run does not reload logind"
assert_eq "0" "$(reloads)" "reloads"

it "--dry-run still says what it would do"
assert_contains "$out" "would write $DROPIN"

# --- real run ---------------------------------------------------------------

out="$(lid_setup --yes)"

it "installs the drop-in from config/"
if cmp -s "$REPO_ROOT/config/systemd/logind.conf.d/90-omarchy-scripts-lid-ignore.conf" "$DROPIN"; then
  pass
else
  fail "expected $DROPIN to match the config/ source"
fi

for key in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
  it "the drop-in sets $key=ignore"
  if grep -qx "$key=ignore" "$DROPIN"; then pass; else fail "$key=ignore missing"; fi
done

it "reloads logind rather than restarting it"
assert_eq "1" "$(reloads)" "reloads"

it "reports the applied state"
assert_contains "$out" "no longer suspends"

# --- second run is a no-op --------------------------------------------------

out2="$(lid_setup --yes)"

it "a second run skips the drop-in"
assert_contains "$out2" "already up to date"

it "a second run says logind already ignores the lid"
assert_contains "$out2" "logind already ignores the lid"

it "a second run does not reload logind"
assert_eq "1" "$(reloads)" "cumulative reloads"

# --- file current but never applied -----------------------------------------

rm -f "$LOGIND_STATE"
lid_setup --yes >/dev/null

it "retries the reload when logind has not picked the drop-in up"
assert_eq "2" "$(reloads)" "cumulative reloads"

# --- reversing --------------------------------------------------------------

out4="$(lid_setup --allow-lid-sleep --yes)"

it "--allow-lid-sleep removes the drop-in"
assert_no_file "$DROPIN"

it "--allow-lid-sleep reloads logind"
assert_eq "3" "$(reloads)" "cumulative reloads"

it "--allow-lid-sleep reports the stock behaviour is back"
assert_contains "$out4" "suspends again"

it "--allow-lid-sleep a second time changes nothing"
assert_contains "$(lid_setup --allow-lid-sleep --yes)" "no lid override installed"

# --- argument handling ------------------------------------------------------

it "help text is available without touching the system"
assert_contains "$(lid_setup --help)" "Usage: setup-no-lid-sleep"

it "rejects unknown arguments"
lid_setup --not-a-flag >/dev/null 2>&1
assert_status 1 $?

finish

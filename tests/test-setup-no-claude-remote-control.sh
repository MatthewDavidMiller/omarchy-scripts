#!/usr/bin/env bash
# bin/setup-no-claude-remote-control — against a throwaway HOME. The script
# only rewrites a JSON file, so there is nothing to stub: the fake HOME is the
# whole fixture, and the assertions read the settings file back.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

FAKE_HOME="$(make_fake_home)"
SETTINGS="$FAKE_HOME/.claude/settings.json"

mkdir -p "$FAKE_HOME/.claude"
cat > "$SETTINGS" <<'JSON'
{
  "model": "opus",
  "theme": "dark"
}
JSON

remote_control_setup() {
  env HOME="$FAKE_HOME" "$REPO_ROOT/bin/setup-no-claude-remote-control" "$@" 2>&1
}

# setting <file> <key> — the key's JSON value, or `absent`.
setting() {
  python - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    settings = json.load(handle)
value = settings.get(sys.argv[2], "absent")
print(value if value == "absent" else json.dumps(value))
PY
}

# --- dry run changes nothing ------------------------------------------------

out="$(remote_control_setup --dry-run --yes)"

it "--dry-run leaves the settings file untouched"
assert_eq "absent" "$(setting "$SETTINGS" disableRemoteControl)" "disableRemoteControl"

it "--dry-run still says what it would do"
assert_contains "$out" "would write $SETTINGS"

it "--dry-run reports Remote Control as still allowed"
assert_contains "$out" "remote control: allowed"

# --- real run ---------------------------------------------------------------

out="$(remote_control_setup --yes)"

it "sets disableRemoteControl, the switch that closes every entry point"
assert_eq "true" "$(setting "$SETTINGS" disableRemoteControl)" "disableRemoteControl"

it "leaves the other settings alone"
assert_eq '"opus"' "$(setting "$SETTINGS" model)" "model"

it "backs the old file up before rewriting it"
backups=("$SETTINGS".bak.*)
if [[ -f "${backups[0]}" ]]; then pass; else fail "expected a .bak.<timestamp> copy"; fi

it "the backup is the file as it was"
assert_eq "absent" "$(setting "${backups[0]}" disableRemoteControl)" "backed-up disableRemoteControl"

it "reports the resulting state"
assert_contains "$out" "remote control: disabled (disableRemoteControl: true)"

# --- second run is a no-op --------------------------------------------------

before="$(cat "$SETTINGS")"
out2="$(remote_control_setup --yes)"

it "a second run skips"
assert_contains "$out2" "Remote Control already disabled"

it "a second run changes nothing"
assert_eq "$before" "$(cat "$SETTINGS")" "settings file"

# --- reversing --------------------------------------------------------------

out3="$(remote_control_setup --allow-remote-control --yes)"

it "--allow-remote-control drops the setting"
assert_eq "absent" "$(setting "$SETTINGS" disableRemoteControl)" "disableRemoteControl"

it "--allow-remote-control keeps the rest of the file"
assert_eq '"dark"' "$(setting "$SETTINGS" theme)" "theme"

it "--allow-remote-control says the setting is gone"
assert_contains "$out3" "setting is gone"

it "--allow-remote-control a second time changes nothing"
assert_contains "$(remote_control_setup --allow-remote-control --yes)" "already unset"

# --- a machine with no Claude settings yet ----------------------------------

BARE_HOME="$(make_fake_home)"
bare_out="$(env HOME="$BARE_HOME" \
  "$REPO_ROOT/bin/setup-no-claude-remote-control" --yes 2>&1)"

it "creates the settings file when there is none"
assert_file "$BARE_HOME/.claude/settings.json"

it "the created file disables Remote Control and nothing else"
assert_eq '{"disableRemoteControl": true}' \
  "$(python -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' \
     "$BARE_HOME/.claude/settings.json")" "created settings"

it "says it wrote the file"
assert_contains "$bare_out" "wrote $BARE_HOME/.claude/settings.json"

# --- CLAUDE_SETTINGS_FILE ---------------------------------------------------

ALT="$TEST_TMP/alt-settings.json"
printf '{"model": "opus"}\n' > "$ALT"
env HOME="$FAKE_HOME" CLAUDE_SETTINGS_FILE="$ALT" \
  "$REPO_ROOT/bin/setup-no-claude-remote-control" --yes >/dev/null 2>&1

it "CLAUDE_SETTINGS_FILE redirects the write"
assert_eq "true" "$(setting "$ALT" disableRemoteControl)" "disableRemoteControl"

it "CLAUDE_SETTINGS_FILE means the default path is left alone"
assert_eq "absent" "$(setting "$SETTINGS" disableRemoteControl)" "default-path setting"

# --- a settings file this script must not clobber ---------------------------

BAD="$TEST_TMP/bad-settings.json"
printf '{ not json at all' > "$BAD"
bad_out="$(env HOME="$FAKE_HOME" CLAUDE_SETTINGS_FILE="$BAD" \
  "$REPO_ROOT/bin/setup-no-claude-remote-control" --yes 2>&1)"
bad_status=$?

it "refuses a settings file that is not valid JSON"
assert_status 1 $bad_status

it "says which file to fix"
assert_contains "$bad_out" "Fix or move $BAD"

it "leaves the unparseable file exactly as it was"
assert_eq '{ not json at all' "$(cat "$BAD")" "bad settings file"

it "refuses a settings file that is not a JSON object"
printf '[1, 2]' > "$BAD"
env HOME="$FAKE_HOME" CLAUDE_SETTINGS_FILE="$BAD" \
  "$REPO_ROOT/bin/setup-no-claude-remote-control" --yes >/dev/null 2>&1
assert_status 1 $?

# --- argument handling ------------------------------------------------------

it "help text is available without touching the system"
assert_contains "$(remote_control_setup --help)" "Usage: setup-no-claude-remote-control"

it "rejects unknown arguments"
remote_control_setup --not-a-flag >/dev/null 2>&1
assert_status 1 $?

finish

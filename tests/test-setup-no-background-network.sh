#!/usr/bin/env bash
# bin/setup-no-background-network — Omarchy widgets, VS Code/RPi settings,
# and exact legacy OpenSnitch deny cleanup against isolated fixtures.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

HOME_DIR="$(make_fake_home)"
STUBS="$TEST_TMP/stubs"
SCRIPT="$REPO_ROOT/bin/setup-no-background-network"
SHELL_CONFIG="$HOME_DIR/.config/omarchy/shell.json"
CODE_SETTINGS="$HOME_DIR/.config/Code/User/settings.json"
SYNC_MARKER="$HOME_DIR/.local/state/omarchy-scripts/vscode-sync-disabled"
RPI_SETTINGS="$HOME_DIR/.config/Raspberry Pi/Raspberry Pi Imager.conf"
RULES="$TEST_TMP/rules"

mkdir -p "$(dirname "$SHELL_CONFIG")" "$(dirname "$CODE_SETTINGS")" \
  "$(dirname "$RPI_SETTINGS")" "$RULES"

cat > "$SHELL_CONFIG" <<'JSON'
{
  "version": 1,
  "bar": {
    "layout": {
      "left": [{"id": "omarchy.menu"}],
      "center": [{"id": "omarchy.weather"}],
      "right": [{"id": "omarchy.agents"}, {"id": "omarchy.network"}]
    }
  }
}
JSON

cat > "$CODE_SETTINGS" <<'JSON'
{
  // VS Code settings are JSONC, not necessarily strict JSON.
  "update.mode": "none",
  "workbench.colorTheme": "Tokyo Night",
  "test.url": "https://example.test/a//b",
}
JSON

cat > "$RPI_SETTINGS" <<'INI'
[General]
x=15
y=47

[caching]
lastFileName=/tmp/lastdownload.cache
INI

for file in \
  deny-12h-simple-usr-bin-curl.json \
  deny-12h-simple-usr-bin-python3-14.json \
  deny-12h-simple-usr-bin-rpi-imager.json \
  deny-12h-simple-usr-share-code-code.json
do
  printf '{"name":"%s","action":"deny"}\n' "${file%.json}" > "$RULES/$file"
done
printf '{"name":"keep-me","action":"allow"}\n' > "$RULES/unrelated.json"

# The real command updates shell.json through the running Omarchy shell. This
# stub performs the equivalent fixture edit so a second run can prove it is a
# no-op.
# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
if [[ "$1 $2" == "plugin disable" ]]; then
  python - "$OMARCHY_SHELL_CONFIG" "$3" <<"PY"
import json, sys
path, target = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)
layout = config.get("bar", {}).get("layout", {})
for key, entries in layout.items():
    layout[key] = [entry for entry in entries if (entry.get("id") if isinstance(entry, dict) else entry) != target]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY
fi'
stub_bin "$STUBS" code ':'
stub_bin "$STUBS" rpi-imager ':'
stub_bin "$STUBS" sudo 'exec "$@"'

run_setup() {
  env HOME="$HOME_DIR" PATH="$STUBS:$PATH" \
    OMARCHY_SHELL_CONFIG="$SHELL_CONFIG" \
    VSCODE_SETTINGS_FILE="$CODE_SETTINGS" \
    VSCODE_SYNC_MARKER="$SYNC_MARKER" \
    RPI_IMAGER_SETTINGS_FILE="$RPI_SETTINGS" \
    OPEN_SNITCH_RULES_DIR="$RULES" \
    "$SCRIPT" "$@" 2>&1
}

cp "$SHELL_CONFIG" "$TEST_TMP/shell.before"
cp "$CODE_SETTINGS" "$TEST_TMP/code.before"
cp "$RPI_SETTINGS" "$TEST_TMP/rpi.before"
dry_out="$(run_setup --dry-run --yes)"

it "dry-run reports plugin disablement"
assert_contains "$dry_out" "omarchy plugin disable omarchy.weather"

it "dry-run reports rule backups and deletion"
assert_contains "$dry_out" "sudo cp -a -- $RULES/deny-12h-simple-usr-bin-curl.json"

it "dry-run leaves Omarchy config unchanged"
assert_eq "$(cat "$TEST_TMP/shell.before")" "$(cat "$SHELL_CONFIG")"

it "dry-run leaves VS Code settings unchanged"
assert_eq "$(cat "$TEST_TMP/code.before")" "$(cat "$CODE_SETTINGS")"

it "dry-run leaves RPi settings unchanged"
assert_eq "$(cat "$TEST_TMP/rpi.before")" "$(cat "$RPI_SETTINGS")"

it "dry-run leaves deny rules present"
assert_file "$RULES/deny-12h-simple-usr-bin-curl.json"

out="$(run_setup --yes)"

it "reports each removed deny rule and its backup"
assert_contains "$out" "removed deny-12h-simple-usr-bin-curl.json (backup:"

it "disables both Omarchy polling widgets"
assert_eq "plugin disable omarchy.weather
plugin disable omarchy.agents" "$(cat "$STUBS/omarchy.log")"

it "preserves unrelated Omarchy widgets"
assert_file_contains "$SHELL_CONFIG" "omarchy.network"

it "turns off VS Code telemetry"
assert_file_contains "$CODE_SETTINGS" '"telemetry.telemetryLevel": "off"'

it "turns off VS Code extension update checks"
assert_file_contains "$CODE_SETTINGS" '"extensions.autoCheckUpdates": false'

it "preserves unrelated VS Code settings"
assert_file_contains "$CODE_SETTINGS" '"workbench.colorTheme": "Tokyo Night"'

it "parses JSONC without corrupting URLs"
assert_file_contains "$CODE_SETTINGS" '"test.url": "https://example.test/a//b"'

it "turns off VS Code Settings Sync"
assert_file_contains "$STUBS/code.log" "--sync off"

it "records successful Settings Sync disablement"
assert_file "$SYNC_MARKER"

it "turns off Raspberry Pi Imager telemetry"
assert_file_contains "$RPI_SETTINGS" "telemetry=false"

it "preserves Raspberry Pi Imager cache settings"
assert_file_contains "$RPI_SETTINGS" "lastFileName=/tmp/lastdownload.cache"

it "removes all four reviewed broad denies"
if compgen -G "$RULES/deny-12h-*.json" >/dev/null; then
  fail "legacy deny rule remains"
else
  pass
fi

it "backs up every removed deny"
count="$(find "$RULES" -name 'deny-12h-*.json.bak.*' | wc -l)"
assert_eq "4" "$count" "deny backup count"

it "preserves unrelated OpenSnitch rules"
assert_file "$RULES/unrelated.json"

it "backs up edited VS Code settings"
if compgen -G "$CODE_SETTINGS.bak.*" >/dev/null; then pass; else fail "VS Code backup not found"; fi

it "backs up edited Raspberry Pi Imager settings"
if compgen -G "$RPI_SETTINGS.bak.*" >/dev/null; then pass; else fail "RPi backup not found"; fi

omarchy_calls="$(wc -l < "$STUBS/omarchy.log")"
code_calls="$(wc -l < "$STUBS/code.log")"
sudo_calls="$(wc -l < "$STUBS/sudo.log")"
second_out="$(run_setup --yes)"

it "second run recognizes disabled Omarchy widgets"
assert_contains "$second_out" "omarchy.weather already disabled"

it "second run recognizes Settings Sync state"
assert_contains "$second_out" "Settings Sync already disabled"

it "second run recognizes absent denies"
assert_contains "$second_out" "deny rules already absent"

it "second run issues no additional mutation commands"
assert_eq "$omarchy_calls $code_calls $sudo_calls" \
  "$(wc -l < "$STUBS/omarchy.log") $(wc -l < "$STUBS/code.log") $(wc -l < "$STUBS/sudo.log")" \
  "command counts"

# --- a root-owned settings file ---------------------------------------------
#
# rpi-imager needs root to write a card, so it is habitually launched with sudo
# and leaves its QSettings file unwritable by the user who owns the directory.
# The setup has to repair that rather than die on a bare "Permission denied".

ROOT_OWNED_HOME="$(make_fake_home)"
ROOT_OWNED="$ROOT_OWNED_HOME/.config/Raspberry Pi/Raspberry Pi Imager.conf"
mkdir -p "$(dirname "$ROOT_OWNED")"
printf '[General]\nx=15\n' > "$ROOT_OWNED"
chmod 0444 "$ROOT_OWNED"

reclaim_out="$(env HOME="$ROOT_OWNED_HOME" PATH="$STUBS:$PATH" \
  OMARCHY_SHELL_CONFIG="$SHELL_CONFIG" \
  VSCODE_SETTINGS_FILE="$ROOT_OWNED_HOME/.config/Code/User/settings.json" \
  VSCODE_SYNC_MARKER="$ROOT_OWNED_HOME/.local/state/omarchy-scripts/vscode-sync-disabled" \
  RPI_IMAGER_SETTINGS_FILE="$ROOT_OWNED" \
  OPEN_SNITCH_RULES_DIR="$RULES" \
  "$SCRIPT" --yes 2>&1)"
reclaim_status=$?

it "survives an unwritable Raspberry Pi Imager settings file"
assert_status 0 "$reclaim_status"

it "reports the ownership problem before repairing it"
assert_contains "$reclaim_out" "not writable by"

it "still writes the telemetry setting afterwards"
assert_file_contains "$ROOT_OWNED" "telemetry=false"

it "preserves the unrelated value in the reclaimed file"
assert_file_contains "$ROOT_OWNED" "x=15"

it "help is available without touching configuration"
assert_contains "$(run_setup --help)" "Usage: setup-no-background-network"

it "unknown options fail"
run_setup --not-an-option >/dev/null 2>&1
assert_status 1 $?

finish

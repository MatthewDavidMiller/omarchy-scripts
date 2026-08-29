#!/usr/bin/env bash
# bin/export-opensnitch-rules — selection, validation, portability checks, and
# idempotent writes against throwaway source and local export directories.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RULES="$TEST_TMP/rules"
EXPORTS="$TEST_TMP/exports"
STATE="$TEST_TMP/state/opensnitch-export-dir"
mkdir -p "$RULES" "$EXPORTS"

make_rule() {
  local file="$1" name="$2" action="$3" duration="$4" enabled="$5" operand="$6" data="$7"
  python - "$RULES/$file" "$name" "$action" "$duration" "$enabled" "$operand" "$data" <<'PY'
import json, sys
path, name, action, duration, enabled, operand, data = sys.argv[1:]
rule = {
    "name": name,
    "enabled": enabled == "true",
    "action": action,
    "duration": duration,
    "precedence": False,
    "operator": {"type": "simple", "operand": operand, "data": data, "sensitive": False},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(rule, handle)
PY
}

make_rule browser.json "allow-firefox" allow always true process.path /usr/lib/firefox/firefox
make_rule uid.json "allow-private-service" allow always true user.id 1000
make_rule temporary.json "allow-once" allow once true process.path /usr/bin/curl
make_rule denied.json "deny-tracker" deny always true dest.host tracker.example
make_rule disabled.json "allow-disabled" allow always false process.path /usr/bin/false

exporter() {
  HOME="$TEST_TMP/home" OPEN_SNITCH_RULES_DIR="$RULES" \
    OPEN_SNITCH_EXPORT_STATE_FILE="$STATE" \
    OPEN_SNITCH_EXPORT_DIR="${OPEN_SNITCH_EXPORT_DIR:-$EXPORTS}" \
    "$REPO_ROOT/bin/export-opensnitch-rules" "$@" 2>&1
}

out="$(exporter allow-firefox)"

it "exports an exact permanent allow rule by name"
assert_contains "$out" "exported rule ready"

exported=("$EXPORTS"/omarchy-shared-allow-firefox-*.json)
it "uses a stable portable filename"
assert_file "${exported[0]}"

it "preserves the selected rule semantics"
assert_file_contains "${exported[0]}" '"data": "/usr/lib/firefox/firefox"'

before="$(cat "${exported[0]}")"
out2="$(exporter browser.json)"

it "accepts an exact source filename"
assert_contains "$out2" "already up to date"

it "re-exporting the same rule is byte-idempotent"
assert_eq "$before" "$(cat "${exported[0]}")" "exported rule"

it "refuses temporary rules"
exporter allow-once >/dev/null 2>&1
assert_status 1 $?

deny_out="$(exporter deny-tracker)"
it "exports a permanent deny rule"
assert_contains "$deny_out" "exported rule ready"

it "warns that a deny is only portable with the allows it complements"
assert_contains "$deny_out" "portable only with the allows it complements"

it "refuses disabled rules"
exporter allow-disabled >/dev/null 2>&1
assert_status 1 $?

machine_out="$(exporter allow-private-service 2>&1)"
machine_status=$?
it "rejects machine-specific rules by default"
assert_status 1 "$machine_status"
it "explains why a rule is machine-specific"
assert_contains "$machine_out" "UID"

it "exports a reviewed machine-specific rule with the explicit override"
assert_contains "$(exporter --allow-machine-specific allow-private-service)" "machine-specific fields"

CLI_EXPORTS="$TEST_TMP/cli-exports"
it "accepts an explicit local output directory"
assert_contains "$(OPEN_SNITCH_EXPORT_DIR='' exporter --output-dir "$CLI_EXPORTS" allow-firefox)" "$CLI_EXPORTS"
assert_file "$CLI_EXPORTS/${exported[0]##*/}"

it "remembers the directory of the last export"
assert_eq "$CLI_EXPORTS" "$(cat "$STATE")" "remembered export directory"

DRY_EXPORTS="$TEST_TMP/dry-exports"
mkdir -p "$DRY_EXPORTS"
dry_out="$(OPEN_SNITCH_EXPORT_DIR="$DRY_EXPORTS" exporter --dry-run allow-firefox)"
it "--dry-run previews the local write"
assert_contains "$dry_out" "would write"
it "--dry-run writes no rule"
if find "$DRY_EXPORTS" -type f | grep -q .; then fail "dry run wrote a rule"; else pass; fi

it "--dry-run leaves the remembered directory alone"
assert_eq "$CLI_EXPORTS" "$(cat "$STATE")" "remembered export directory"

it "names the remembered directory when no destination is given"
no_dir_out="$(HOME="$TEST_TMP/home" OPEN_SNITCH_RULES_DIR="$RULES" \
  OPEN_SNITCH_EXPORT_STATE_FILE="$STATE" \
  "$REPO_ROOT/bin/export-opensnitch-rules" allow-firefox 2>&1)"
assert_contains "$no_dir_out" "last used: $CLI_EXPORTS"

it "--yes reuses the remembered directory without prompting"
yes_out="$(HOME="$TEST_TMP/home" OPEN_SNITCH_RULES_DIR="$RULES" \
  OPEN_SNITCH_EXPORT_STATE_FILE="$STATE" \
  "$REPO_ROOT/bin/export-opensnitch-rules" --yes allow-firefox 2>&1)"
assert_contains "$yes_out" "reusing the last export directory: $CLI_EXPORTS"

it "rejects export destinations inside the project"
OPEN_SNITCH_EXPORT_DIR='' exporter --output-dir "$REPO_ROOT/config/opensnitch/rules" allow-firefox >/dev/null 2>&1
assert_status 1 $?

it "requires exact rule names or filenames"
exporter no-such-rule >/dev/null 2>&1
assert_status 1 $?

it "help text is available without an installed rules directory"
assert_contains "$("$REPO_ROOT/bin/export-opensnitch-rules" --help)" "permanent allow and deny rules"
assert_contains "$("$REPO_ROOT/bin/export-opensnitch-rules" --help)" "--output-dir"

# Free text from the GUI reaches the catalog, which is tab-separated.
make_rule newline.json "allow-multiline" allow always true process.path \
  "$(printf '/usr/bin/x\nallow-injected\tyes')"

it "exports a rule whose data contains a tab or newline"
assert_contains "$(exporter allow-multiline)" "exported rule ready"

it "does not let embedded whitespace invent a second rule"
exporter allow-injected >/dev/null 2>&1
assert_status 1 $?

it "keeps the neighbouring rules selectable"
assert_contains "$(exporter allow-firefox)" "already up to date"

make_rule twin-a.json "allow-twin" allow always true process.path /usr/bin/twin-a
make_rule twin-b.json "allow-twin" allow always true process.path /usr/bin/twin-b

it "refuses to export two same-named rules onto one filename"
twin_out="$(exporter allow-twin)"
assert_contains "$twin_out" "share the rule name"

it "warns about the shared filename while both rules are visible"
assert_contains "$twin_out" "share a rule name and one export filename"

# A home directory is not always under /home/.
ALT_HOME="$TEST_TMP/elsewhere"
mkdir -p "$ALT_HOME"
make_rule althome.json "allow-alt-home" allow always true process.path "$ALT_HOME/.local/bin/tool"

it "flags a home path even when HOME is not under /home"
alt_out="$(HOME="$ALT_HOME" OPEN_SNITCH_RULES_DIR="$RULES" \
  OPEN_SNITCH_EXPORT_STATE_FILE="$STATE" OPEN_SNITCH_EXPORT_DIR="$EXPORTS" \
  "$REPO_ROOT/bin/export-opensnitch-rules" allow-alt-home 2>&1)"
assert_contains "$alt_out" "home path"

it "rejects unknown arguments"
"$REPO_ROOT/bin/export-opensnitch-rules" --not-an-option >/dev/null 2>&1
assert_status 1 $?

finish

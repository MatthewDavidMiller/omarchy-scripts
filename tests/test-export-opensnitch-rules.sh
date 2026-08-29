#!/usr/bin/env bash
# bin/export-opensnitch-rules — selection, validation, portability checks, and
# idempotent writes against throwaway source and project directories.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RULES="$TEST_TMP/rules"
EXPORTS="$TEST_TMP/exports"
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
    OPEN_SNITCH_SHARED_RULES_DIR="${OPEN_SNITCH_SHARED_RULES_DIR:-$EXPORTS}" \
    "$REPO_ROOT/bin/export-opensnitch-rules" "$@" 2>&1
}

out="$(exporter allow-firefox)"

it "exports an exact permanent allow rule by name"
assert_contains "$out" "shared rule ready"

exported=("$EXPORTS"/omarchy-shared-allow-firefox-*.json)
it "uses a stable repository-managed filename"
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

it "refuses deny rules"
exporter deny-tracker >/dev/null 2>&1
assert_status 1 $?

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

DRY_EXPORTS="$TEST_TMP/dry-exports"
mkdir -p "$DRY_EXPORTS"
dry_out="$(OPEN_SNITCH_SHARED_RULES_DIR="$DRY_EXPORTS" exporter --dry-run allow-firefox)"
it "--dry-run previews the project write"
assert_contains "$dry_out" "would write"
it "--dry-run writes no rule"
if find "$DRY_EXPORTS" -type f | grep -q .; then fail "dry run wrote a rule"; else pass; fi

it "requires exact rule names or filenames"
exporter no-such-rule >/dev/null 2>&1
assert_status 1 $?

it "help text is available without an installed rules directory"
assert_contains "$("$REPO_ROOT/bin/export-opensnitch-rules" --help)" "permanent allow rules"

it "rejects unknown arguments"
"$REPO_ROOT/bin/export-opensnitch-rules" --not-an-option >/dev/null 2>&1
assert_status 1 $?

finish

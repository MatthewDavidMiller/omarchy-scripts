#!/usr/bin/env bash
# opensnitch-rulectl: argument handling, rule parsing, and the promise that a
# dry run never touches the UI socket.
#
# The socket half of this tool needs a live opensnitchd to talk to, so it is
# not exercised here. Everything that can be checked without one is.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RULECTL="$REPO_ROOT/bin/opensnitch-rulectl"

if ! python -c "import grpc" 2>/dev/null; then
  it "opensnitch-rulectl tests need python-grpcio"
  printf '  %s-%s skipped: python-grpcio not installed\n' "$T_DIM" "$T_RESET"
  TESTS_RUN=$((TESTS_RUN - 1))
  finish
  exit 0
fi

WORK="$TEST_TMP/rulectl"
mkdir -p "$WORK"

valid_rule() {
  cat > "$1" <<'JSON'
{
  "action": "allow",
  "created": "2026-08-29T16:00:00.000000Z",
  "description": "A test rule.",
  "duration": "always",
  "enabled": true,
  "name": "500-test-rule",
  "nolog": false,
  "operator": {
    "type": "list",
    "operand": "list",
    "data": "",
    "sensitive": false,
    "list": [
      {"type": "simple", "operand": "process.path", "data": "/usr/bin/true", "sensitive": false, "list": []},
      {"type": "simple", "operand": "dest.port", "data": "443", "sensitive": false, "list": []}
    ]
  },
  "precedence": true
}
JSON
}

# --- usage -----------------------------------------------------------------

it "--help exits 0 and lists every command"
out="$("$RULECTL" --help 2>&1)"; status=$?
if [[ $status -eq 0 ]] \
  && [[ "$out" == *list* && "$out" == *show* && "$out" == *apply* \
     && "$out" == *delete* && "$out" == *watch* ]]; then
  pass
else
  fail "expected help listing all commands, exit 0" "exit $status" "${out:0:300}"
fi

it "a missing subcommand is an error, not a socket connection"
out="$("$RULECTL" 2>&1)"; status=$?
assert_status 2 "$status"

it "refuses to run as root"
assert_file_contains "$RULECTL" "Run this as your normal user, not root"

# --- dry run ---------------------------------------------------------------

# The socket is deliberately bogus. Anything that tries to use it fails loudly,
# which is the point: a dry run must not get that far.
export OPEN_SNITCH_UI_SOCKET="$WORK/definitely-not-a-socket"

it "--dry-run apply reports the rule without touching the socket"
valid_rule "$WORK/500-test-rule.json"
out="$("$RULECTL" -n apply "$WORK/500-test-rule.json" 2>&1)"; status=$?
if [[ $status -eq 0 && "$out" == *"would install 500-test-rule"* ]]; then
  pass
else
  fail "expected a dry-run report" "exit $status" "$out"
fi

it "--dry-run leaves no socket behind"
assert_no_file "$WORK/definitely-not-a-socket"

it "--dry-run delete reports the rule name"
out="$("$RULECTL" -n delete some-rule 2>&1)"
assert_contains "$out" "would delete some-rule"

# --- rule parsing ----------------------------------------------------------

it "rejects a file that is not JSON"
printf 'not json at all\n' > "$WORK/bad.json"
out="$("$RULECTL" -n apply "$WORK/bad.json" 2>&1)"; status=$?
if [[ $status -ne 0 && "$out" == *"not valid JSON"* ]]; then
  pass
else
  fail "expected a JSON parse error" "exit $status" "$out"
fi

it "rejects a JSON array where a rule object belongs"
printf '[]\n' > "$WORK/array.json"
out="$("$RULECTL" -n apply "$WORK/array.json" 2>&1)"; status=$?
if [[ $status -ne 0 && "$out" == *"expected one rule object"* ]]; then
  pass
else
  fail "expected an object-shape error" "exit $status" "$out"
fi

it "rejects a rule with no name"
printf '{"action":"allow","duration":"always"}\n' > "$WORK/noname.json"
out="$("$RULECTL" -n apply "$WORK/noname.json" 2>&1)"; status=$?
if [[ $status -ne 0 && "$out" == *"no name"* ]]; then
  pass
else
  fail "expected a missing-name error" "exit $status" "$out"
fi

it "reports a missing file rather than crashing"
out="$("$RULECTL" -n apply "$WORK/absent.json" 2>&1)"; status=$?
if [[ $status -ne 0 && "$out" == *"no such file"* ]]; then
  pass
else
  fail "expected a missing-file error" "exit $status" "$out"
fi

it "warns when the filename will not match the installed name"
valid_rule "$WORK/wrong-name.json"
out="$("$RULECTL" -n apply "$WORK/wrong-name.json" 2>&1)"
assert_contains "$out" "will be installed as 500-test-rule.json"

# --- JSON round-trip -------------------------------------------------------
#
# apply writes what the daemon later hands back to show, so the two conversions
# have to agree. A field lost here is a rule silently weakened on reinstall.

it "a rule survives the JSON -> proto -> JSON round trip"
round_trip="$(python - "$RULECTL" "$WORK/500-test-rule.json" <<'PY'
import importlib.util, json, sys

spec = importlib.util.spec_from_loader("rulectl", None)
module = importlib.util.module_from_spec(spec)
module.__dict__["__name__"] = "rulectl"
exec(compile(open(sys.argv[1]).read(), sys.argv[1], "exec"), module.__dict__)

original = json.load(open(sys.argv[2]))
result = module.rule_to_json(module.rule_from_json(original, "test"))
for field in ("name", "action", "duration", "enabled", "precedence", "description"):
    if original[field] != result[field]:
        print(f"FAIL {field}: {original[field]!r} != {result[field]!r}")
        raise SystemExit(0)
if original["created"] != result["created"]:
    print(f"FAIL created: {original['created']!r} != {result['created']!r}")
    raise SystemExit(0)
operands = [op["operand"] for op in result["operator"]["list"]]
if operands != ["process.path", "dest.port"]:
    print(f"FAIL operands: {operands}")
    raise SystemExit(0)
if result["operator"]["data"] != "":
    print(f"FAIL list operator data should stay empty: {result['operator']['data']!r}")
    raise SystemExit(0)
print("OK")
PY
)"
assert_eq "OK" "$round_trip" "round trip"

finish

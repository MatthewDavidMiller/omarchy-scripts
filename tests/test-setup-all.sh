#!/usr/bin/env bash
# bin/setup-all — discovery, ordering, selection, and failure reporting.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

repo="$(make_test_repo)"
rm -f "$repo/bin/setup-ssh-agent"          # keep the fixtures deterministic
make_setup_script "$repo/bin" setup-beta  50 "beta script"
make_setup_script "$repo/bin" setup-alpha 10 "alpha script"
make_setup_script "$repo/bin" setup-omega 90 "omega script"

setup_all() { "$repo/bin/setup-all" "$@" 2>&1; }

it "--list orders by the order: header, not alphabetically"
listed="$(setup_all --list | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'setup-[a-z]*' | tr '\n' ' ')"
assert_eq "setup-alpha setup-beta setup-omega " "$listed"

it "--list shows each script's description"
assert_contains "$(setup_all --list)" "alpha script"

it "scripts with no order: header default to 50"
make_setup_script "$repo/bin" setup-noorder 50 "no order"
sed -i '/^# order:/d' "$repo/bin/setup-noorder"
assert_contains "$(setup_all --list | sed 's/\x1b\[[0-9;]*m//g')" " 50  setup-noorder"
rm -f "$repo/bin/setup-noorder"

it "runs every script when given none to skip"
out="$(setup_all --no-tui)"
assert_contains "$out" "All 3 script(s) completed"

it "passes --dry-run through to each script"
assert_contains "$(setup_all --no-tui --dry-run)" "[setup-alpha] args: --dry-run"

it "passes --yes through to each script"
assert_contains "$(setup_all --no-tui --yes)" "[setup-alpha] args: --yes"

it "--only runs just the named script"
out="$(setup_all --no-tui --only alpha)"
assert_contains "$out" "All 1 script(s) completed"

it "--only accepts the setup- prefix too"
assert_contains "$(setup_all --no-tui --only setup-alpha)" "[setup-alpha]"

it "--only accepts a comma-separated list"
assert_contains "$(setup_all --no-tui --only alpha,omega)" "All 2 script(s) completed"

it "--only with an unknown name is an error, not a silent no-op"
setup_all --no-tui --only nosuchscript >/dev/null 2>&1
assert_status 1 $?

it "--skip excludes the named script"
assert_not_contains "$(setup_all --no-tui --skip alpha)" "[setup-alpha]"

it "a non-executable script is skipped with a warning, not ignored"
touch "$repo/bin/setup-notexec" && chmod -x "$repo/bin/setup-notexec"
assert_contains "$(setup_all --list)" "setup-notexec is not executable"
rm -f "$repo/bin/setup-notexec"

it "setup-all does not try to run itself"
assert_not_contains "$(setup_all --list)" "setup-all "

it "non-setup scripts in bin/ are ignored"
printf '#!/usr/bin/env bash\necho nope\n' > "$repo/bin/lint" && chmod +x "$repo/bin/lint"
assert_not_contains "$(setup_all --list)" "bin/lint"

# --- failure handling ---

make_setup_script "$repo/bin" setup-broken 20 "fails on purpose" 3

it "a failing script is reported in the summary"
out="$(setup_all --no-tui)"
assert_contains "$out" "setup-broken — failed (exit 3)"

it "a failure does not stop the remaining scripts"
assert_contains "$out" "[setup-omega]"

it "the run exits non-zero when a script fails"
setup_all --no-tui >/dev/null 2>&1
assert_status 1 $?

it "--fail-fast stops after the first failure"
assert_not_contains "$(setup_all --no-tui --fail-fast)" "[setup-omega]"

it "--fail-fast still reports what ran before the failure"
assert_contains "$(setup_all --no-tui --fail-fast)" "ok setup-alpha"

rm -f "$repo/bin/setup-broken"

# --- TUI dispatch ---

it "a piped invocation gets the plain runner, never the menu"
out="$(setup_all </dev/null)"
assert_contains "$out" "All 3 script(s) completed"

it "--tui without a terminal is refused rather than hanging"
out="$(setup_all --tui </dev/null 2>&1)"
assert_contains "$out" "interactive terminal"

it "descriptions containing commas are sanitised for the menu"
make_setup_script "$repo/bin" setup-comma 60 "one, two"
assert_contains "$(setup_all --list)" "one · two"

finish

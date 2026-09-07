#!/usr/bin/env bash
# bin/setup-all — discovery, ordering, selection, and failure reporting.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

repo="$(make_test_repo)"
# Drop every real setup script: only the fixtures below should be discovered,
# so these tests neither run real system commands nor change when bin/ grows.
find "$repo/bin" -maxdepth 1 -name 'setup-*' ! -name 'setup-all' -delete
make_setup_script "$repo/bin" setup-beta  50 "beta script"
make_setup_script "$repo/bin" setup-alpha 10 "alpha script"
make_setup_script "$repo/bin" setup-omega 90 "omega script"
make_setup_script "$repo/bin" setup-optional 95 "optional script"
# A leftover header from when setup-all had an opt-in tier. It must not hide
# the script any more: the whole point of dropping the mechanism is that
# nothing in bin/ can remove itself from --list and from the menu.
sed -i '4i# default: no' "$repo/bin/setup-optional"

setup_all() { "$repo/bin/setup-all" "$@" 2>&1; }

it "--list orders by the order: header, not alphabetically"
listed="$(setup_all --list | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'setup-[a-z]*' | tr '\n' ' ')"
assert_eq "setup-alpha setup-beta setup-omega setup-optional " "$listed"

it "--list shows each script's description"
assert_contains "$(setup_all --list)" "alpha script"

it "scripts with no order: header default to 50"
make_setup_script "$repo/bin" setup-noorder 50 "no order"
sed -i '/^# order:/d' "$repo/bin/setup-noorder"
assert_contains "$(setup_all --list | sed 's/\x1b\[[0-9;]*m//g')" " 50  setup-noorder"
rm -f "$repo/bin/setup-noorder"

it "runs every script when given none to skip"
out="$(setup_all --no-tui)"
assert_contains "$out" "All 4 script(s) completed"

it "a stale default: no header no longer holds a script back"
assert_contains "$out" "[setup-optional]"

it "and no longer hides it from --list either"
assert_contains "$(setup_all --list)" "setup-optional"

# --skip is now the only way to hold a script back, which keeps the choice at
# the call site rather than in a header nobody reads.
it "--skip is what holds a script back now"
assert_not_contains "$(setup_all --no-tui --skip optional)" "[setup-optional]"

# --- one sudo prompt for the whole run -------------------------------------
# Eight real setup scripts shell out to sudo. Left alone each one prompts
# separately, so setup-all takes the credential once before the first script.

sudo_log="$TEST_TMP/sudo.calls"
sudo_stubs="$TEST_TMP/sudo-stubs"
# Counts -v calls and records them; `-n -v` fails until a bare `sudo -v` has
# run, which is what a real timestamp does.
# Stub bodies are literal shell, expanded when the stub runs, not now.
# shellcheck disable=SC2016
stub_bin "$sudo_stubs" sudo '
log="${FAKE_SUDO_LOG:?}"
stamp="${FAKE_SUDO_STAMP:?}"
if [[ "$1" == "-n" && "$2" == "-v" ]]; then
  [[ -f "$stamp" ]] || exit 1
  printf "refresh
" >> "$log"
  exit 0
fi
if [[ "$1" == "-v" ]]; then
  printf "prompt
" >> "$log"
  : > "$stamp"
  exit 0
fi
exec "$@"'

sudo_repo="$(make_test_repo)"
find "$sudo_repo/bin" -maxdepth 1 -name 'setup-*' ! -name 'setup-all' -delete
for n in one two three; do
  make_setup_script "$sudo_repo/bin" "setup-$n" 10 "$n script"
  # A real sudo call, so the script registers as needing a credential.
  sed -i '$i sudo true' "$sudo_repo/bin/setup-$n"
done

sudo_all() {
  : > "$sudo_log"
  rm -f "$TEST_TMP/sudo.stamp"
  env PATH="$sudo_stubs:$PATH" \
      FAKE_SUDO_LOG="$sudo_log" \
      FAKE_SUDO_STAMP="$TEST_TMP/sudo.stamp" \
      "$sudo_repo/bin/setup-all" "$@" 2>&1
}

out="$(sudo_all --no-tui)"

it "asks for the password once, not once per script"
assert_eq "1" "$(grep -c '^prompt$' "$sudo_log")" "sudo prompts"

it "says why it is asking before the first script runs"
assert_contains "$out" "One password for the whole run"

it "still runs every script"
assert_contains "$out" "All 3 script(s) completed"

it "does not ask again when a credential is already cached"
: > "$sudo_log"
: > "$TEST_TMP/sudo.stamp.keep"
env PATH="$sudo_stubs:$PATH" FAKE_SUDO_LOG="$sudo_log" \
    FAKE_SUDO_STAMP="$TEST_TMP/sudo.stamp.keep" \
    "$sudo_repo/bin/setup-all" --no-tui >/dev/null 2>&1
assert_eq "0" "$(grep -c '^prompt$' "$sudo_log")" "sudo prompts"

it "--dry-run never asks for a password"
sudo_all --no-tui --dry-run >/dev/null 2>&1
assert_eq "0" "$(grep -c '^prompt$' "$sudo_log")" "sudo prompts"

# A run that touches nothing privileged should not demand a password for it.
nosudo_repo="$(make_test_repo)"
find "$nosudo_repo/bin" -maxdepth 1 -name 'setup-*' ! -name 'setup-all' -delete
make_setup_script "$nosudo_repo/bin" setup-plain 10 "plain script"
# Names sudo only in a comment, which must not count as needing one.
sed -i '$i # this one deliberately avoids sudo' "$nosudo_repo/bin/setup-plain"

it "does not ask when no selected script uses sudo"
: > "$sudo_log"
env PATH="$sudo_stubs:$PATH" FAKE_SUDO_LOG="$sudo_log" \
    FAKE_SUDO_STAMP="$TEST_TMP/sudo.stamp.none" \
    "$nosudo_repo/bin/setup-all" --no-tui >/dev/null 2>&1
assert_eq "0" "$(grep -c '^prompt$' "$sudo_log")" "sudo prompts"

it "warns rather than pretending when sudo caches nothing"
# A sudo whose timestamp never takes: `-n -v` always fails.
# shellcheck disable=SC2016
stub_bin "$sudo_stubs" sudo '
log="${FAKE_SUDO_LOG:?}"
if [[ "$1" == "-n" && "$2" == "-v" ]]; then exit 1; fi
if [[ "$1" == "-v" ]]; then printf "prompt
" >> "$log"; exit 0; fi
exec "$@"'
assert_contains "$(sudo_all --no-tui)" "not to cache credentials"

it "leaves no keep-alive process behind"
assert_not_contains "$(sudo_all --no-tui)" "Terminated"

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
assert_contains "$out" "All 4 script(s) completed"

it "--tui without a terminal is refused rather than hanging"
out="$(setup_all --tui </dev/null 2>&1)"
assert_contains "$out" "interactive terminal"

it "descriptions containing commas are sanitised for the menu"
make_setup_script "$repo/bin" setup-comma 60 "one, two"
assert_contains "$(setup_all --list)" "one · two"

finish

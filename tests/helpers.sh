#!/usr/bin/env bash
# Assertions and fixtures for the test suite. Sourced by each tests/test-*.sh.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

# Everything a test creates goes here and is removed on exit, so tests never
# touch the real home directory or repo.
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-tests.XXXXXX")"
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

# Used by the test files that source this, not here.
# shellcheck disable=SC2034
if [[ -t 1 ]]; then
  T_RED=$'\e[31m'; T_GREEN=$'\e[32m'; T_DIM=$'\e[2m'; T_RESET=$'\e[0m'
else
  T_RED=''; T_GREEN=''; T_DIM=''; T_RESET=''
fi

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  %s✗%s %s\n' "$T_RED" "$T_RESET" "$CURRENT_TEST" >&2
  printf '    %s\n' "$@" >&2
  return 1
}

pass() { printf '  %s✓%s %s\n' "$T_GREEN" "$T_RESET" "$CURRENT_TEST"; }

assert_eq() {
  local expected="$1" actual="$2" what="${3:-value}"
  if [[ "$expected" == "$actual" ]]; then
    pass
  else
    fail "$what mismatch" "expected: $expected" "actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass
  else
    fail "expected output to contain: $needle" "got: ${haystack:0:400}"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass
  else
    fail "expected output NOT to contain: $needle" "got: ${haystack:0:400}"
  fi
}

assert_status() {
  local expected="$1" actual="$2"
  if [[ "$expected" == "$actual" ]]; then
    pass
  else
    fail "expected exit $expected, got $actual"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2"
  if [[ ! -f "$file" ]]; then
    fail "expected file to exist: $file"
  elif grep -qF "$needle" "$file"; then
    pass
  else
    fail "expected $file to contain: $needle" "got: $(head -c 300 "$file")"
  fi
}

assert_no_file() {
  local file="$1"
  if [[ -e "$file" ]]; then
    fail "expected $file not to exist"
  else
    pass
  fi
}

# --- fixtures --------------------------------------------------------------

# make_fake_home — an isolated HOME with XDG_RUNTIME_DIR, echoed to stdout.
make_fake_home() {
  local home="$TEST_TMP/home.$RANDOM"
  mkdir -p "$home/.ssh" "$home/.config" "$home/run"
  chmod 700 "$home/.ssh"
  printf '%s' "$home"
}

# stub_bin <dir> <name> <body> — a fake command that logs its arguments to
# $dir/<name>.log, so tests can assert on how a script called it.
stub_bin() {
  local dir="$1" name="$2" body="${3:-}"
  mkdir -p "$dir"
  cat > "$dir/$name" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/$name.log"
$body
STUB
  chmod +x "$dir/$name"
}

# make_socket <path> — a real unix socket, for code that checks [[ -S ... ]].
make_socket() {
  local path="$1"
  python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
" "$path"
}

# make_setup_script <dir> <name> <order> <description> [exit_code]
make_setup_script() {
  local dir="$1" name="$2" order="$3" desc="$4" code="${5:-0}"
  mkdir -p "$dir"
  cat > "$dir/$name" <<SCRIPT
#!/usr/bin/env bash
# order: $order
# description: $desc
echo "[$name] args: \$*"
exit $code
SCRIPT
  chmod +x "$dir/$name"
}

# make_test_repo — a throwaway copy of bin/ and lib/ that fixtures can be
# added to without touching the real tree.
make_test_repo() {
  local repo="$TEST_TMP/repo.$RANDOM"
  mkdir -p "$repo"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$repo/"
  printf '%s' "$repo"
}

# Report counts to the harness and set the process exit status.
finish() {
  printf 'RESULT %s %s\n' "$TESTS_RUN" "$TESTS_FAILED" >&"${TEST_RESULT_FD:-1}"
  [[ "$TESTS_FAILED" -eq 0 ]]
}

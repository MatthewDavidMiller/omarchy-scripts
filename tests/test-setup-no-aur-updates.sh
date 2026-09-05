#!/usr/bin/env bash
# bin/setup-no-aur-updates — against a throwaway shim directory with a stubbed
# omarchy, pacman and sudo. Nothing here touches /usr/local/bin or the real
# package database.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"

# sudo just runs the command; the stub records that sudo was used at all.
stub_bin "$STUBS" sudo 'exec "$@"'

# A one-file-per-package fake database, so the script sees the truth its own
# removal just created rather than a stub that always agrees.
# shellcheck disable=SC2016
stub_bin "$STUBS" pacman '
db="${FAKE_PKG_DB:?}"
case "$1" in
  -Qq)  [[ -f "$db/$2" ]] ;;
  -Q*)  printf "forwarded %s\n" "$*" ;;
  -Rs)  shift 2
        for p in "$@"; do printf "%s-1.0-1\n" "$p"; done ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
db="${FAKE_PKG_DB:?}"
verb="$1 $2"; shift 2
case "$verb" in
  "pkg drop") for p in "$@"; do rm -f "$db/$p"; done ;;
  *) echo "unexpected: $verb $*" >&2; exit 1 ;;
esac'

export PATH="$STUBS:$PATH"

MARKER='omarchy-scripts:no-aur-updates'
SCRIPT="$REPO_ROOT/bin/setup-no-aur-updates"

# Every shim the script owns, and the Omarchy commands it expects upstream.
SHIMS=(omarchy-update-aur-pkgs omarchy-pkg-aur-accessible \
  "omarchy-pkg-aur-add" omarchy-pkg-aur-install)

# fixture — a clean shim dir, upstream bin dir, and package database with the
# helper installed. Echoes the case directory.
fixture() {
  local dir="$TEST_TMP/case.$RANDOM"
  mkdir -p "$dir/shims" "$dir/bin" "$dir/db"
  local name
  for name in "${SHIMS[@]}"; do
    printf '#!/bin/bash\n' > "$dir/bin/$name"
    chmod +x "$dir/bin/$name"
  done
  : > "$dir/db/yay"
  printf '%s' "$dir"
}

# run_setup <case-dir> [args...]
run_setup() {
  local dir="$1"; shift
  FAKE_PKG_DB="$dir/db" \
  OMARCHY_SHIM_DIR="$dir/shims" \
  OMARCHY_BIN_DIR="$dir/bin" \
  OMARCHY_LOGIN_PATH="$dir/shims:$dir/bin" \
    bash "$SCRIPT" -y "$@" 2>&1
}

# --- a first run installs every shim and removes the helper ----------------

CASE="$(fixture)"
out="$(run_setup "$CASE")"
status=$?

it "exits 0 on a first run"
assert_status 0 "$status"

for name in "${SHIMS[@]}"; do
  it "installs the $name shim"
  assert_file "$CASE/shims/$name"
done

it "installs a shim for the helper it removes"
assert_file "$CASE/shims/yay"

it "marks every shim as ours"
missing=""
for name in "${SHIMS[@]}" yay; do
  grep -qF -- "$MARKER" "$CASE/shims/$name" || missing="$missing $name"
done
assert_eq "" "$missing" "shims missing the marker"

it "makes every shim executable"
nonexec=""
for name in "${SHIMS[@]}" yay; do
  [[ -x "$CASE/shims/$name" ]] || nonexec="$nonexec $name"
done
assert_eq "" "$nonexec" "shims that are not executable"

it "removes the helper package through omarchy pkg drop"
assert_no_file "$CASE/db/yay"

it "goes through sudo to write into the shim directory"
assert_file_contains "$STUBS/sudo.log" "install -D -m 0755"

it "skips a helper that is not installed"
assert_contains "$out" "paru is not installed"

it "reports the shim directory winning on a login PATH"
assert_contains "$out" "precedes"

# --- the shims do what they claim ------------------------------------------

it "the update step shim exits 0 without touching the network"
"$CASE/shims/omarchy-update-aur-pkgs" >/dev/null 2>&1
assert_status 0 "$?"

it "the reachability probe shim reports the AUR as unreachable"
"$CASE/shims/omarchy-pkg-aur-accessible" >/dev/null 2>&1
assert_status 1 "$?"

# The probe shim's comment explains the curl it replaces, so only code lines
# count here.
it "no shim runs curl"
curl_calls="$(grep -vh '^[[:space:]]*#' "$CASE/shims"/* | grep -n "curl" || true)"
assert_eq "" "$curl_calls" "shim code running curl"

it "the installer shim refuses"
"$CASE/shims/omarchy-pkg-aur-add" some-package >/dev/null 2>&1
assert_status 1 "$?"

it "the helper shim forwards a read-only query to pacman"
forwarded="$(FAKE_PKG_DB="$CASE/db" "$CASE/shims/yay" -Qi something 2>&1)"
assert_contains "$forwarded" "forwarded -Qi something"

it "the helper shim refuses anything that could install"
"$CASE/shims/yay" -S something >/dev/null 2>&1
assert_status 1 "$?"

# --- idempotence, the load-bearing property --------------------------------

before="$(find "$CASE/shims" -type f -exec md5sum {} + | sort)"
out2="$(run_setup "$CASE")"
status2=$?

it "exits 0 on a second run"
assert_status 0 "$status2"

it "a second run changes nothing on disk"
after="$(find "$CASE/shims" -type f -exec md5sum {} + | sort)"
assert_eq "$before" "$after" "shim directory contents"

it "a second run reports skips rather than writes"
assert_not_contains "$out2" "ok wrote"

it "a second run leaves no backup files behind"
backups="$(find "$CASE/shims" -name '*.bak.*' | wc -l)"
assert_eq "0" "$backups" "backup files"

# --- dry run ---------------------------------------------------------------

CASE="$(fixture)"
: > "$STUBS/sudo.log"
out="$(run_setup "$CASE" --dry-run)"

it "--dry-run writes no shim"
assert_eq "" "$(ls -A "$CASE/shims")" "shim directory contents"

it "--dry-run leaves the helper package installed"
assert_file "$CASE/db/yay"

it "--dry-run never calls sudo"
assert_eq "" "$(cat "$STUBS/sudo.log")" "sudo invocations"

it "--dry-run still says what it would do"
assert_contains "$out" "would write"

# --- a file the script does not own is never touched -----------------------

CASE="$(fixture)"
printf '#!/bin/sh\n# someone else\n' > "$CASE/shims/omarchy-pkg-aur-add"
chmod +x "$CASE/shims/omarchy-pkg-aur-add"
out="$(run_setup "$CASE")"

it "warns about a shim-directory file that is not ours"
assert_contains "$out" "is not ours"

it "leaves a file that is not ours exactly as it was"
assert_file_contains "$CASE/shims/omarchy-pkg-aur-add" "# someone else"

it "still installs the shims it does own"
assert_file_contains "$CASE/shims/omarchy-update-aur-pkgs" "$MARKER"

# --- the reverse -----------------------------------------------------------

out="$(run_setup "$CASE" --allow-aur-updates)"

it "--allow-aur-updates removes the shims it installed"
assert_no_file "$CASE/shims/omarchy-update-aur-pkgs"

it "--allow-aur-updates removes the helper shim too"
assert_no_file "$CASE/shims/yay"

it "--allow-aur-updates leaves a file that is not ours alone"
assert_file_contains "$CASE/shims/omarchy-pkg-aur-add" "# someone else"

it "--allow-aur-updates does not reinstall the helper package"
assert_contains "$out" "not reinstalled"

it "--allow-aur-updates is idempotent"
out2="$(run_setup "$CASE" --allow-aur-updates)"
assert_contains "$out2" "already gone"

# --- a machine where the helper was never installed ------------------------

CASE="$(fixture)"
rm -f "$CASE/db/yay"
out="$(run_setup "$CASE")"

it "installs the Omarchy shims with no helper installed"
assert_file_contains "$CASE/shims/omarchy-update-aur-pkgs" "$MARKER"

it "writes no helper shim when there is no helper to replace"
assert_no_file "$CASE/shims/yay"

it "says the helper is not installed rather than failing"
assert_contains "$out" "yay is not installed"

# --- upstream drift --------------------------------------------------------

CASE="$(fixture)"
rm -f "$CASE/bin/omarchy-update-aur-pkgs"
out="$(run_setup "$CASE")"

it "warns when an Omarchy command it shadows has gone away"
assert_contains "$out" "may be stale against a newer Omarchy"

it "still installs the shim rather than dying on upstream drift"
assert_file "$CASE/shims/omarchy-update-aur-pkgs"

# --- the repository's own package-source policy ----------------------------

it "the script never invokes an AUR helper"
invocations="$(grep -En \
  '(^|[[:space:]])(yay|paru|omarchy +pkg +aur +add|omarchy-pkg-aur-add)([[:space:]]|$)' \
  "$SCRIPT" || true)"
assert_eq "" "$invocations" "AUR helper invocations"

it "--help exits 0"
bash "$SCRIPT" --help >/dev/null 2>&1
assert_status 0 "$?"

it "rejects an unknown argument"
bash "$SCRIPT" --nonsense >/dev/null 2>&1
assert_status 1 "$?"

finish

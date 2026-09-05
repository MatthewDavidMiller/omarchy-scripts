#!/usr/bin/env bash
# bin/setup-no-aur-updates — against a throwaway shim directory with a stubbed
# omarchy, pacman and sudo. Nothing here touches /usr/local/bin or the real
# package database.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"

# sudo just runs the command; the stub records that sudo was used at all.
# FAKE_SUDO_FAIL=1 makes it refuse, standing in for a sudo that cannot read a
# password — the case that once printed "ok wrote" over an untouched file.
# shellcheck disable=SC2016
stub_bin "$STUBS" sudo '
[[ -n "${FAKE_SUDO_FAIL:-}" ]] && exit 1
exec "$@"'

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

# Never reaches the real user manager: run_setup sets OMARCHY_MANAGER_PATH, which
# makes the script refuse to write a session environment, and this stub catches
# anything that still tries.
stub_bin "$STUBS" systemctl 'exit 0'
# Nothing in the script writes a session environment any more; the stub is here
# so a regression that reintroduces one is caught rather than run for real.

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
  mkdir -p "$dir/shims" "$dir/bin" "$dir/db" "$dir/hypr"
  # A stand-in for the stock entry point, down to the require this must land
  # after.
  cat > "$dir/hypr/hyprland.lua" <<'ENTRY'
dofile("/usr/share/omarchy/default/hypr/bootstrap.lua")
require("default.hypr.omarchy")
require("hypr.bindings")

-- Add any other personal Hyprland configuration below.
ENTRY
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
  OMARCHY_LOGIN_PATH="${OMARCHY_LOGIN_PATH-$dir/shims:$dir/bin}" \
  OMARCHY_MANAGER_PATH="${OMARCHY_MANAGER_PATH-}" \
  OMARCHY_HYPR_DIR="$dir/hypr" \
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
assert_contains "$out" "wins every shim name on the login PATH"

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

# --- the Hyprland PATH override ---------------------------------------------
# Split in two so an update that rewrites a config file cannot take the whole
# thing with it: the module is ours and is not a config Omarchy ships, so only
# the require line in hyprland.lua is exposed.

CASE="$(fixture)"
out="$(run_setup "$CASE")"

it "writes the override module"
assert_file "$CASE/hypr/omarchy-scripts-path.lua"

it "marks the module as ours"
assert_file_contains "$CASE/hypr/omarchy-scripts-path.lua" "$MARKER"

it "puts the shim directory ahead of Omarchy's bin in the module"
assert_file_contains "$CASE/hypr/omarchy-scripts-path.lua" 'table.insert(kept, 1, shim_dir)'

it "adds the require line to hyprland.lua"
assert_file_contains "$CASE/hypr/hyprland.lua" 'pcall(require, "hypr.omarchy-scripts-path")'

it "guards the require with pcall, so a broken module cannot stop the session"
assert_file_contains "$CASE/hypr/hyprland.lua" "pcall(require"

it "adds the require after Omarchy's own defaults, or it would not win"
theirs="$(grep -n 'default.hypr.omarchy' "$CASE/hypr/hyprland.lua" | head -1 | cut -d: -f1)"
ours_line="$(grep -n 'pcall(require, "hypr.omarchy-scripts-path")' "$CASE/hypr/hyprland.lua" | head -1 | cut -d: -f1)"
if [[ -n "$theirs" && -n "$ours_line" && "$ours_line" -gt "$theirs" ]]; then
  pass
else
  fail "expected our require (line ${ours_line:-none}) after Omarchy's (line ${theirs:-none})"
fi

it "leaves the rest of hyprland.lua alone"
assert_file_contains "$CASE/hypr/hyprland.lua" 'require("hypr.bindings")'

# An update that replaces hyprland.lua takes the require line with it. The
# module survives, because it is not a file Omarchy ships, and a re-run rewires
# it — this is the whole point of the split.

cat > "$CASE/hypr/hyprland.lua" <<'ENTRY'
dofile("/usr/share/omarchy/default/hypr/bootstrap.lua")
require("default.hypr.omarchy")
require("hypr.bindings")
ENTRY
out="$(run_setup "$CASE")"

it "survives an update that replaces hyprland.lua: the module is still there"
assert_file_contains "$CASE/hypr/omarchy-scripts-path.lua" "$MARKER"

it "rewires the require line a config refresh removed"
assert_file_contains "$CASE/hypr/hyprland.lua" 'pcall(require, "hypr.omarchy-scripts-path")'

it "reports the module as already up to date rather than rewriting it"
assert_contains "$out" "already up to date"

# A second run with nothing changed must not append the require line twice.

before="$(grep -c "omarchy-scripts-path" "$CASE/hypr/hyprland.lua")"
run_setup "$CASE" >/dev/null
after="$(grep -c "omarchy-scripts-path" "$CASE/hypr/hyprland.lua")"

it "never adds the require line twice"
assert_eq "$before" "$after" "occurrences of the require line"

# Reversing takes both halves out and leaves the user's own file intact.

out="$(run_setup "$CASE" --allow-aur-updates)"

it "--allow-aur-updates removes the override module"
assert_no_file "$CASE/hypr/omarchy-scripts-path.lua"

it "--allow-aur-updates drops the require line"
assert_not_contains "$(cat "$CASE/hypr/hyprland.lua")" "omarchy-scripts-path"

it "--allow-aur-updates keeps the rest of hyprland.lua"
assert_file_contains "$CASE/hypr/hyprland.lua" 'require("hypr.bindings")'

it "--allow-aur-updates is idempotent on the override"
out2="$(run_setup "$CASE" --allow-aur-updates)"
assert_contains "$out2" "already gone"

# A module someone else wrote is reported, never deleted.

CASE="$(fixture)"
printf -- '-- someone else\n' > "$CASE/hypr/omarchy-scripts-path.lua"
out="$(run_setup "$CASE" --allow-aur-updates)"

it "leaves an override module that is not ours alone"
assert_file_contains "$CASE/hypr/omarchy-scripts-path.lua" "-- someone else"

it "says it left a module that is not ours alone"
assert_contains "$out" "is not ours"

# A machine with no Hyprland config at all must not grow one.

CASE="$(fixture)"
rm -f "$CASE/hypr/hyprland.lua"
out="$(run_setup "$CASE")"

it "writes no Hyprland files where there is no Hyprland config"
assert_no_file "$CASE/hypr/omarchy-scripts-path.lua"

it "says why it skipped the Hyprland override"
assert_contains "$out" "no Hyprland config to override"

# --- a stale shell is not a broken install ----------------------------------
# A process keeps the PATH it was given, so a terminal or editor started before
# the override reports every shim as shadowed while the install is perfectly
# correct. That is a note, not a failure: reporting it as one made setup-all
# say a script failed when there was nothing to fix.

CASE="$(fixture)"
mkdir -p "$CASE/farm"
for name in "${SHIMS[@]}"; do
  ln -sf "$CASE/bin/$name" "$CASE/farm/$name"
done
# Login PATH stale, manager PATH clean, override installed.
out="$(OMARCHY_LOGIN_PATH="$CASE/farm:$CASE/shims:$CASE/bin" \
  OMARCHY_MANAGER_PATH="$CASE/shims:$CASE/bin" run_setup "$CASE")"
status=$?

it "exits 0 when only the invoking shell is stale"
assert_status 0 "$status"

it "still names what shadows the shim, so the warning is not lost"
assert_contains "$out" "before $CASE/shims/omarchy-update-aur-pkgs"

it "says the install is fine and the shell is what is old"
assert_contains "$out" "was started before"

it "does not tell the user to re-run the script"
assert_not_contains "$out" "Re-run this once it is"

# The same stale login PATH with the override missing is a real failure: nothing
# will make a new process resolve the shims.

CASE="$(fixture)"
mkdir -p "$CASE/farm"
for name in "${SHIMS[@]}"; do
  ln -sf "$CASE/bin/$name" "$CASE/farm/$name"
done
run_setup "$CASE" >/dev/null
rm -f "$CASE/hypr/omarchy-scripts-path.lua"
# Re-running would reinstall it, so check the classification with the module
# gone by pointing at a hypr dir that has an entry but no module.
out="$(OMARCHY_LOGIN_PATH="$CASE/farm:$CASE/shims:$CASE/bin" \
  OMARCHY_MANAGER_PATH="$CASE/farm:$CASE/shims:$CASE/bin" run_setup "$CASE")"
status=$?

it "exits non-zero when the manager PATH is shadowed too"
assert_status 1 "$status"

it "names envs.lua as the usual cause of a real failure"
assert_contains "$out" "envs.lua"

# --- a write that does not happen -------------------------------------------
# `install_root_file` is called with `|| true` so a skip can pass through, and
# that disables set -e for its whole body. A sudo failure therefore has to be
# checked by hand or the run reports shims it never installed.

CASE="$(fixture)"
out="$(FAKE_SUDO_FAIL=1 run_setup "$CASE")"
status=$?

it "exits non-zero when a shim cannot be written"
assert_status 1 "$status"

it "does not report a shim write that failed as done"
assert_not_contains "$out" "ok wrote $CASE/shims"

it "says the write failed"
assert_contains "$out" "could not write"

it "leaves no shim behind when the write failed"
assert_no_file "$CASE/shims/omarchy-update-aur-pkgs"

it "does not claim the AUR step is skipped when nothing was written"
assert_not_contains "$out" "now skips the AUR step"

# A failing backup must stop that shim too, rather than overwriting a file whose
# previous contents were never saved.

CASE="$(fixture)"
run_setup "$CASE" >/dev/null
printf '#!/bin/bash\n# %s\n# changed\n' "$MARKER" > "$CASE/shims/omarchy-update-aur-pkgs"
out="$(FAKE_SUDO_FAIL=1 run_setup "$CASE")"

it "does not report a backup that failed as done"
assert_not_contains "$out" "ok backed up"

it "leaves the file alone when its backup could not be taken"
assert_file_contains "$CASE/shims/omarchy-update-aur-pkgs" "# changed"

# --- a PATH that shadows the shims ------------------------------------------
# The failure this section exists to catch: /usr/share/omarchy/bin is a farm of
# symlinks into /usr/bin, so a PATH carrying it ahead of the shim directory
# reaches the upstream command while the shim directory still precedes the bin
# directory. The old check compared only those two and passed.

# No Hyprland config here, so there is no override to make a new session right:
# a shadowed shim is simply broken.
CASE="$(fixture)"
rm -f "$CASE/hypr/hyprland.lua"
mkdir -p "$CASE/farm"
for name in "${SHIMS[@]}"; do
  ln -sf "$CASE/bin/$name" "$CASE/farm/$name"
done
out="$(OMARCHY_LOGIN_PATH="$CASE/farm:$CASE/shims:$CASE/bin" run_setup "$CASE")"
status=$?

it "names the file that shadows a shim on the login PATH"
assert_contains "$out" "$CASE/farm/omarchy-update-aur-pkgs before $CASE/shims/omarchy-update-aur-pkgs"

it "does not claim success when a shim is shadowed"
assert_not_contains "$out" "now skips the AUR step"

it "exits non-zero when a shim is shadowed"
assert_status 1 "$status"

it "still installs the shims, so fixing PATH is all that is left"
assert_file_contains "$CASE/shims/omarchy-update-aur-pkgs" "$MARKER"

# A directory that shadows only the helper name is still a shadowed shim: that
# is the half of this machine's PATH that did work, and it must not mask the
# half that did not.

CASE="$(fixture)"
out="$(OMARCHY_LOGIN_PATH="$CASE/bin:$CASE/shims" run_setup "$CASE")"

it "reports every shadowed name, not just the first"
shadowed="$(grep -c "before $CASE/shims/" <<< "$out")"
assert_eq "4" "$shadowed" "shadowed shim warnings"

# --- a PATH without the shim directory at all -------------------------------

CASE="$(fixture)"
rm -f "$CASE/hypr/hyprland.lua"
out="$(OMARCHY_LOGIN_PATH="$CASE/bin" run_setup "$CASE")"
status=$?

it "reports a login PATH that cannot reach the shim directory"
assert_contains "$out" "is not on the login PATH"

it "exits non-zero when the shim directory is not on PATH"
assert_status 1 "$status"

# --- the systemd user manager's PATH is checked too -------------------------
# It holds the session PATH under a uwsm login and outlives a logout, so a
# stale entry there is not cleared by opening a new shell.

CASE="$(fixture)"
mkdir -p "$CASE/farm"
ln -sf "$CASE/bin/omarchy-pkg-aur-accessible" "$CASE/farm/omarchy-pkg-aur-accessible"
out="$(OMARCHY_MANAGER_PATH="$CASE/farm:$CASE/shims:$CASE/bin" run_setup "$CASE")"
status=$?

it "checks the systemd user manager PATH as well as a login shell's"
assert_contains "$out" "systemd user manager PATH reaches"

it "exits non-zero when only the manager PATH shadows a shim"
assert_status 1 "$status"

it "never writes a session environment, even when a shim is shadowed"
: > "$STUBS/systemctl.log"
CASE="$(fixture)"
out="$(OMARCHY_MANAGER_PATH="$CASE/bin:$CASE/shims" run_setup "$CASE")"
assert_eq "" "$(cat "$STUBS/systemctl.log")" "systemctl invocations"

it "names the cause a shadowed shim usually has"
assert_contains "$out" "envs.lua"

it "an empty manager PATH skips that check rather than failing"
CASE="$(fixture)"
out="$(run_setup "$CASE")"
assert_not_contains "$out" "systemd user manager PATH"

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

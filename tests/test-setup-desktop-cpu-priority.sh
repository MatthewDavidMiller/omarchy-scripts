#!/usr/bin/env bash
# bin/setup-desktop-cpu-priority — against a throwaway HOME, a stubbed
# systemctl, and a fake cgroup tree standing in for /sys/fs/cgroup.
#
# The systemctl stub applies the drop-in the way the real one does: a
# daemon-reload copies CPUWeight into the live cgroup attribute. That is what
# lets these tests exercise the verify path, which is the only part that proves
# the setting reached the kernel rather than just landing in a file.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

FAKE_HOME="$(make_fake_home)"
STUBS="$TEST_TMP/stubs"
USER_DIR="$FAKE_HOME/.config/systemd/user"
DROP_IN="$USER_DIR/user.slice.d/10-cpu-weight.conf"
CGROUP="$TEST_TMP/cgroup"

# A user manager with cpu delegated, which is the ordinary case.
mkdir -p "$CGROUP/user.slice"
printf 'cpu memory pids\n' > "$CGROUP/cgroup.controllers"
printf '100\n' > "$CGROUP/user.slice/cpu.weight"

# Stub bodies are literal shell, expanded when the stub runs, not now.
# shellcheck disable=SC2016
stub_bin "$STUBS" systemctl '
case "$*" in
  "--user daemon-reload")
    conf="$SYSTEMD_USER_DIR/user.slice.d/10-cpu-weight.conf"
    weight=100
    [[ -f $conf ]] && weight="$(sed -n "s/^CPUWeight=//p" "$conf")"
    mkdir -p "$USER_CGROUP/user.slice"
    printf "%s\n" "$weight" > "$USER_CGROUP/user.slice/cpu.weight"
    ;;
  "is-active --quiet docker.service") exit 3 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" podman '
[[ "$*" == "info --format {{.Host.CgroupManager}}" ]] && echo systemd'

cpu_priority() {
  env HOME="$FAKE_HOME" PATH="$STUBS:$PATH" \
      SYSTEMD_USER_DIR="$USER_DIR" USER_CGROUP="$CGROUP" \
      "$REPO_ROOT/bin/setup-desktop-cpu-priority" "$@" 2>&1
}

reloads() { grep -c -- '--user daemon-reload' "$STUBS/systemctl.log" 2>/dev/null || true; }

# --- dry run changes nothing ------------------------------------------------

out="$(cpu_priority --dry-run --yes)"

it "--dry-run writes no drop-in"
assert_no_file "$DROP_IN"

it "--dry-run does not reload the user manager"
assert_eq "0" "$(reloads)" "daemon-reload calls"

it "--dry-run still says what it would write"
assert_contains "$out" "would write $DROP_IN"

# --- real run ---------------------------------------------------------------

out="$(cpu_priority --yes)"

it "writes the drop-in"
assert_file "$DROP_IN"

it "sets the weight below the default 100 every other slice gets"
assert_file_contains "$DROP_IN" "CPUWeight=20"

it "marks the file as this repository's, so a later reader knows what owns it"
assert_file_contains "$DROP_IN" "Managed by omarchy-scripts"

it "targets user.slice, where rootless podman puts containers"
assert_file "$USER_DIR/user.slice.d"

# Lowering app.slice would throttle the editor this exists to protect, and
# lowering session.slice would throttle the compositor. Only user.slice is right.
it "leaves app.slice and session.slice alone"
assert_no_file "$USER_DIR/app.slice.d"

it "does not touch session.slice either"
assert_no_file "$USER_DIR/session.slice.d"

it "reloads the user manager so the change is live"
assert_eq "1" "$(reloads)" "daemon-reload calls"

it "reads the applied weight back out of the cgroup"
assert_contains "$out" "user.slice is running at cpu.weight 20"

it "confirms the cpu controller is delegated"
assert_contains "$out" "cpu controller is delegated"

it "names the escape hatch for a build run outside a container"
assert_contains "$out" "systemd-run --user --scope --slice=user.slice"

# --- second run is a no-op --------------------------------------------------

out2="$(cpu_priority --yes)"

it "a second run skips the write"
assert_contains "$out2" "already up to date"

it "a second run does not reload again"
assert_eq "1" "$(reloads)" "daemon-reload calls"

# --- a different weight -----------------------------------------------------

out3="$(cpu_priority --weight 50 --yes)"

it "--weight rewrites the drop-in"
assert_file_contains "$DROP_IN" "CPUWeight=50"

it "--weight reloads, because the value has to reach the kernel"
assert_eq "2" "$(reloads)" "daemon-reload calls"

it "--weight verifies the new value"
assert_contains "$out3" "cpu.weight 50"

it "CPU_WEIGHT in the environment works the same as --weight"
CPU_WEIGHT=30 cpu_priority --yes >/dev/null
assert_file_contains "$DROP_IN" "CPUWeight=30"

# --- reverting --------------------------------------------------------------

out4="$(cpu_priority --revert --yes)"

it "--revert removes the drop-in"
assert_no_file "$DROP_IN"

# The rewrites above left write_file's timestamped backups in the directory.
# Reverting must not take those with it — they are the record of what the
# previous settings were, and the repository's backup rule owns them.
it "--revert keeps the backups of earlier versions"
if compgen -G "$USER_DIR/user.slice.d/*.bak.*" >/dev/null; then
  pass
else
  fail "expected write_file backups to survive the revert"
fi

it "--revert restores the default weight in the cgroup"
assert_eq "100" "$(cat "$CGROUP/user.slice/cpu.weight")" "live cpu.weight"

it "--revert says the default is back"
assert_contains "$out4" "back to the default weight of 100"

it "--revert a second time changes nothing"
assert_contains "$(cpu_priority --revert --yes)" "is not installed"

# On a home where the drop-in was written once and never rewritten there is
# nothing left to keep, and the directory should not be left behind as litter.
CLEAN_HOME="$(make_fake_home)"
CLEAN_DIR="$CLEAN_HOME/.config/systemd/user"
clean_run() {
  env HOME="$CLEAN_HOME" PATH="$STUBS:$PATH" \
      SYSTEMD_USER_DIR="$CLEAN_DIR" USER_CGROUP="$CGROUP" \
      "$REPO_ROOT/bin/setup-desktop-cpu-priority" "$@" 2>&1
}
clean_run --yes >/dev/null
clean_run --revert --yes >/dev/null

it "--revert removes the drop-in directory when nothing else is in it"
assert_no_file "$CLEAN_DIR/user.slice.d"

# --- when the knob is not connected -----------------------------------------

UNDELEGATED="$TEST_TMP/cgroup-nocpu"
mkdir -p "$UNDELEGATED/user.slice"
printf 'memory pids\n' > "$UNDELEGATED/cgroup.controllers"
printf '100\n' > "$UNDELEGATED/user.slice/cpu.weight"

nocpu_out="$(env HOME="$FAKE_HOME" PATH="$STUBS:$PATH" \
  SYSTEMD_USER_DIR="$USER_DIR" USER_CGROUP="$UNDELEGATED" \
  "$REPO_ROOT/bin/setup-desktop-cpu-priority" --yes 2>&1)"

it "warns when the cpu controller is not delegated to the user manager"
assert_contains "$nocpu_out" "NOT delegated"

it "still writes the drop-in, so it takes effect if delegation appears later"
assert_file_contains "$DROP_IN" "CPUWeight=20"

cpu_priority --revert --yes >/dev/null

# --- containers this cannot reach -------------------------------------------

# shellcheck disable=SC2016
stub_bin "$STUBS" podman '
[[ "$*" == "info --format {{.Host.CgroupManager}}" ]] && echo cgroupfs'

it "warns when podman is not using the systemd cgroup manager"
assert_contains "$(cpu_priority --yes)" "not systemd"

# shellcheck disable=SC2016
stub_bin "$STUBS" systemctl '
case "$*" in
  "--user daemon-reload") : ;;
  "is-active --quiet docker.service") exit 0 ;;
esac'

it "warns that a running Docker daemon is outside this slice entirely"
assert_contains "$(cpu_priority --weight 25 --yes)" "system.slice"

# --- argument handling ------------------------------------------------------

it "rejects a weight below systemd's range"
cpu_priority --weight 0 >/dev/null 2>&1
assert_status 1 $?

it "rejects a weight above systemd's range"
cpu_priority --weight 10001 >/dev/null 2>&1
assert_status 1 $?

it "rejects a weight that is not a number"
cpu_priority --weight heavy >/dev/null 2>&1
assert_status 1 $?

it "help text is available without touching the system"
assert_contains "$(cpu_priority --help)" "Usage: setup-desktop-cpu-priority"

it "rejects unknown arguments"
cpu_priority --not-a-flag >/dev/null 2>&1
assert_status 1 $?

it "dies when systemctl is not installed"
# A PATH with just enough to start the script — bash for the shebang, dirname
# to resolve SCRIPT_DIR — and nothing else, so require_cmd is what stops it.
MINIMAL="$TEST_TMP/minimal-path"
mkdir -p "$MINIMAL"
for cmd in bash dirname; do ln -sf "$(command -v "$cmd")" "$MINIMAL/$cmd"; done
env HOME="$FAKE_HOME" PATH="$MINIMAL" SYSTEMD_USER_DIR="$USER_DIR" \
  USER_CGROUP="$CGROUP" "$REPO_ROOT/bin/setup-desktop-cpu-priority" --yes >/dev/null 2>&1
assert_status 1 $?

finish

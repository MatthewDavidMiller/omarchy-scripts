#!/usr/bin/env bash
# bin/setup-opensnitch — package, config, rule synchronization, and systemd
# behavior against disposable fixtures. No real firewall or service is touched.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"

# shellcheck disable=SC2016
stub_bin "$STUBS" sudo '
exec "$@"'

# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
db="${FAKE_PKG_DB:?}"
case "$1 $2" in
  "pkg present") [[ -f "$db/$3" ]] ;;
  "pkg add") : > "$db/$3" ;;
  *) echo "unexpected omarchy call: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" pacman '
REPO_VALUE="${FAKE_OPEN_SNITCH_REPO:-extra}"
PKG_NAME=opensnitch
# Real `pacman -Si` prints Repository first, then ~20 more fields. The large
# tail here is deliberate: a reader that exits at the Repository line leaves
# this writer blocked on a full pipe, and under `set -o pipefail` that SIGPIPE
# becomes exit 141 for the whole script. Without the padding the race is won
# often enough that the bug only shows up as an occasional flake.
printf "Repository      : %s\nName            : %s\n" "$REPO_VALUE" "$PKG_NAME"
printf "Description     : "
head -c 200000 /dev/zero | tr "\0" "x"
printf "\n"'

# shellcheck disable=SC2016
stub_bin "$STUBS" systemctl '
state="${FAKE_UNIT_STATE:?}"
case "$*" in
  "cat opensnitchd.service") exit 0 ;;
  "is-enabled --quiet opensnitchd.service") [[ -f "$state/enabled" ]] ;;
  "enable opensnitchd.service") : > "$state/enabled" ;;
  "is-active --quiet opensnitchd.service") [[ -f "$state/active" ]] ;;
  "start opensnitchd.service"|"restart opensnitchd.service") : > "$state/active" ;;
  *) echo "unexpected systemctl call: $*" >&2; exit 1 ;;
esac'

stub_bin "$STUBS" pgrep 'exit 1'

make_fixture() {
  local root="$1"
  mkdir -p "$root/etc/opensnitchd/rules" "$root/shared" "$root/pkgdb" "$root/units"
  : > "$root/ebpf.o"
  cat > "$root/etc/opensnitchd/default-config.json" <<'JSON'
{
  "Server": {"Address": "unix:///tmp/osui.sock", "LogFile": "/var/log/opensnitchd.log"},
  "DefaultAction": "allow",
  "InterceptUnknown": true,
  "ProcMonitorMethod": "proc",
  "Firewall": "iptables",
  "FwOptions": {"QueueBypass": true, "ActionOnOverflow": "accept", "MonitorInterval": "15s"},
  "Rules": {"Path": "/etc/opensnitchd/rules", "EnableChecksums": false},
  "Stats": {"Workers": 6}
}
JSON
  cp "$REPO_ROOT"/config/opensnitch/rules/*.json "$root/shared/"
}

run_setup() {
  local home="$1" root="$2"; shift 2
  HOME="$home" XDG_RUNTIME_DIR="$home/run" PATH="$STUBS:$PATH" \
    FAKE_PKG_DB="$root/pkgdb" FAKE_UNIT_STATE="$root/units" \
    FAKE_OPEN_SNITCH_REPO="${FAKE_OPEN_SNITCH_REPO:-extra}" \
    HYPRLAND_INSTANCE_SIGNATURE="" \
    OPEN_SNITCH_DAEMON_CONFIG="$root/etc/opensnitchd/default-config.json" \
    OPEN_SNITCH_RULES_DIR="$root/etc/opensnitchd/rules" \
    OPEN_SNITCH_SHARED_RULES_DIR="$root/shared" \
    OPEN_SNITCH_EBPF_OBJECT="$root/ebpf.o" \
    OPEN_SNITCH_GUI_SETTINGS="$home/.config/opensnitch/settings.conf" \
    OPEN_SNITCH_AUTOSTART_FILE="$home/.config/hypr/autostart.lua" \
    OPEN_SNITCH_UI_LAUNCHER="$home/.local/bin/opensnitch-ui-secure" \
    OPEN_SNITCH_SKIP_LIVE_UI=1 \
    "$REPO_ROOT/bin/setup-opensnitch" "$@" 2>&1
}

HOME_FIXTURE="$(make_fake_home)"
ROOT_FIXTURE="$TEST_TMP/root"
make_fixture "$ROOT_FIXTURE"

cat > "$ROOT_FIXTURE/etc/opensnitchd/rules/old-local-name.json" <<'JSON'
{
  "name": "000-omarchy-allow-localhost-ipv4",
  "enabled": true,
  "action": "allow",
  "duration": "always",
  "operator": {"type": "simple", "operand": "dest.host", "data": "wrong.example"}
}
JSON
printf '{"name":"stale","enabled":true}\n' \
  > "$ROOT_FIXTURE/etc/opensnitchd/rules/omarchy-shared-stale.json"
printf '{"name":"user-local","enabled":true}\n' \
  > "$ROOT_FIXTURE/etc/opensnitchd/rules/user-local.json"

run_setup "$HOME_FIXTURE" "$ROOT_FIXTURE" > "$TEST_TMP/initial-setup.out"
setup_status=$?

it "completes against a supported OpenSnitch package"
assert_status 0 "$setup_status"

it "installs opensnitch through omarchy pkg add"
assert_file_contains "$STUBS/omarchy.log" "pkg add opensnitch"

it "sets daemon enforcement to deny"
assert_eq "deny" "$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["DefaultAction"])' "$ROOT_FIXTURE/etc/opensnitchd/default-config.json")"

it "uses nftables and eBPF with unknown traffic dropped"
daemon_values="$(python -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["Firewall"], c["ProcMonitorMethod"], c["InterceptUnknown"])' "$ROOT_FIXTURE/etc/opensnitchd/default-config.json")"
assert_eq "nftables ebpf False" "$daemon_values"

it "turns queue bypass off for fail-closed behavior"
assert_eq "False" "$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["FwOptions"]["QueueBypass"])' "$ROOT_FIXTURE/etc/opensnitchd/default-config.json")"

it "uses drop for newer overflow schemas"
assert_eq "drop" "$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["FwOptions"]["ActionOnOverflow"])' "$ROOT_FIXTURE/etc/opensnitchd/default-config.json")"

it "preserves unrelated package configuration"
assert_eq "6" "$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["Stats"]["Workers"])' "$ROOT_FIXTURE/etc/opensnitchd/default-config.json")"

it "uses the private per-user UI socket in daemon and GUI settings"
assert_contains "$(cat "$ROOT_FIXTURE/etc/opensnitchd/default-config.json" "$HOME_FIXTURE/.config/opensnitch/settings.conf")" "$HOME_FIXTURE/run/opensnitch/osui.sock"

it "keeps GUI prompts deny-by-default with temporary decisions"
assert_contains "$(cat "$HOME_FIXTURE/.config/opensnitch/settings.conf")" $'default_action=0\ndefault_duration=6'

it "adds the Omarchy-native GUI autostart entry"
assert_file_contains "$HOME_FIXTURE/.config/hypr/autostart.lua" 'o.launch_on_start("opensnitch-ui-secure")'

it "writes an executable private-socket UI launcher"
if [[ -x "$HOME_FIXTURE/.local/bin/opensnitch-ui-secure" ]]; then pass; else fail "launcher is not executable"; fi

it "imports the portable baseline rules"
assert_file "$ROOT_FIXTURE/etc/opensnitchd/rules/omarchy-shared-010-allow-systemd-resolved.json"

it "backs up and removes a duplicate local rule"
assert_no_file "$ROOT_FIXTURE/etc/opensnitchd/rules/old-local-name.json"
duplicate_backups=("$ROOT_FIXTURE"/etc/opensnitchd/rules/old-local-name.json.bak.*)
assert_file "${duplicate_backups[0]}"

it "prunes a stale repository-managed rule"
assert_no_file "$ROOT_FIXTURE/etc/opensnitchd/rules/omarchy-shared-stale.json"

it "never prunes an unrelated GUI-created rule"
assert_file "$ROOT_FIXTURE/etc/opensnitchd/rules/user-local.json"

it "enables and starts opensnitchd"
assert_file_contains "$STUBS/systemctl.log" "enable opensnitchd.service"
assert_file_contains "$STUBS/systemctl.log" "start opensnitchd.service"

sudo_writes_before="$(grep -cE '^(install|rm|cp)' "$STUBS/sudo.log" || true)"
system_writes_before="$(grep -cE '^(enable|start|restart)' "$STUBS/systemctl.log")"
out2="$(run_setup "$HOME_FIXTURE" "$ROOT_FIXTURE")"

it "a second run reports installed configuration as unchanged"
assert_contains "$out2" "already up to date"

it "a second run issues no root file writes"
assert_eq "$sudo_writes_before" "$(grep -cE '^(install|rm|cp)' "$STUBS/sudo.log" || true)" "sudo writes"

it "a second run does not restart or re-enable the service"
assert_eq "$system_writes_before" "$(grep -cE '^(enable|start|restart)' "$STUBS/systemctl.log")" "systemd writes"

# --- dry-run safety --------------------------------------------------------

DRY_HOME="$(make_fake_home)"
DRY_ROOT="$TEST_TMP/dry-root"
make_fixture "$DRY_ROOT"
config_before="$(cat "$DRY_ROOT/etc/opensnitchd/default-config.json")"
dry_out="$(run_setup "$DRY_HOME" "$DRY_ROOT" --dry-run)"

it "--dry-run previews package installation"
assert_contains "$dry_out" "omarchy pkg add opensnitch"

it "--dry-run leaves daemon configuration unchanged"
assert_eq "$config_before" "$(cat "$DRY_ROOT/etc/opensnitchd/default-config.json")" "daemon config"

it "--dry-run does not create user configuration"
assert_no_file "$DRY_HOME/.config/opensnitch/settings.conf"

it "--dry-run does not install shared rules"
installed_count="$(find "$DRY_ROOT/etc/opensnitchd/rules" -name 'omarchy-shared-*.json' | wc -l)"
assert_eq "0" "$installed_count" "installed shared rules"

# --- package policy --------------------------------------------------------

BAD_HOME="$(make_fake_home)"
BAD_ROOT="$TEST_TMP/bad-root"
make_fixture "$BAD_ROOT"
it "rejects opensnitch from a non-Extra package source"
FAKE_OPEN_SNITCH_REPO=community run_setup "$BAD_HOME" "$BAD_ROOT" >/dev/null 2>&1
assert_status 1 $?

it "help text is available without touching the system"
assert_contains "$("$REPO_ROOT/bin/setup-opensnitch" --help)" "deny-by-default"

it "rejects unknown arguments"
"$REPO_ROOT/bin/setup-opensnitch" --not-an-option >/dev/null 2>&1
assert_status 1 $?

# --- a running OpenSnitch UI ------------------------------------------------
#
# In a live Hyprland session the setup stops any running opensnitch-ui before
# rewriting its settings. Stopping one successfully must not be mistaken for a
# failure: the bug this pins down aborted the whole run, silently and with the
# user's UI already killed, precisely when the stop worked.

UI_HOME="$(make_fake_home)"
UI_ROOT="$TEST_TMP/ui-root"
UI_STUBS="$TEST_TMP/ui-stubs"
make_fixture "$UI_ROOT"
cp "$STUBS"/{sudo,omarchy,pacman,systemctl} "$UI_STUBS" 2>/dev/null || {
  mkdir -p "$UI_STUBS"; cp "$STUBS"/{sudo,omarchy,pacman,systemctl} "$UI_STUBS"; }

# Running the first time it is asked, gone thereafter — a UI that shuts down
# when told to.
# shellcheck disable=SC2016
stub_bin "$UI_STUBS" pgrep '
marker="${TEST_UI_MARKER:?}"
if [[ -f "$marker" ]]; then exit 1; fi
: > "$marker"
exit 0'
stub_bin "$UI_STUBS" pkill ':'
stub_bin "$UI_STUBS" hyprctl ':'

ui_out="$(HOME="$UI_HOME" XDG_RUNTIME_DIR="$UI_HOME/run" PATH="$UI_STUBS:$PATH" \
  FAKE_PKG_DB="$UI_ROOT/pkgdb" FAKE_UNIT_STATE="$UI_ROOT/units" \
  FAKE_OPEN_SNITCH_REPO=extra \
  TEST_UI_MARKER="$TEST_TMP/ui-stopped" \
  HYPRLAND_INSTANCE_SIGNATURE="test-session" \
  OPEN_SNITCH_DAEMON_CONFIG="$UI_ROOT/etc/opensnitchd/default-config.json" \
  OPEN_SNITCH_RULES_DIR="$UI_ROOT/etc/opensnitchd/rules" \
  OPEN_SNITCH_SHARED_RULES_DIR="$UI_ROOT/shared" \
  OPEN_SNITCH_EBPF_OBJECT="$UI_ROOT/ebpf.o" \
  OPEN_SNITCH_GUI_SETTINGS="$UI_HOME/.config/opensnitch/settings.conf" \
  OPEN_SNITCH_AUTOSTART_FILE="$UI_HOME/.config/hypr/autostart.lua" \
  OPEN_SNITCH_UI_LAUNCHER="$UI_HOME/.local/bin/opensnitch-ui-secure" \
  OPEN_SNITCH_SKIP_LIVE_UI=1 \
  "$REPO_ROOT/bin/setup-opensnitch" 2>&1)"
ui_status=$?

it "does not abort after successfully stopping a running UI"
assert_status 0 "$ui_status"

it "carries on past the stop and configures the daemon"
assert_contains "$ui_out" "Synchronizing repository-managed OpenSnitch rules"

it "installs the baseline even when a UI had to be stopped first"
assert_file "$UI_ROOT/etc/opensnitchd/rules/omarchy-shared-010-allow-systemd-resolved.json"

# --- shape of the committed baseline ---------------------------------------
#
# The baseline is the one rule set that ships to every machine, so a mistake
# here is a mistake everywhere. These checks are about shape, not content: the
# rules stay allow-only, take precedence over learned denies, name the
# executable they were written for, and explain themselves.

shape_report="$(python - "$REPO_ROOT/config/opensnitch/rules" <<'SHAPE'
import json, pathlib, re, sys

problems = []
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    try:
        rule = json.loads(path.read_text())
    except ValueError as error:
        problems.append(f"{path.name}: invalid JSON ({error})")
        continue

    prefix = re.match(r"omarchy-shared-(\d{3})-", path.name)
    if not prefix:
        problems.append(f"{path.name}: filename lacks an omarchy-shared-NNN- prefix")
    elif not str(rule.get("name", "")).startswith(prefix.group(1) + "-"):
        problems.append(f"{path.name}: name {rule.get('name')!r} does not start with {prefix.group(1)}-")

    if rule.get("action") != "allow":
        problems.append(f"{path.name}: baseline rules are allow-only, not {rule.get('action')!r}")
    if rule.get("duration") != "always":
        problems.append(f"{path.name}: baseline rules must be permanent")
    if rule.get("enabled") is not True:
        problems.append(f"{path.name}: baseline rules must ship enabled")
    if rule.get("precedence") is not True:
        problems.append(f"{path.name}: baseline rules must outrank learned denies")

    operands = set()

    def walk(operator):
        if not isinstance(operator, dict):
            return
        operands.add(operator.get("operand"))
        for child in operator.get("list") or []:
            walk(child)

    walk(rule.get("operator"))

    # Localhost is matched by destination alone. Every other baseline rule must
    # name the executable it was written for, or it is a process-wide hole.
    if "dest.network" not in operands and "process.path" not in operands:
        problems.append(f"{path.name}: no process.path, so it is not scoped to one executable")

    machine_specific = operands & {"user.id", "process.command"}
    if machine_specific:
        problems.append(f"{path.name}: {sorted(machine_specific)} does not belong in a portable rule")

    # A home path carries a username, so the rule only ever matches on the
    # machine it was written on. export-opensnitch-rules already refuses these;
    # the baseline has to refuse them too, or a tool installed under ~/ (mise,
    # cargo, npm) quietly becomes an unportable "portable" rule.
    def data_of(operator):
        if not isinstance(operator, dict):
            return
        yield str(operator.get("data", ""))
        for child in operator.get("list") or []:
            yield from data_of(child)

    for value in data_of(rule.get("operator")):
        if "/home/" in value or value.startswith("~/"):
            problems.append(f"{path.name}: home path {value!r} cannot be portable")
            break

print("\n".join(problems))
SHAPE
)"

it "every committed baseline rule keeps the shared-rule shape"
assert_eq "" "$shape_report" "baseline rule problems"

it "ships the full baseline: system essentials, maintenance, and repo workflows"
baseline_count="$(find "$REPO_ROOT/config/opensnitch/rules" -name 'omarchy-shared-*.json' | wc -l)"
assert_eq "11" "$baseline_count" "baseline rule count"

finish

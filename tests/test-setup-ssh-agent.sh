#!/usr/bin/env bash
# bin/setup-ssh-agent — against a throwaway HOME with stubbed system commands.
# Nothing here touches the real ~/.ssh, systemd, or a running agent.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

FAKE_HOME="$(make_fake_home)"
STUBS="$TEST_TMP/stubs"

# systemctl: nothing enabled, nothing active, nothing in the environment — the
# state of a machine that has never been set up. Stateful about enabling, so
# the script's own "did the socket actually start?" check sees the truth.
# Stub bodies are literal shell, expanded when the stub runs, not now.
# shellcheck disable=SC2016
stub_bin "$STUBS" systemctl '
state="$(dirname "$0")/enabled"
case "$*" in
  *"enable --now"*)     touch "$state"; exit 0 ;;
  *"is-enabled"*)       echo disabled; exit 1 ;;
  *"is-active"*)        [[ -f "$state" ]] && exit 0 || exit 3 ;;
  *"show-environment"*) exit 0 ;;
  *) exit 0 ;;
esac'
stub_bin "$STUBS" ssh-agent 'exit 0'
stub_bin "$STUBS" ssh-add 'case "$*" in *-l*) exit 1 ;; *) exit 0 ;; esac'

# A real key, so key discovery and fingerprinting are exercised for real.
ssh-keygen -q -t ed25519 -N '' -C test -f "$FAKE_HOME/.ssh/work_key_2026" </dev/null

# The script only adds keys once the agent socket exists; give it a real one.
make_socket "$FAKE_HOME/run/ssh-agent.socket"

ssh_agent_setup() {
  env HOME="$FAKE_HOME" \
      XDG_RUNTIME_DIR="$FAKE_HOME/run" \
      PATH="$STUBS:$PATH" \
      SSH_AGENT_PID= SSH_AUTH_SOCK= \
      "$REPO_ROOT/bin/setup-ssh-agent" "$@" 2>&1
}

ENV_FILE="$FAKE_HOME/.config/environment.d/10-ssh-agent.conf"
SSH_CONFIG="$FAKE_HOME/.ssh/config"

# --- dry run changes nothing ---

it "--dry-run writes no environment.d file"
ssh_agent_setup --dry-run --yes >/dev/null
assert_no_file "$ENV_FILE"

it "--dry-run writes no ssh config"
assert_no_file "$SSH_CONFIG"

# --- real run against the fake home ---

out="$(ssh_agent_setup --yes)"

it "writes the environment.d file"
assert_file_contains "$ENV_FILE" "SSH_AUTH_SOCK="

it "keeps XDG_RUNTIME_DIR unexpanded so systemd expands it, not bash"
# The literal string is exactly what must appear in the file.
# shellcheck disable=SC2016
assert_file_contains "$ENV_FILE" '${XDG_RUNTIME_DIR}/ssh-agent.socket'

it "enables the socket unit"
assert_file_contains "$STUBS/systemctl.log" "enable --now ssh-agent.socket"

it "appends the marked block to ssh config"
assert_file_contains "$SSH_CONFIG" "omarchy-scripts: ssh-agent"

it "sets AddKeysToAgent"
assert_file_contains "$SSH_CONFIG" "AddKeysToAgent yes"

it "does not set IdentitiesOnly, which would hide non-default key names"
if grep -q "IdentitiesOnly" "$SSH_CONFIG"; then
  fail "IdentitiesOnly must not be set under Host *"
else
  pass
fi

it "tightens ssh config permissions"
assert_eq "600" "$(stat -c '%a' "$SSH_CONFIG")" "config mode"

it "finds a key that does not use a default id_* name"
assert_contains "$out" "added work_key_2026"

it "warns that the current shell still points elsewhere"
assert_contains "$out" "still points at another agent"

# --- idempotence: the property the whole project rests on ---

env_before="$(cat "$ENV_FILE")"
config_before="$(cat "$SSH_CONFIG")"
out2="$(ssh_agent_setup --yes)"

it "a second run leaves environment.d byte-identical"
assert_eq "$env_before" "$(cat "$ENV_FILE")" "environment.d contents"

it "a second run leaves ssh config byte-identical"
assert_eq "$config_before" "$(cat "$SSH_CONFIG")" "ssh config contents"

it "a second run reports the environment file as already up to date"
assert_contains "$out2" "already up to date"

it "a second run does not duplicate the ssh config block"
assert_eq "1" "$(grep -c 'omarchy-scripts: ssh-agent >>>' "$SSH_CONFIG")" "marker count"

it "a second run says the ssh config block is already present"
assert_contains "$out2" "already present"

it "a second run creates no further backups"
assert_eq "1" "$(find "$FAKE_HOME/.ssh" -name 'config.bak.*' | wc -l)" "backup count"

# --- conflicting agents ---

CONFLICT_HOME="$(make_fake_home)"
CONFLICT_STUBS="$TEST_TMP/stubs-conflict"
# shellcheck disable=SC2016
stub_bin "$CONFLICT_STUBS" systemctl '
case "$*" in
  *"is-enabled gcr-ssh-agent.socket"*) echo enabled; exit 0 ;;
  *"is-enabled gpg-agent-ssh.socket"*) echo static; exit 0 ;;
  *"is-enabled"*)       echo disabled; exit 1 ;;
  *"is-active"*)        exit 0 ;;
  *"show-environment"*) exit 0 ;;
  *) exit 0 ;;
esac'
stub_bin "$CONFLICT_STUBS" ssh-agent 'exit 0'
stub_bin "$CONFLICT_STUBS" ssh-add 'case "$*" in *-l*) exit 1 ;; *) exit 0 ;; esac'

conflict_out="$(env HOME="$CONFLICT_HOME" XDG_RUNTIME_DIR="$CONFLICT_HOME/run" \
  PATH="$CONFLICT_STUBS:$PATH" SSH_AGENT_PID= SSH_AUTH_SOCK= \
  "$REPO_ROOT/bin/setup-ssh-agent" --yes 2>&1)"

it "disables an enabled competing agent"
assert_file_contains "$CONFLICT_STUBS/systemctl.log" "disable --now gcr-ssh-agent.socket"

it "masks a static competing agent, which cannot be disabled"
assert_file_contains "$CONFLICT_STUBS/systemctl.log" "mask --now gpg-agent-ssh.socket"

it "warns about the conflict it found"
assert_contains "$conflict_out" "fight over SSH_AUTH_SOCK"

# --- refuses to run as root ---

it "help text is available without touching the system"
out="$(ssh_agent_setup --help)"
assert_contains "$out" "Usage: setup-ssh-agent"

it "rejects unknown arguments"
ssh_agent_setup --not-a-flag >/dev/null 2>&1
assert_status 1 $?

finish

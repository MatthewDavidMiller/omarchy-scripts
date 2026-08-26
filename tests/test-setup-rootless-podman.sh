#!/usr/bin/env bash
# bin/setup-rootless-podman — against a throwaway HOME with a stubbed omarchy,
# pacman, systemctl, usermod, ufw and podman. Nothing here touches the real
# package database, systemd, /etc/subuid or the firewall.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"

# sudo just runs the command; the stub records that sudo was used at all.
stub_bin "$STUBS" sudo 'exec "$@"'

# newuidmap/newgidmap only have to exist — the script checks for them because
# rootless podman is silently broken without them.
stub_bin "$STUBS" newuidmap 'exit 0'
stub_bin "$STUBS" newgidmap 'exit 0'

# Stub bodies are literal shell, expanded when the stub runs, not now.
# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
db="${FAKE_PKG_DB:?}"
verb="$1 $2"; shift 2
case "$verb" in
  "pkg present") for p in "$@"; do [[ -f "$db/$p" ]] || exit 1; done ;;
  "pkg add")     for p in "$@"; do : > "$db/$p"; done ;;
  "pkg drop")    for p in "$@"; do rm -f "$db/$p"; done ;;
  *) echo "unexpected: $verb $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" pacman '
db="${FAKE_PKG_DB:?}"
case "$1" in
  -Qq) [[ -f "$db/$2" ]] ;;
  -Rs) shift 2
       for p in "$@"; do printf "%s-1.0-1\n" "$p"; done
       printf "containerd-2.3.4-1\n" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# Stateful about enabling and stopping, so the script sees the truth it just
# created rather than a stub that always agrees.
# shellcheck disable=SC2016
stub_bin "$STUBS" systemctl '
state="${FAKE_UNIT_STATE:?}"
args="$*"
unit="${args##* }"
case "$args" in
  --user*enable*--now*) : > "$state/user-$unit"; exit 0 ;;
  --user*is-enabled*|--user*is-active*)
    [[ -f "$state/user-$unit" ]] && exit 0 || exit 3 ;;
  cat\ *)              [[ -f "$state/system-$unit" ]] && exit 0 || exit 1 ;;
  disable*--now*)      rm -f "$state/system-$unit"; exit 0 ;;
  is-enabled*)         [[ -f "$state/system-$unit" ]] && { echo enabled; exit 0; }
                       echo disabled; exit 1 ;;
  is-active*)          [[ -f "$state/system-$unit" ]] && exit 0 || exit 3 ;;
  *) exit 0 ;;
esac'

# usermod writes the ranges the way shadow does, so "did the range actually
# land, and where" is a real check rather than a recorded intention.
# shellcheck disable=SC2016
stub_bin "$STUBS" usermod '
while [[ $# -gt 1 ]]; do
  case "$1" in
    --add-subuids) uids="$2"; shift ;;
    --add-subgids) gids="$2"; shift ;;
  esac
  shift
done
user="$1"
printf "%s:%s:%s\n" "$user" "${uids%%-*}" "$(( ${uids##*-} - ${uids%%-*} + 1 ))" >> "${SUBUID_FILE:?}"
printf "%s:%s:%s\n" "$user" "${gids%%-*}" "$(( ${gids##*-} - ${gids%%-*} + 1 ))" >> "${SUBGID_FILE:?}"'

# shellcheck disable=SC2016
stub_bin "$STUBS" podman '
case "$*" in
  "info --format {{.Host.Security.Rootless}}") echo "${FAKE_ROOTLESS:-true}" ;;
  "info --format {{.Host.OCIRuntime.Name}}")   echo crun ;;
  "info --format {{.Store.GraphDriverName}}")  echo overlay ;;
  "system migrate") : > "${FAKE_MIGRATED:-/dev/null}" ;;
  *) exit 0 ;;
esac'

# The ufw stub edits the fixture the way real ufw edits /etc/ufw/user.rules.
# shellcheck disable=SC2016
stub_bin "$STUBS" ufw '
case "$1" in
  delete) src=""
          for a in "$@"; do [[ "$prev" == "from" ]] && src="$a"; prev="$a"; done
          sed -i "\#$src#d" "$UFW_RULES_DIR/user.rules" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# --- fixtures --------------------------------------------------------------

# make_pkg_db [pkg...] — a package database holding exactly these packages.
make_pkg_db() {
  local db="$TEST_TMP/pkgdb.$RANDOM" pkg
  mkdir -p "$db"
  for pkg in "$@"; do : > "$db/$pkg"; done
  printf '%s' "$db"
}

# make_unit_state [unit...] — the system units that are enabled and running.
# podman.socket is always absent: the script is what enables it.
make_unit_state() {
  local dir="$TEST_TMP/units.$RANDOM" unit
  mkdir -p "$dir"
  for unit in "$@"; do : > "$dir/system-$unit"; done
  printf '%s' "$dir"
}

# make_subid_file — an empty /etc/subuid-shaped file, as a machine that has
# never run a rootless container has.
make_subid_file() {
  local file="$TEST_TMP/subid.$RANDOM"
  : > "$file"
  printf '%s' "$file"
}

# make_ufw_fixture — a rules dir shaped like a stock omarchy one: the docker
# DNS pair, plus a LocalSend rule that must survive untouched.
make_ufw_fixture() {
  local dir="$TEST_TMP/ufw.$RANDOM"
  mkdir -p "$dir"
  {
    printf '*filter\n### RULES ###\n\n'
    printf '### tuple ### allow udp 53 172.17.0.1 any 172.16.0.0/12 in comment=616c6c6f77\n'
    printf -- '-A ufw-user-input -p udp -d 172.17.0.1 --dport 53 -s 172.16.0.0/12 -j ACCEPT\n\n'
    printf '### tuple ### allow udp 53 172.17.0.1 any 192.168.0.0/16 in comment=616c6c6f77\n'
    printf -- '-A ufw-user-input -p udp -d 172.17.0.1 --dport 53 -s 192.168.0.0/16 -j ACCEPT\n\n'
    printf '### tuple ### allow tcp 53317 0.0.0.0/0 any 0.0.0.0/0 in\n'
    printf -- '-A ufw-user-input -p tcp --dport 53317 -j ACCEPT\n\n'
    printf '### END RULES ###\n'
  } > "$dir/user.rules"
  : > "$dir/user6.rules"
  printf '%s' "$dir"
}

# A whole machine: stock omarchy, docker installed and running, no podman.
# Echoes "HOME PKGDB UNITS SUBUID SUBGID UFW" for the caller to read apart.
make_machine() {
  local home pkgdb units subuid subgid ufw
  home="$(make_fake_home)"
  pkgdb="$(make_pkg_db docker docker-buildx docker-compose ufw-docker lazydocker)"
  units="$(make_unit_state docker.socket docker.service)"
  subuid="$(make_subid_file)"
  subgid="$(make_subid_file)"
  ufw="$(make_ufw_fixture)"
  printf '%s %s %s %s %s %s' "$home" "$pkgdb" "$units" "$subuid" "$subgid" "$ufw"
}

read -r HOME_DIR PKGDB UNITS SUBUID SUBGID UFWDIR <<< "$(make_machine)"

podman_setup() {
  env HOME="$HOME_DIR" \
      USER=tester \
      XDG_RUNTIME_DIR="$HOME_DIR/run" \
      PATH="$STUBS:$PATH" \
      FAKE_PKG_DB="$PKGDB" \
      FAKE_UNIT_STATE="$UNITS" \
      SUBUID_FILE="$SUBUID" \
      SUBGID_FILE="$SUBGID" \
      UFW_RULES_DIR="$UFWDIR" \
      DOCKER_DATA_DIR="$HOME_DIR/var-lib-docker" \
      "$REPO_ROOT/bin/setup-rootless-podman" "$@" 2>&1
}

ENV_FILE="$HOME_DIR/.config/environment.d/20-podman.conf"

# --- dry run changes nothing ----------------------------------------------

out="$(podman_setup --dry-run --yes)"

it "--dry-run writes no environment.d file"
assert_no_file "$ENV_FILE"

it "--dry-run installs nothing"
assert_no_file "$PKGDB/podman"

it "--dry-run removes nothing"
assert_file "$PKGDB/docker"

it "--dry-run grants no subordinate ids"
assert_eq "" "$(cat "$SUBUID")" "subuid file"

it "--dry-run leaves the firewall alone"
assert_file_contains "$UFWDIR/user.rules" "172.16.0.0/12"

it "--dry-run still says what it would install"
assert_contains "$out" "omarchy pkg add podman crun"

it "--dry-run still says what it would remove"
assert_contains "$out" "omarchy pkg drop docker"

# --- the real run ----------------------------------------------------------

out="$(podman_setup --yes)"

it "installs podman"
assert_file "$PKGDB/podman"

it "installs crun, so podman is not left sharing docker's runtime"
assert_file "$PKGDB/crun"

it "grants the user a subuid range"
assert_file_contains "$SUBUID" "tester:100000:65536"

it "grants a matching subgid range"
assert_file_contains "$SUBGID" "tester:100000:65536"

it "enables the user podman socket"
if [[ -f "$UNITS/user-podman.socket" ]]; then pass; else fail "podman.socket was not enabled"; fi

# The variable must reach the file unexpanded: systemd expands it per session,
# and this script may well run in one whose XDG_RUNTIME_DIR is not the user's.
it "points DOCKER_HOST at the user's podman socket"
# shellcheck disable=SC2016
assert_file_contains "$ENV_FILE" 'DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock'

it "tells omarchy's Docker TUI it no longer needs to elevate"
# shellcheck disable=SC2016
assert_file_contains "$ENV_FILE" 'OMARCHY_DOCKER_SOCKET=${XDG_RUNTIME_DIR}/podman/podman.sock'

it "stops docker before removing it"
assert_no_file "$UNITS/system-docker.socket"

it "removes the docker package"
assert_no_file "$PKGDB/docker"

it "removes docker-buildx, which needs a daemon podman does not run"
assert_no_file "$PKGDB/docker-buildx"

it "removes ufw-docker, which depends on docker"
assert_no_file "$PKGDB/ufw-docker"

it "keeps docker-compose, which drives the API and not the daemon"
assert_file "$PKGDB/docker-compose"

it "keeps lazydocker, which is just another API client"
assert_file "$PKGDB/lazydocker"

it "installs the docker CLI shim once the conflict is gone"
assert_file "$PKGDB/podman-docker"

it "installs the shim after the removal, never before"
assert_eq "1" "$(awk '/^pkg drop docker/{drop=NR} /^pkg add podman-docker/{add=NR} END{print (drop && add && add > drop) ? 1 : 0}' "$STUBS/omarchy.log")" "ordering"

it "closes the host resolver to the docker bridge"
assert_not_contains "$(cat "$UFWDIR/user.rules")" "172.16.0.0/12"

it "closes it for the second source range too"
assert_not_contains "$(cat "$UFWDIR/user.rules")" "192.168.0.0/16"

it "leaves firewall rules that have nothing to do with docker"
assert_file_contains "$UFWDIR/user.rules" "53317"

it "verifies that podman actually came up rootless"
assert_contains "$out" "podman is running rootless"

it "reports the daemon's leftover data rather than deleting it"
mkdir -p "$HOME_DIR/var-lib-docker"
assert_contains "$(podman_setup --yes)" "still holds Docker's old images"

# --- idempotence -----------------------------------------------------------

adds_before="$(grep -c '^pkg add' "$STUBS/omarchy.log")"
subuid_before="$(cat "$SUBUID")"
out2="$(podman_setup --yes)"
adds_after="$(grep -c '^pkg add' "$STUBS/omarchy.log")"

it "a second run installs nothing"
assert_eq "$adds_before" "$adds_after" "pkg add calls"

it "a second run does not hand out a second subuid range"
assert_eq "$subuid_before" "$(cat "$SUBUID")" "subuid file"

it "a second run reports the packages as already installed"
assert_contains "$out2" "already installed"

it "a second run reports the socket as already enabled"
assert_contains "$out2" "podman.socket already enabled"

it "a second run leaves the environment.d file untouched"
assert_contains "$out2" "already up to date"

it "a second run reports docker as already gone"
assert_contains "$out2" "Docker is not installed"

it "a second run reports the firewall as already closed"
assert_contains "$out2" "already closed"

it "a second run exits successfully"
podman_setup --yes >/dev/null 2>&1
assert_status 0 $?

# --- declining the removal -------------------------------------------------

read -r HOME_DIR PKGDB UNITS SUBUID SUBGID UFWDIR <<< "$(make_machine)"
ENV_FILE="$HOME_DIR/.config/environment.d/20-podman.conf"

decline_out="$(printf 'n\n' | podman_setup)"

it "lists the packages before asking to remove them"
assert_contains "$decline_out" "containerd-2.3.4-1"

it "declining leaves docker installed"
assert_file "$PKGDB/docker"

it "declining does not touch the firewall"
assert_file_contains "$UFWDIR/user.rules" "172.16.0.0/12"

it "declining does not install a conflicting docker CLI shim"
assert_no_file "$PKGDB/podman-docker"

it "declining still leaves podman set up"
assert_file "$PKGDB/podman"

# --- --keep-docker ---------------------------------------------------------

read -r HOME_DIR PKGDB UNITS SUBUID SUBGID UFWDIR <<< "$(make_machine)"
ENV_FILE="$HOME_DIR/.config/environment.d/20-podman.conf"

keep_out="$(podman_setup --yes --keep-docker)"

it "--keep-docker installs podman"
assert_file "$PKGDB/podman"

it "--keep-docker leaves docker installed"
assert_file "$PKGDB/docker"

it "--keep-docker leaves docker running"
assert_file "$UNITS/system-docker.socket"

it "--keep-docker does not install the conflicting CLI shim"
assert_no_file "$PKGDB/podman-docker"

it "--keep-docker says how to reach the docker daemon anyway"
assert_contains "$keep_out" "DOCKER_HOST=unix:///var/run/docker.sock"

# --- --keep-firewall-rules -------------------------------------------------

read -r HOME_DIR PKGDB UNITS SUBUID SUBGID UFWDIR <<< "$(make_machine)"
ENV_FILE="$HOME_DIR/.config/environment.d/20-podman.conf"

podman_setup --yes --keep-firewall-rules >/dev/null 2>&1

it "--keep-firewall-rules still removes docker"
assert_no_file "$PKGDB/docker"

it "--keep-firewall-rules leaves the docker DNS rules in place"
assert_file_contains "$UFWDIR/user.rules" "172.16.0.0/12"

# --- subordinate id allocation ---------------------------------------------

read -r HOME_DIR PKGDB UNITS SUBUID SUBGID UFWDIR <<< "$(make_machine)"
ENV_FILE="$HOME_DIR/.config/environment.d/20-podman.conf"
printf 'someone:100000:65536\n' > "$SUBUID"
printf 'someone:100000:65536\n' > "$SUBGID"

podman_setup --yes >/dev/null 2>&1

it "starts the range above every range already handed out"
assert_file_contains "$SUBUID" "tester:165536:65536"

it "does not overlap the account that was already there"
assert_file_contains "$SUBUID" "someone:100000:65536"

it "falls back to id(1) when USER is unset, rather than granting a range to nobody"
read -r HOME_DIR PKGDB UNITS SUBUID SUBGID UFWDIR <<< "$(make_machine)"
env -u USER HOME="$HOME_DIR" XDG_RUNTIME_DIR="$HOME_DIR/run" PATH="$STUBS:$PATH" \
    FAKE_PKG_DB="$PKGDB" FAKE_UNIT_STATE="$UNITS" \
    SUBUID_FILE="$SUBUID" SUBGID_FILE="$SUBGID" UFW_RULES_DIR="$UFWDIR" \
    "$REPO_ROOT/bin/setup-rootless-podman" --yes >/dev/null 2>&1
assert_file_contains "$SUBUID" "$(id -un):100000:65536"

# --- migrating an existing rootless store ----------------------------------

read -r HOME_DIR PKGDB UNITS SUBUID SUBGID UFWDIR <<< "$(make_machine)"
ENV_FILE="$HOME_DIR/.config/environment.d/20-podman.conf"
mkdir -p "$HOME_DIR/.local/share/containers/storage"
MIGRATED="$HOME_DIR/migrated"

it "migrates an existing rootless store onto the new id mapping"
env FAKE_MIGRATED="$MIGRATED" HOME="$HOME_DIR" USER=tester \
    XDG_RUNTIME_DIR="$HOME_DIR/run" PATH="$STUBS:$PATH" \
    FAKE_PKG_DB="$PKGDB" FAKE_UNIT_STATE="$UNITS" \
    SUBUID_FILE="$SUBUID" SUBGID_FILE="$SUBGID" UFW_RULES_DIR="$UFWDIR" \
    "$REPO_ROOT/bin/setup-rootless-podman" --yes >/dev/null 2>&1
if [[ -f "$MIGRATED" ]]; then pass; else fail "podman system migrate was not run"; fi

# --- failure modes ---------------------------------------------------------

read -r HOME_DIR PKGDB UNITS SUBUID SUBGID UFWDIR <<< "$(make_machine)"

it "fails loudly if podman ends up running as root"
out="$(env FAKE_ROOTLESS=false HOME="$HOME_DIR" USER=tester \
    XDG_RUNTIME_DIR="$HOME_DIR/run" PATH="$STUBS:$PATH" \
    FAKE_PKG_DB="$PKGDB" FAKE_UNIT_STATE="$UNITS" \
    SUBUID_FILE="$SUBUID" SUBGID_FILE="$SUBGID" UFW_RULES_DIR="$UFWDIR" \
    "$REPO_ROOT/bin/setup-rootless-podman" --yes 2>&1)" && status=0 || status=$?
assert_contains "$out" "podman is running as root"

it "exits non-zero when it does"
assert_status 1 "$status"

# --- argument handling -----------------------------------------------------

it "help text is available without touching the system"
assert_contains "$(podman_setup --help)" "Usage: setup-rootless-podman"

it "rejects unknown arguments"
podman_setup --not-a-flag >/dev/null 2>&1
assert_status 1 $?

it "dies when omarchy is not installed"
MINIMAL="$TEST_TMP/minimal-path"
mkdir -p "$MINIMAL"
for cmd in bash dirname; do ln -sf "$(command -v "$cmd")" "$MINIMAL/$cmd"; done
env HOME="$HOME_DIR" USER=tester PATH="$MINIMAL" \
  "$REPO_ROOT/bin/setup-rootless-podman" --yes >/dev/null 2>&1
assert_status 1 $?

finish

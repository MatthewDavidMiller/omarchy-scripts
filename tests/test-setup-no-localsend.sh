#!/usr/bin/env bash
# bin/setup-no-localsend — against fixture ufw rules files and a stubbed
# pacman/ufw/sudo/flatpak. The ufw stub edits the fixture the way real ufw
# edits /etc/ufw/user.rules, so "did the rule actually go" is a real check.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"

# sudo just runs the command; the stub records that sudo was used at all.
stub_bin "$STUBS" sudo 'exec "$@"'

# Stub bodies are literal shell, expanded when the stub runs, not now.
# shellcheck disable=SC2016
stub_bin "$STUBS" ufw '
v4="$UFW_RULES_DIR/user.rules"
v6="$UFW_RULES_DIR/user6.rules"
case "$1" in
  show)
    [[ -n "${FAKE_SHOW_ADDED:-}" ]] && cat "$FAKE_SHOW_ADDED" ;;
  delete)
    proto="${3##*/}"
    sed -i "/allow $proto 53317/d; /-p $proto --dport 53317/d" "$v4" "$v6" ;;
  allow)
    proto="${2##*/}"
    for f in "$v4" "$v6"; do
      sed -i "/### END RULES ###/i ### tuple ### allow $proto 53317 0.0.0.0/0 any 0.0.0.0/0 in\n-A ufw-user-input -p $proto --dport 53317 -j ACCEPT" "$f"
    done ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" pacman '
db="${FAKE_PKG_DB:?}"
case "$*" in
  "-Qq localsend")                     [[ -f $db ]] ;;
  "-Qq localsend-bin")                 exit 1 ;;
  "-Rs --print localsend")             printf "localsend-1.18.1-2\nlibayatana-appindicator-0.6.0-1\n" ;;
  "-Rs --noconfirm localsend")         rm -f "$db" ;;
  "-S --needed --noconfirm localsend") : > "$db" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" flatpak '
case "$1" in
  info)      [[ "${FAKE_FLATPAK:-0}" == "1" ]] ;;
  uninstall) : > "${FLATPAK_MARKER:?}" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# make_ufw_fixture [with-localsend] — a rules dir shaped like a stock omarchy
# one: the docker DNS rules always, the LocalSend pair only when asked.
make_ufw_fixture() {
  local dir="$TEST_TMP/ufw.$RANDOM" localsend="${1:-yes}"
  mkdir -p "$dir"

  {
    printf '*filter\n### RULES ###\n\n'
    printf '### tuple ### allow udp 53 172.17.0.1 any 172.16.0.0/12 in comment=616c6c6f77\n'
    printf -- '-A ufw-user-input -p udp -d 172.17.0.1 --dport 53 -s 172.16.0.0/12 -j ACCEPT\n\n'
    if [[ "$localsend" == "yes" ]]; then
      printf '### tuple ### allow udp 53317 0.0.0.0/0 any 0.0.0.0/0 in\n'
      printf -- '-A ufw-user-input -p udp --dport 53317 -j ACCEPT\n\n'
      printf '### tuple ### allow tcp 53317 0.0.0.0/0 any 0.0.0.0/0 in\n'
      printf -- '-A ufw-user-input -p tcp --dport 53317 -j ACCEPT\n\n'
    fi
    printf '### END RULES ###\nCOMMIT\n'
  } > "$dir/user.rules"

  {
    printf '*filter\n### RULES ###\n\n'
    if [[ "$localsend" == "yes" ]]; then
      printf '### tuple ### allow udp 53317 ::/0 any ::/0 in\n'
      printf -- '-A ufw6-user-input -p udp --dport 53317 -j ACCEPT\n\n'
      printf '### tuple ### allow tcp 53317 ::/0 any ::/0 in\n'
      printf -- '-A ufw6-user-input -p tcp --dport 53317 -j ACCEPT\n\n'
    fi
    printf '### END RULES ###\nCOMMIT\n'
  } > "$dir/user6.rules"

  printf '%s' "$dir"
}

# no_localsend <rules-dir> <pkg-db> [args...]
no_localsend() {
  local rules="$1" db="$2"; shift 2
  env PATH="$STUBS:$PATH" \
      UFW_RULES_DIR="$rules" \
      FAKE_PKG_DB="$db" \
      FLATPAK_MARKER="$TEST_TMP/flatpak-removed.$RANDOM" \
      "$REPO_ROOT/bin/setup-no-localsend" "$@" 2>&1
}

rules_have() { grep -q "53317" "$1/user.rules" "$1/user6.rules"; }

# --- dry run changes nothing -----------------------------------------------

RULES="$(make_ufw_fixture)"
DB="$TEST_TMP/pkg.installed"; : > "$DB"

out="$(no_localsend "$RULES" "$DB" --dry-run --yes)"

it "--dry-run leaves the firewall rules in place"
if rules_have "$RULES"; then pass; else fail "expected 53317 rules to survive a dry run"; fi

it "--dry-run leaves the package installed"
if [[ -f "$DB" ]]; then pass; else fail "expected localsend to survive a dry run"; fi

it "--dry-run still says what it would do"
assert_contains "$out" "sudo ufw delete allow 53317/udp"

it "--dry-run lists the packages it would remove"
assert_contains "$out" "libayatana-appindicator"

# --- real run ---------------------------------------------------------------

out="$(no_localsend "$RULES" "$DB" --yes)"

it "deletes the LocalSend rules"
if rules_have "$RULES"; then fail "53317 still allowed"; else pass; fi

it "deletes the IPv6 half too"
assert_not_contains "$(cat "$RULES/user6.rules")" "53317"

it "leaves the docker DNS rules alone"
assert_file_contains "$RULES/user.rules" "--dport 53 -s 172.16.0.0/12"

it "goes through sudo for the firewall change"
assert_file_contains "$STUBS/sudo.log" "ufw delete allow 53317/tcp"

it "uninstalls the package"
assert_no_file "$DB"

it "reports the resulting state"
assert_contains "$out" "package:  not installed"

it "warns that omarchy's Share entries now do nothing"
assert_contains "$out" "Share → Receive"

# --- second run is a no-op --------------------------------------------------

before="$(wc -l < "$STUBS/pacman.log")"
out2="$(no_localsend "$RULES" "$DB" --yes)"

it "a second run skips the udp rule"
assert_contains "$out2" "53317/udp already closed"

it "a second run skips the tcp rule"
assert_contains "$out2" "53317/tcp already closed"

it "a second run skips the package"
assert_contains "$out2" "localsend is not installed"

it "a second run issues no ufw or pacman write commands"
writes="$(grep -cE 'ufw (delete )?allow|pacman -(Rs --noconfirm|S )' "$STUBS/sudo.log" || true)"
assert_eq "3" "$writes" "cumulative write commands"
# Guards the count above against a stub that stopped logging entirely.
it "the second run did query pacman"
if [[ "$(wc -l < "$STUBS/pacman.log")" -gt "$before" ]]; then pass; else fail "no calls logged"; fi

it "a second run never needs sudo to decide"
# Everything it read came from the world-readable rules file.
assert_not_contains "$out2" "ufw show added"

# --- reversing --------------------------------------------------------------

out3="$(no_localsend "$RULES" "$DB" --allow-localsend --yes)"

it "--allow-localsend puts the rules back"
if rules_have "$RULES"; then pass; else fail "expected 53317 rules to return"; fi

it "--allow-localsend reinstalls the package"
if [[ -f "$DB" ]]; then pass; else fail "expected localsend to be reinstalled"; fi

it "--allow-localsend says the stock setup is back"
assert_contains "$out3" "the way omarchy ships it"

it "--allow-localsend a second time changes nothing"
assert_contains "$(no_localsend "$RULES" "$DB" --allow-localsend --yes)" "already allowed"

# --- --keep-package ---------------------------------------------------------

KEEP_RULES="$(make_ufw_fixture)"
KEEP_DB="$TEST_TMP/keep.installed"; : > "$KEEP_DB"
keep_out="$(no_localsend "$KEEP_RULES" "$KEEP_DB" --keep-package --yes)"

it "--keep-package still closes the port"
if rules_have "$KEEP_RULES"; then fail "53317 still allowed"; else pass; fi

it "--keep-package leaves the app installed"
if [[ -f "$KEEP_DB" ]]; then pass; else fail "expected localsend to survive"; fi

it "--keep-package says so"
assert_contains "$keep_out" "leaving LocalSend installed"

# --- declining the removal --------------------------------------------------

NO_RULES="$(make_ufw_fixture)"
NO_DB="$TEST_TMP/declined.installed"; : > "$NO_DB"
decline_out="$(printf 'n\n' | no_localsend "$NO_RULES" "$NO_DB")"

it "answering no leaves the package installed"
if [[ -f "$NO_DB" ]]; then pass; else fail "expected localsend to survive a declined prompt"; fi

it "answering no still closed the firewall"
if rules_have "$NO_RULES"; then fail "53317 still allowed"; else pass; fi

it "answering no says what it left behind"
assert_contains "$decline_out" "left localsend installed"

# --- the flatpak, which omarchy's nautilus action also looks for -------------

FP_RULES="$(make_ufw_fixture no)"
FP_DB="$TEST_TMP/flatpak.installed"
FP_MARKER="$TEST_TMP/flatpak-removed"

fp_out="$(env PATH="$STUBS:$PATH" UFW_RULES_DIR="$FP_RULES" FAKE_PKG_DB="$FP_DB" \
  FAKE_FLATPAK=1 FLATPAK_MARKER="$FP_MARKER" \
  "$REPO_ROOT/bin/setup-no-localsend" --yes 2>&1)"

it "removes a flatpak LocalSend when there is one"
if [[ -f "$FP_MARKER" ]]; then pass; else fail "expected the flatpak to be uninstalled"; fi

it "names the flatpak it removed"
assert_contains "$fp_out" "org.localsend.localsend_app"

it "says nothing about flatpak when the app is not installed"
assert_not_contains "$(no_localsend "$FP_RULES" "$FP_DB" --yes)" "flatpak"

# --- falling back to `ufw show added` when the rules file is unreadable ------

SHOW="$TEST_TMP/show-added"
printf 'Added user rules:\nufw allow 53317/udp\nufw allow 53317/tcp\n' > "$SHOW"
EMPTY="$TEST_TMP/no-rules-dir"

fallback_out="$(env PATH="$STUBS:$PATH" UFW_RULES_DIR="$EMPTY" FAKE_PKG_DB="$TEST_TMP/fb.db" \
  FAKE_SHOW_ADDED="$SHOW" FLATPAK_MARKER="$TEST_TMP/fb.marker" \
  "$REPO_ROOT/bin/setup-no-localsend" --dry-run --yes 2>&1)"

it "reads the rules through ufw when the file is not readable"
assert_contains "$fallback_out" "sudo ufw delete allow 53317/tcp"

# --- port 53 is not port 53317 ----------------------------------------------

DOCKER_ONLY="$(make_ufw_fixture no)"
docker_out="$(no_localsend "$DOCKER_ONLY" "$TEST_TMP/none.db" --dry-run --yes)"

it "does not mistake the docker DNS rule on port 53 for a LocalSend rule"
assert_contains "$docker_out" "53317/udp already closed"

# --- argument handling ------------------------------------------------------

it "help text is available without touching the system"
assert_contains "$(no_localsend "$RULES" "$DB" --help)" "Usage: setup-no-localsend"

it "rejects unknown arguments"
no_localsend "$RULES" "$DB" --not-a-flag >/dev/null 2>&1
assert_status 1 $?

it "dies when pacman is not installed"
# A PATH with just enough to start the script — bash for the shebang, dirname
# to resolve SCRIPT_DIR — and nothing else, so require_cmd is what stops it.
MINIMAL="$TEST_TMP/minimal-path"
mkdir -p "$MINIMAL"
for cmd in bash dirname; do ln -sf "$(command -v "$cmd")" "$MINIMAL/$cmd"; done
env PATH="$MINIMAL" UFW_RULES_DIR="$RULES" "$REPO_ROOT/bin/setup-no-localsend" --yes >/dev/null 2>&1
assert_status 1 $?

finish

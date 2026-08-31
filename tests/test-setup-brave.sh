#!/usr/bin/env bash
# bin/setup-brave — against a throwaway HOME and stubbed package/browser tools.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"
OMARCHY_FIXTURE="$TEST_TMP/omarchy"
mkdir -p "$OMARCHY_FIXTURE/config"
printf '%s\n' '--ozone-platform=wayland' '--password-store=gnome-libsecret' \
  > "$OMARCHY_FIXTURE/config/chromium-flags.conf"
printf '%s\n' \
  '--load-extension=/usr/share/omarchy/default/chromium/extensions/copy-url,/opt/kept,/usr/share/omarchy/default/chromium/extensions/yt-dlp,/usr/share/omarchy/default/chromium/extensions/whatsapp-slim' \
  >> "$OMARCHY_FIXTURE/config/chromium-flags.conf"

# shellcheck disable=SC2016
stub_bin "$STUBS" pacman '
case "$*" in
  "-Q brave-bin"|"-Q brave-browser")
    # pacman resolves queries through provides=, so an installed local package
    # is returned for both legacy names even though neither is installed.
    [[ -f "${FAKE_PKG_DB:?}" ]] || exit 1
    printf "brave-browser-local %s\n" "$(cat "$FAKE_PKG_DB")"
    ;;
  "-Q brave-browser-local")
    [[ -f "${FAKE_PKG_DB:?}" ]] || exit 1
    printf "brave-browser-local %s\n" "$(cat "$FAKE_PKG_DB")"
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" makepkg '
[[ "${MAKEPKG_FAIL:-0}" != 1 ]] || exit 42
[[ -f PKGBUILD && -f brave-launcher ]] || exit 44
if [[ "${MAKEPKG_NOOP:-0}" != 1 ]]; then
  printf "1.93.138-1\n" > "${FAKE_PKG_DB:?}"
fi'

stub_bin "$STUBS" sudo 'exec "$@"'

# Resolves deterministic "latest" metadata without network access. The real
# resolver's signature trust roots and endpoints are asserted below.
# shellcheck disable=SC2016
stub_bin "$STUBS" prepare-latest '
printf "pkgname=brave-browser-local\npkgver=1.93.138\npkgrel=1\n" > "$1/PKGBUILD"
printf "1.93.138\n"'

# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
browser_state="$HOME/.default-browser"
case "$*" in
  "default browser")
    if [[ -f "$browser_state" ]]; then cat "$browser_state"; else printf "chromium\n"; fi
    ;;
  "default browser brave")
    [[ "${OMARCHY_DEFAULT_NOOP:-0}" == 1 ]] || printf "brave\n" > "$browser_state"
    ;;
  "theme set browser")
    touch "${BRAVE_POLICY_DIR:?}/color.json"
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# The managed-policy directory has to end up root-owned, which an unprivileged
# test cannot produce. These runs name the invoking user as the owner the
# script must enforce, so creation, repair, and verification are all exercised;
# that the default owner really is root:root is asserted separately below.
POLICY_OWNER="$(id -un):$(id -gn)"

# policy_fixture <name> — a managed-policy directory under two ancestors, laid
# out like /etc/brave/policies/managed.
policy_fixture() { printf '%s/%s/brave/policies/managed' "$TEST_TMP" "$1"; }

# policy_parents <dir> — the two ancestors of a fixture, shortest first.
policy_parents() { printf '%s %s' "${1%/*/*}" "${1%/*}"; }

brave_setup() {
  local home="$1" policy="$2" db="$3"; shift 3
  env HOME="$home" PATH="$STUBS:$PATH" \
      XDG_CONFIG_HOME="$home/.config" OMARCHY_ROOT="$OMARCHY_FIXTURE" \
      BRAVE_POLICY_DIR="$policy" BRAVE_POLICY_PARENTS="$(policy_parents "$policy")" \
      BRAVE_POLICY_OWNER="$POLICY_OWNER" \
      BRAVE_PREPARE_LATEST="$STUBS/prepare-latest" \
      FAKE_PKG_DB="$db" \
      "$REPO_ROOT/bin/setup-brave" "$@" 2>&1
}

# --- dry run ---------------------------------------------------------------

DRY_HOME="$(make_fake_home)"
DRY_POLICY="$(policy_fixture dry)"
DRY_DB="$TEST_TMP/dry-package"
out="$(brave_setup "$DRY_HOME" "$DRY_POLICY" "$DRY_DB" --dry-run --yes)"

it "--dry-run does not build or install a package"
assert_no_file "$DRY_DB"

it "--dry-run does not create Brave policy files"
assert_no_file "$DRY_POLICY"

it "--dry-run does not change the default browser"
assert_no_file "$DRY_HOME/.default-browser"

it "--dry-run identifies the signed first-party stable RPM"
assert_contains "$out" "signed first-party stable RPM"

it "--dry-run does not invoke makepkg"
if [[ ! -f "$STUBS/makepkg.log" ]]; then pass; else fail "makepkg was invoked"; fi

# --- install and idempotence ----------------------------------------------

HOME_ONE="$(make_fake_home)"
POLICY_ONE="$(policy_fixture one)"
DB_ONE="$TEST_TMP/package-one"
out="$(brave_setup "$HOME_ONE" "$POLICY_ONE" "$DB_ONE" --yes)"

it "builds the repository-owned package with makepkg"
assert_file_contains "$STUBS/makepkg.log" "--syncdeps --install --cleanbuild --noconfirm --needed"

it "installs the resolved latest stable package version"
assert_eq "1.93.138-1" "$(cat "$DB_ONE")" "package version"

it "writes Omarchy's Brave flags"
assert_file_contains "$HOME_ONE/.config/brave-flags.conf" "--ozone-platform=wayland"

it "keeps user-provided Chromium extensions"
assert_file_contains "$HOME_ONE/.config/brave-flags.conf" "--load-extension=/opt/kept"

flags="$(cat "$HOME_ONE/.config/brave-flags.conf")"
it "does not enable Omarchy's Copy URL extension"
assert_not_contains "$flags" "/extensions/copy-url"

it "does not enable Omarchy's Download Video extension"
assert_not_contains "$flags" "/extensions/yt-dlp"

it "does not enable Omarchy's WhatsApp Slim extension"
assert_not_contains "$flags" "/extensions/whatsapp-slim"

it "does not install unwanted native messaging integrations"
assert_not_contains "$(cat "$STUBS/omarchy.log")" "install chromium"

it "creates and applies the Brave theme policy"
if [[ -f "$POLICY_ONE/color.json" ]]; then pass; else fail "theme policy missing"; fi

it "creates the managed-policy directory owned by the enforced owner"
assert_eq "755 ${POLICY_OWNER%%:*}" "$(stat -c '%a %U' "$POLICY_ONE")" "policy directory"

it "hardens the ancestors of the managed-policy directory too"
assert_eq "755 755" \
  "$(stat -c '%a' "${POLICY_ONE%/*/*}" "${POLICY_ONE%/*}" | paste -sd' ')" "ancestor modes"

it "makes Brave the default browser"
assert_eq "brave" "$(cat "$HOME_ONE/.default-browser")" "default browser"

it "reports the complete vetted setup"
assert_contains "$out" "Vetted Brave installed with Omarchy integration"

before_builds="$(wc -l < "$STUBS/makepkg.log")"
before_writes="$(grep -c '^default browser brave$' "$STUBS/omarchy.log")"
out2="$(brave_setup "$HOME_ONE" "$POLICY_ONE" "$DB_ONE" --yes)"
after_builds="$(wc -l < "$STUBS/makepkg.log")"
after_writes="$(grep -c '^default browser brave$' "$STUBS/omarchy.log")"

it "a second run does not rebuild the current package"
assert_eq "$before_builds" "$after_builds" "makepkg calls"

it "provided legacy names are not mistaken for installed conflicts"
assert_contains "$out2" "already installed"

it "a second run does not reset the default browser"
assert_eq "$before_writes" "$after_writes" "default-browser writes"

it "a second run reports the installed package"
assert_contains "$out2" "already installed"

it "a second run keeps the policy file the owner already wrote"
assert_file "$POLICY_ONE/color.json"

# --- policy-directory repair -----------------------------------------------
# Omarchy 4 hardened the Chromium-family policy directories because anything
# the user can write there is browser policy the whole machine trusts. Earlier
# versions of this script created Brave's directory owned by the invoking user,
# so a rerun has to take it back rather than leave it as it found it.

LOOSE_HOME="$(make_fake_home)"
LOOSE_POLICY="$(policy_fixture loose)"
mkdir -p "$LOOSE_POLICY"
chmod 0777 "$LOOSE_POLICY"
loose_out="$(brave_setup "$LOOSE_HOME" "$LOOSE_POLICY" "$TEST_TMP/loose-package" --yes)"

it "takes back a group- and world-writable policy directory"
assert_eq "755" "$(stat -c '%a' "$LOOSE_POLICY")" "repaired policy mode"

it "reports which directory it took back"
assert_contains "$loose_out" "Taking $LOOSE_POLICY back"

# The real machine needs root:root, which an unprivileged test cannot produce.
# Record what the script asks sudo for, and confirm it refuses to report
# success while the directory is still owned by the invoking user.
RECORD_STUBS="$TEST_TMP/record-stubs"
stub_bin "$RECORD_STUBS" sudo ''
for command in omarchy makepkg pacman; do
  ln -s "$STUBS/$command" "$RECORD_STUBS/$command"
done
ROOT_HOME="$(make_fake_home)"
ROOT_POLICY="$(policy_fixture root)"
mkdir -p "$ROOT_POLICY"
: > "$ROOT_POLICY/color.json"
root_out="$(env HOME="$ROOT_HOME" PATH="$RECORD_STUBS:$PATH" \
  XDG_CONFIG_HOME="$ROOT_HOME/.config" OMARCHY_ROOT="$OMARCHY_FIXTURE" \
  BRAVE_POLICY_DIR="$ROOT_POLICY" BRAVE_POLICY_PARENTS="$(policy_parents "$ROOT_POLICY")" \
  BRAVE_PREPARE_LATEST="$STUBS/prepare-latest" \
  FAKE_PKG_DB="$TEST_TMP/root-package" \
  "$REPO_ROOT/bin/setup-brave" --yes 2>&1)"
status=$?

it "asks for a root-owned managed-policy directory by default"
assert_file_contains "$RECORD_STUBS/sudo.log" \
  "install -d -m 0755 -o root -g root -- $ROOT_POLICY"

it "hardens the default ancestors too"
assert_file_contains "$RECORD_STUBS/sudo.log" \
  "install -d -m 0755 -o root -g root -- ${ROOT_POLICY%/*}"

it "removes policy files root did not write"
assert_file_contains "$RECORD_STUBS/sudo.log" "rm -rf -- $ROOT_POLICY/color.json"

it "fails when the policy directory could not be taken back"
assert_status 1 "$status"

it "explains that the policy directory is still not root-owned"
assert_contains "$root_out" "policy directory is not a root-owned 0755 directory"

# --- upgrades and failures -------------------------------------------------

OLD_HOME="$(make_fake_home)"
OLD_POLICY="$(policy_fixture old)"
OLD_DB="$TEST_TMP/old-package"
printf '1.93.136-1\n' > "$OLD_DB"
brave_setup "$OLD_HOME" "$OLD_POLICY" "$OLD_DB" --yes >/dev/null

it "rebuilds when the vetted recipe version is newer"
assert_eq "1.93.138-1" "$(cat "$OLD_DB")" "upgraded package version"

FAIL_HOME="$(make_fake_home)"
env HOME="$FAIL_HOME" PATH="$STUBS:$PATH" \
  XDG_CONFIG_HOME="$FAIL_HOME/.config" OMARCHY_ROOT="$OMARCHY_FIXTURE" \
  BRAVE_POLICY_DIR="$(policy_fixture fail)" BRAVE_POLICY_OWNER="$POLICY_OWNER" \
  BRAVE_POLICY_PARENTS="$(policy_parents "$(policy_fixture fail)")" \
  BRAVE_PREPARE_LATEST="$STUBS/prepare-latest" \
  FAKE_PKG_DB="$TEST_TMP/fail-package" \
  MAKEPKG_FAIL=1 "$REPO_ROOT/bin/setup-brave" --yes >/dev/null 2>&1
status=$?

it "propagates a package build failure"
assert_status 42 "$status"

CONFLICT_HOME="$(make_fake_home)"
CONFLICT_STUBS="$TEST_TMP/conflict-stubs"
# shellcheck disable=SC2016
stub_bin "$CONFLICT_STUBS" pacman '
case "$*" in
  "-Q brave-bin") printf "brave-bin 1.93.138-1\n" ;;
  *) exit 1 ;;
esac'
for command in omarchy makepkg sudo; do
  ln -s "$STUBS/$command" "$CONFLICT_STUBS/$command"
done
conflict_out="$(env HOME="$CONFLICT_HOME" PATH="$CONFLICT_STUBS:$PATH" \
  XDG_CONFIG_HOME="$CONFLICT_HOME/.config" OMARCHY_ROOT="$OMARCHY_FIXTURE" \
  BRAVE_POLICY_DIR="$(policy_fixture conflict)" BRAVE_POLICY_OWNER="$POLICY_OWNER" \
  BRAVE_POLICY_PARENTS="$(policy_parents "$(policy_fixture conflict)")" \
  BRAVE_PREPARE_LATEST="$STUBS/prepare-latest" \
  FAKE_PKG_DB="$TEST_TMP/conflict-package" \
  "$REPO_ROOT/bin/setup-brave" --yes 2>&1)"
status=$?

it "refuses to replace an existing third-party Brave package implicitly"
assert_status 1 "$status"

it "names the conflicting package"
assert_contains "$conflict_out" "Remove conflicting package brave-bin"

NOOP_HOME="$(make_fake_home)"
noop_out="$(env HOME="$NOOP_HOME" PATH="$STUBS:$PATH" \
  XDG_CONFIG_HOME="$NOOP_HOME/.config" OMARCHY_ROOT="$OMARCHY_FIXTURE" \
  BRAVE_POLICY_DIR="$(policy_fixture noop)" BRAVE_POLICY_OWNER="$POLICY_OWNER" \
  BRAVE_POLICY_PARENTS="$(policy_parents "$(policy_fixture noop)")" \
  BRAVE_PREPARE_LATEST="$STUBS/prepare-latest" \
  FAKE_PKG_DB="$TEST_TMP/noop-package" \
  MAKEPKG_NOOP=1 "$REPO_ROOT/bin/setup-brave" --yes 2>&1)"
status=$?

it "fails if makepkg did not register the package"
assert_status 1 "$status"

it "explains a failed package verification"
assert_contains "$noop_out" "was not registered as installed"

# --- recipe security -------------------------------------------------------

it "the recipe uses Brave's first-party GitHub release"
assert_file_contains "$REPO_ROOT/packages/brave/PKGBUILD.template" \
  "github.com/brave/brave-browser/releases/download"

it "the recipe contains no AUR endpoint or helper"
recipe="$(cat "$REPO_ROOT/packages/brave/PKGBUILD.template")"
assert_not_contains "$recipe" "aur.archlinux.org"

it "the resolver uses Brave's official stable-version endpoint"
assert_file_contains "$REPO_ROOT/packages/brave/prepare-latest" \
  "versions.brave.com/latest/release-linux-x64.version"

it "the resolver pins Brave's official checksum-key digest"
assert_file_contains "$REPO_ROOT/packages/brave/prepare-latest" \
  "5b22f304063ba95e1fd3a7923abd2ac2df9cda7d213e6ff2e42128aa1296aa0e"

it "the resolver verifies signed release checksums"
assert_file_contains "$REPO_ROOT/packages/brave/prepare-latest" "gpgv --status-fd"

it "the resolver pins the current Brave checksum signer"
assert_file_contains "$REPO_ROOT/packages/brave/prepare-latest" \
  "B840107020F8BED83CF7696DEDC0814C91A8144D"

it "the recipe preserves Brave's sandbox mode"
assert_file_contains "$REPO_ROOT/packages/brave/PKGBUILD.template" "chmod 4755"

it "the recipe removes the vendor RPM updater"
# shellcheck disable=SC2016 # $pkgdir must remain literal in the expected text.
assert_file_contains "$REPO_ROOT/packages/brave/PKGBUILD.template" 'rm -rf "$pkgdir/etc/cron.daily"'

# --- argument handling -----------------------------------------------------

it "help text is available without touching the system"
assert_contains "$(brave_setup "$HOME_ONE" "$POLICY_ONE" "$DB_ONE" --help)" "Usage: setup-brave"

it "rejects unknown arguments"
brave_setup "$HOME_ONE" "$POLICY_ONE" "$DB_ONE" --not-a-flag >/dev/null 2>&1
assert_status 1 $?

finish

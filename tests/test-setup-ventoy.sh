#!/usr/bin/env bash
# bin/setup-ventoy — against stubbed pacman and makepkg, plus the real recipe.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"
PKGBUILD="$REPO_ROOT/packages/ventoy/PKGBUILD"

# shellcheck disable=SC2016
stub_bin "$STUBS" pacman '
case "$*" in
  "-Q ventoy"|"-Q ventoy-local")
    # pacman resolves queries through provides=, so the local package answers
    # for the ventoy name it provides.
    [[ -f "${FAKE_PKG_DB:?}" ]] || exit 1
    printf "ventoy-local %s\n" "$(cat "$FAKE_PKG_DB")"
    ;;
  "-Q ventoy-bin") exit 1 ;;
  "-U --needed --noconfirm "*.pkg.tar.zst)
    [[ -f "${*: -1}" ]] || exit 45
    [[ "${INSTALL_NOOP:-0}" == 1 ]] || cat "${*: -1}" > "${FAKE_PKG_DB:?}"
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# The "package" a build produces holds the version pacman -U registers.
# shellcheck disable=SC2016
stub_bin "$STUBS" makepkg '
[[ -f PKGBUILD && -f ventoy-launcher && -f ventoy.desktop ]] || exit 44
package="$PWD/ventoy-local-x86_64.pkg.tar.zst"
if [[ "$1" == --packagelist ]]; then printf "%s\n" "$package"; exit 0; fi
(source PKGBUILD; printf "%s-%s\n" "$pkgver" "$pkgrel") > "$package"'

stub_bin "$STUBS" sudo 'exec "$@"'

# shellcheck disable=SC1090,SC2154  # the variables come from the PKGBUILD
expected_version="$(source "$PKGBUILD"; printf '%s-%s' "$pkgver" "$pkgrel")"

ventoy_setup() {
  local db="$1"; shift
  env PATH="$STUBS:$PATH" FAKE_PKG_DB="$db" "$REPO_ROOT/bin/setup-ventoy" "$@" 2>&1
}

# --- dry run ---------------------------------------------------------------

DRY_DB="$TEST_TMP/dry-package"
out="$(ventoy_setup "$DRY_DB" --dry-run --yes)"

it "--dry-run does not build or install a package"
assert_no_file "$DRY_DB"

it "--dry-run does not invoke makepkg"
if [[ ! -f "$STUBS/makepkg.log" ]]; then pass; else fail "makepkg was invoked"; fi

it "--dry-run names the pinned first-party release"
assert_contains "$out" "Ventoy $expected_version from its pinned first-party release"

# --- install and idempotence ----------------------------------------------

DB_ONE="$TEST_TMP/package-one"
out="$(ventoy_setup "$DB_ONE" --yes)"

it "builds the repository-owned package with makepkg, without root"
assert_file_contains "$STUBS/makepkg.log" "--cleanbuild --nodeps --noconfirm"

it "does not let makepkg call pacman itself, which prompts for sudo every time"
assert_not_contains "$(cat "$STUBS/makepkg.log")" "--install"

it "installs the built package with a single sudo call"
assert_eq "1" "$(grep -c . "$STUBS/sudo.log")" "sudo calls"

it "installs the built package through pacman -U"
assert_file_contains "$STUBS/sudo.log" "pacman -U --needed --noconfirm"

it "installs the pinned package version"
assert_eq "$expected_version" "$(cat "$DB_ONE")" "package version"

it "reports the installed commands"
assert_contains "$out" "Vetted Ventoy installed"

before_builds="$(wc -l < "$STUBS/makepkg.log")"
out2="$(ventoy_setup "$DB_ONE" --yes)"
after_builds="$(wc -l < "$STUBS/makepkg.log")"

it "a second run does not rebuild the current package"
assert_eq "$before_builds" "$after_builds" "makepkg calls"

it "the provided ventoy name is not mistaken for an installed conflict"
assert_contains "$out2" "already installed"

# --- failures -------------------------------------------------------------

CONFLICT_STUBS="$TEST_TMP/conflict-stubs"
stub_bin "$CONFLICT_STUBS" pacman '
case "$*" in
  "-Q ventoy-bin") printf "ventoy-bin 1.1.10-1\n" ;;
  *) exit 1 ;;
esac'
for command in makepkg sudo; do
  ln -s "$STUBS/$command" "$CONFLICT_STUBS/$command"
done
conflict_out="$(env PATH="$CONFLICT_STUBS:$PATH" FAKE_PKG_DB="$TEST_TMP/conflict-package" \
  "$REPO_ROOT/bin/setup-ventoy" --yes 2>&1)"
status=$?

it "refuses to replace an existing third-party Ventoy package implicitly"
assert_status 1 "$status"

it "names the conflicting package"
assert_contains "$conflict_out" "Remove conflicting package ventoy-bin"

noop_out="$(env PATH="$STUBS:$PATH" FAKE_PKG_DB="$TEST_TMP/noop-package" INSTALL_NOOP=1 \
  "$REPO_ROOT/bin/setup-ventoy" --yes 2>&1)"
status=$?

it "fails if pacman did not register the package"
assert_status 1 "$status"

it "says the package was not registered"
assert_contains "$noop_out" "was not registered as installed"

# --- the recipe itself ----------------------------------------------------

recipe="$(cat "$PKGBUILD")"

it "downloads only from Ventoy's GitHub releases"
assert_contains "$recipe" "https://github.com/ventoy/Ventoy/releases/download/v\${pkgver}/"

it "pins a SHA-256 for every source"
# shellcheck disable=SC1090,SC2154  # the variables come from the PKGBUILD
sources="$(source "$PKGBUILD"; printf '%s\n' "${#source[@]}")"
# shellcheck disable=SC1090,SC2154  # the variables come from the PKGBUILD
pinned="$(source "$PKGBUILD"; printf '%s\n' "${sha256sums[@]}" | grep -cE '^[0-9a-f]{64}$')"
assert_eq "$sources" "$pinned" "pinned checksums"

it "pins the current digests of the reviewed launcher and desktop entry"
stale=""
for file in ventoy-launcher ventoy.desktop; do
  digest="$(sha256sum "$REPO_ROOT/packages/ventoy/$file" | awk '{print $1}')"
  [[ "$recipe" == *"'$digest'"* ]] || stale+="$file "
done
if [[ -z "$stale" ]]; then pass; else fail "changed without updating sha256sums: $stale"; fi

it "does not reference the AUR"
assert_not_contains "$(tr '[:upper:]' '[:lower:]' <<< "$recipe" | grep -v 'not sourced from the aur')" "aur"

finish

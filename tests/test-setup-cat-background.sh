#!/usr/bin/env bash
# bin/setup-cat-background — against a throwaway HOME with omarchy and magick stubbed.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

SOURCE_IMAGE="$REPO_ROOT/assets/cat-wallpaper.png"

# --- the committed art itself ---------------------------------------------

it "the renderer uses neutral-gray canvas padding"
assert_file_contains "$REPO_ROOT/bin/setup-cat-background" 'BACKGROUND="#77797c"'

it "the approved generated wallpaper source is present"
if [[ -s "$SOURCE_IMAGE" ]]; then pass; else fail "expected $SOURCE_IMAGE"; fi

it "the approved generated wallpaper source has not changed"
assert_eq "fa1f6d43d81ea3c7a1e0f3426ce1d3b8d2795fe6d2342a6b8eb0010cc0dd0ce6" \
  "$(sha256sum "$SOURCE_IMAGE" | awk '{print $1}')" "source image checksum"

it "the renderer uses the approved generated wallpaper source"
assert_file_contains "$REPO_ROOT/bin/setup-cat-background" 'assets/cat-wallpaper.png'

# --- fixtures --------------------------------------------------------------

FAKE_HOME="$(make_fake_home)"
STUBS="$TEST_TMP/stubs"
mkdir -p "$FAKE_HOME/.local/state/omarchy/current"
printf 'tokyo-night' > "$FAKE_HOME/.local/state/omarchy/current/theme.name"

# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
case "$*" in
  "pkg present imagemagick") [[ "${IM_MISSING:-0}" != 1 ]] ;;
  "pkg add imagemagick")     ;;
  "theme bg set "*)          ln -nsf "$4" "$HOME/.local/state/omarchy/current/background" ;;
  "theme bg cache")          ;;
  "shell background setInstant "*) [[ "${SHELL_FAIL:-0}" != 1 ]] ;;
  "shell background set "*)        ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac'

# Deterministic stand-in for the renderer: write fixed bytes to the output path
# so the idempotence comparison is exercised for real.
# shellcheck disable=SC2016
stub_bin "$STUBS" magick '
out="${!#}"
printf "fake-png-%s" "${RENDER_TAG:-1}" > "${out#*:}"'

cat_bg() {
  env HOME="$FAKE_HOME" XDG_CACHE_HOME="$FAKE_HOME/.cache" PATH="$STUBS:$PATH" \
    "$REPO_ROOT/bin/setup-cat-background" "$@" 2>&1
}

TARGET="$FAKE_HOME/.config/omarchy/backgrounds/tokyo-night/pixel-cat.png"
RELOAD_TARGET="$FAKE_HOME/.cache/omarchy/pixel-cat-reload.png"

# --- dry run ---------------------------------------------------------------

out="$(cat_bg --dry-run --yes)"

it "--dry-run writes no wallpaper"
assert_no_file "$TARGET"

it "--dry-run names the file it would render"
assert_contains "$out" "pixel-cat.png"

it "--dry-run does not set the background"
assert_eq "0" "$(grep -c '^theme bg set' "$STUBS/omarchy.log" || true)" "bg set calls"

# --- first real run --------------------------------------------------------

out="$(cat_bg --yes)"

it "renders the wallpaper into the theme's user background directory"
if [[ -f "$TARGET" ]]; then pass; else fail "expected $TARGET"; fi

it "does not query theme colours"
assert_eq "0" "$(grep -c '^theme color ' "$STUBS/omarchy.log" || true)" "theme color calls"

it "makes it the current background"
assert_file_contains "$STUBS/omarchy.log" "theme bg set $TARGET"

it "cache-busts the live shell before returning to the stable path"
assert_file_contains "$STUBS/omarchy.log" "shell background setInstant $RELOAD_TARGET"

it "returns the live shell to the stable background path"
assert_file_contains "$STUBS/omarchy.log" "shell background set $TARGET"

it "caches the switcher thumbnail"
assert_file_contains "$STUBS/omarchy.log" "theme bg cache"

# --- idempotence -----------------------------------------------------------

before="$(grep -c '^theme bg set' "$STUBS/omarchy.log")"
out2="$(cat_bg --yes)"
after="$(grep -c '^theme bg set' "$STUBS/omarchy.log")"

it "a second run reports the wallpaper is already up to date"
assert_contains "$out2" "already up to date"

it "a second run leaves no backup behind"
assert_eq "0" "$(find "$(dirname "$TARGET")" -name '*.bak.*' | wc -l)" "backups"

it "a second run refreshes the live background without rewriting it"
assert_eq "$((before + 1))" "$after" "bg set calls"

# --- re-render on theme change --------------------------------------------

out3="$(env RENDER_TAG=2 HOME="$FAKE_HOME" XDG_CACHE_HOME="$FAKE_HOME/.cache" PATH="$STUBS:$PATH" \
  "$REPO_ROOT/bin/setup-cat-background" --yes 2>&1)"

it "re-renders when the rendered bytes change"
assert_contains "$out3" "wrote $TARGET"

it "backs the old wallpaper up before replacing it"
assert_eq "1" "$(find "$(dirname "$TARGET")" -name 'pixel-cat.png.bak.*' | wc -l)" "backups"

it "reloads an active wallpaper when its bytes change at the same path"
assert_eq "$((after + 1))" "$(grep -c '^theme bg set' "$STUBS/omarchy.log")" "bg set calls"

# --- flags -----------------------------------------------------------------

NOACT_HOME="$(make_fake_home)"
mkdir -p "$NOACT_HOME/.local/state/omarchy/current"
printf 'gruvbox' > "$NOACT_HOME/.local/state/omarchy/current/theme.name"
: > "$STUBS/omarchy.log"
env HOME="$NOACT_HOME" PATH="$STUBS:$PATH" \
  "$REPO_ROOT/bin/setup-cat-background" --no-activate >/dev/null 2>&1

it "--no-activate still renders the wallpaper"
if [[ -f "$NOACT_HOME/.config/omarchy/backgrounds/gruvbox/pixel-cat.png" ]]; then pass; else fail "no wallpaper"; fi

it "--no-activate leaves the current background alone"
assert_eq "0" "$(grep -c '^theme bg set' "$STUBS/omarchy.log" || true)" "bg set calls"

it "--force re-renders identical bytes"
assert_contains "$(env HOME="$NOACT_HOME" PATH="$STUBS:$PATH" \
  "$REPO_ROOT/bin/setup-cat-background" --no-activate --force 2>&1)" "wrote"

# --- failures --------------------------------------------------------------

it "rejects a malformed --size"
cat_bg --size huge >/dev/null 2>&1
assert_status 1 $?

BARE_HOME="$(make_fake_home)"
it "dies when no theme is active"
env HOME="$BARE_HOME" PATH="$STUBS:$PATH" \
  "$REPO_ROOT/bin/setup-cat-background" >/dev/null 2>&1
assert_status 1 $?

it "reports failure when the live shell cannot refresh"
SHELL_FAIL=1 cat_bg --force >/dev/null 2>&1
assert_status 1 $?

it "installs ImageMagick when it is missing"
: > "$STUBS/omarchy.log"
env IM_MISSING=1 HOME="$FAKE_HOME" PATH="$STUBS:$PATH" \
  "$REPO_ROOT/bin/setup-cat-background" --no-activate >/dev/null 2>&1
assert_file_contains "$STUBS/omarchy.log" "pkg add imagemagick"

# --- argument handling -----------------------------------------------------

it "help text is available without touching the system"
assert_contains "$(cat_bg --help)" "Usage: setup-cat-background"

it "rejects unknown arguments"
cat_bg --not-a-flag >/dev/null 2>&1
assert_status 1 $?

finish

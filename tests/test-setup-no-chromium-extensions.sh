#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

HOME_DIR="$(make_fake_home)"
FLAGS="$HOME_DIR/.config"
SCRIPT="$REPO_ROOT/bin/setup-no-chromium-extensions"
OMARCHY="/usr/share/omarchy/default/chromium/extensions"

cat > "$FLAGS/chromium-flags.conf" <<EOF
--ozone-platform=wayland
--load-extension=$OMARCHY/copy-url,/opt/my-extension,$OMARCHY/yt-dlp,$OMARCHY/whatsapp-slim
--password-store=gnome-libsecret
EOF

cp "$FLAGS/chromium-flags.conf" "$TEST_TMP/original"
out="$(env HOME="$HOME_DIR" CHROMIUM_FLAGS_DIR="$FLAGS" "$SCRIPT" --dry-run --yes 2>&1)"

it "dry-run reports the flags file"
assert_contains "$out" "$FLAGS/chromium-flags.conf"

it "dry-run changes nothing"
assert_eq "$(cat "$TEST_TMP/original")" "$(cat "$FLAGS/chromium-flags.conf")"

out="$(env HOME="$HOME_DIR" CHROMIUM_FLAGS_DIR="$FLAGS" "$SCRIPT" --yes 2>&1)"

it "removes Copy URL"
assert_not_contains "$(cat "$FLAGS/chromium-flags.conf")" "$OMARCHY/copy-url"

it "removes Download Video"
assert_not_contains "$(cat "$FLAGS/chromium-flags.conf")" "$OMARCHY/yt-dlp"

it "removes WhatsApp Slim"
assert_not_contains "$(cat "$FLAGS/chromium-flags.conf")" "$OMARCHY/whatsapp-slim"

it "preserves a user extension"
assert_file_contains "$FLAGS/chromium-flags.conf" "--load-extension=/opt/my-extension"

it "preserves unrelated flags"
assert_file_contains "$FLAGS/chromium-flags.conf" "--password-store=gnome-libsecret"

it "backs up the edited file"
if compgen -G "$FLAGS/chromium-flags.conf.bak.*" >/dev/null; then pass; else fail "backup not found"; fi

it "a second run is a no-op"
assert_contains "$(env HOME="$HOME_DIR" CHROMIUM_FLAGS_DIR="$FLAGS" "$SCRIPT" --yes 2>&1)" "already disabled"

cat > "$FLAGS/brave-flags.conf" <<EOF
--load-extension=$OMARCHY/copy-url,$OMARCHY/yt-dlp,$OMARCHY/whatsapp-slim
--enable-features=Example
EOF
env HOME="$HOME_DIR" CHROMIUM_FLAGS_DIR="$FLAGS" "$SCRIPT" --yes >/dev/null

it "removes an empty load-extension flag"
assert_not_contains "$(cat "$FLAGS/brave-flags.conf")" "--load-extension="

it "keeps following flags when removing the whole extension line"
assert_file_contains "$FLAGS/brave-flags.conf" "--enable-features=Example"

it "help works without touching files"
assert_contains "$(env HOME="$HOME_DIR" "$SCRIPT" --help)" "Usage: setup-no-chromium-extensions"

it "rejects unknown arguments"
env HOME="$HOME_DIR" "$SCRIPT" --invalid >/dev/null 2>&1
assert_status 1 $?

finish

#!/usr/bin/env bash
# Repository hygiene: what .gitignore must and must not exclude.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

ignored() { git -C "$REPO_ROOT" check-ignore -q "$1"; }

# --- must be ignored -------------------------------------------------------

for path in \
  id_ed25519 id_rsa secret.pem private.key store.p12 deploy_key \
  .env .env.production secrets/token \
  config.bak.20260101120000 notes.bak \
  'cat-photo.jpg' 'scan.jpeg' \
  settings.local local/scratch \
  packages/brave/src/file packages/brave/pkg/file \
  packages/brave/brave.rpm packages/brave/brave.pkg.tar.zst \
  .DS_Store editor~ file.swp
do
  it "ignores $path"
  if ignored "$path"; then pass; else fail "$path should be ignored"; fi
done

# --- must NOT be ignored ---------------------------------------------------

for path in \
  README.md LICENSE AGENTS.md CLAUDE.md .gitignore .shellcheckrc .editorconfig \
  bin/setup-all bin/setup-ssh-agent bin/setup-no-idle bin/setup-brave bin/setup-rpi-imager \
  bin/setup-no-localsend bin/setup-no-background-network bin/setup-cat-background bin/setup-rootless-podman \
  bin/setup-security-hardening \
  bin/setup-opensnitch bin/export-opensnitch-rules \
  config/opensnitch/rules/omarchy-shared-000-allow-localhost-ipv4.json \
  config/opensnitch/rules/omarchy-shared-001-allow-localhost-ipv6.json \
  config/opensnitch/rules/omarchy-shared-010-allow-systemd-resolved.json \
  config/opensnitch/rules/omarchy-shared-011-allow-systemd-timesyncd.json \
  config/opensnitch/rules/omarchy-shared-020-allow-networkmanager-connectivity.json \
  config/opensnitch/rules/omarchy-shared-030-allow-avahi-mdns-ipv4.json \
  config/opensnitch/rules/omarchy-shared-031-allow-avahi-mdns-ipv6.json \
  config/opensnitch/rules/omarchy-shared-040-allow-fwupd-firmware-updates.json \
  config/opensnitch/rules/omarchy-shared-060-allow-podman-registry-pulls.json \
  config/opensnitch/rules/omarchy-shared-061-allow-container-egress-to-alpine-cdn.json \
  config/opensnitch/rules/omarchy-shared-062-allow-curl-brave-release-downloads.json \
  assets/cat-wallpaper.png \
  bin/lint bin/install-hooks \
  packages/brave/PKGBUILD.template packages/brave/brave-launcher \
  packages/brave/prepare-latest \
  lib/common.sh lib/tui.sh \
  githooks/pre-commit docker/lint.Dockerfile \
  tests/run tests/helpers.sh tests/test-repo.sh \
  docs/ci.md docs/testing.md docs/setup-cat-background.md \
  docs/setup-rootless-podman.md \
  docs/setup-security-hardening.md tests/test-setup-security-hardening.sh \
  docs/setup-opensnitch.md tests/test-setup-opensnitch.sh \
  docs/setup-no-background-network.md tests/test-setup-no-background-network.sh \
  tests/test-export-opensnitch-rules.sh
do
  it "keeps $path tracked"
  if ignored "$path"; then fail "$path must not be ignored"; else pass; fi
done

# --- nothing already committed is ignored ----------------------------------

it "no tracked file is covered by .gitignore"
conflicts="$(git -C "$REPO_ROOT" ls-files | git -C "$REPO_ROOT" check-ignore --stdin 2>/dev/null || true)"
assert_eq "" "$conflicts" "tracked-but-ignored files"

it "setup scripts do not invoke AUR installers"
aur_calls="$(grep -REn \
  '(^|[[:space:]])(yay|paru|omarchy +pkg +aur +add|omarchy-pkg-aur-add)([[:space:]]|$)' \
  "$REPO_ROOT"/bin/setup-* || true)"
assert_eq "" "$aur_calls" "AUR installer references"

finish

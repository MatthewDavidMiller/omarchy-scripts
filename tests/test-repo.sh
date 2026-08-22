#!/usr/bin/env bash
# Repository hygiene: what .gitignore must and must not exclude.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

ignored() { git -C "$REPO_ROOT" check-ignore -q "$1"; }

# --- must be ignored -------------------------------------------------------

for path in \
  id_ed25519 id_rsa secret.pem private.key store.p12 deploy_key \
  .env .env.production secrets/token \
  config.bak.20260101120000 notes.bak \
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
  bin/setup-no-localsend \
  bin/lint bin/install-hooks \
  packages/brave/PKGBUILD.template packages/brave/brave-launcher \
  packages/brave/prepare-latest \
  lib/common.sh lib/tui.sh \
  githooks/pre-commit docker/lint.Dockerfile \
  tests/run tests/helpers.sh tests/test-repo.sh \
  docs/ci.md docs/testing.md
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

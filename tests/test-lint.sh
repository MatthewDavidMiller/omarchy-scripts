#!/usr/bin/env bash
# bin/lint — CLI contract and fallback behaviour. Container runs are only
# exercised when an engine is actually available.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

lint() { "$REPO_ROOT/bin/lint" "$@" 2>&1; }

it "--help works without any engine or linter present"
assert_contains "$(lint --help)" "Usage: lint"

it "rejects unknown arguments"
lint --not-a-flag >/dev/null 2>&1
assert_status 1 $?

it "refuses files outside the repo"
out="$(lint /etc/hostname 2>&1)" && status=0 || status=$?
assert_contains "$out" "Not inside the repo"

# A PATH holding the ordinary shell utilities, with no container engine and no
# host linter on it. Emptying PATH outright would only prove that the shebang
# cannot resolve bash.
#
# (Careful: any comment line starting with the word "shellcheck" is parsed as a
# directive, so keep it out of the first position.)
BARE="$TEST_TMP/bare-path"
mkdir -p "$BARE"
for cmd in bash env cat cut dirname basename grep sed find id timeout sha256sum mktemp; do
  target="$(command -v "$cmd")" && ln -sf "$target" "$BARE/$cmd"
done

it "exits 3 — not 1 — when no linter is available at all"
env PATH="$BARE" "$REPO_ROOT/bin/lint" --no-container >/dev/null 2>&1
assert_status 3 $?

it "says why, rather than failing silently"
out="$(env PATH="$BARE" "$REPO_ROOT/bin/lint" --no-container 2>&1)"
assert_contains "$out" "nothing to lint with"

it "--container fails cleanly with exit 3 when no engine answers"
env PATH="$BARE" "$REPO_ROOT/bin/lint" --container >/dev/null 2>&1
assert_status 3 $?

it "a dead engine does not make it fall over slowly"
DEAD="$TEST_TMP/dead-engine"
mkdir -p "$DEAD"
cp -a "$BARE"/* "$DEAD/"
printf '#!/usr/bin/env bash\nexit 1\n' > "$DEAD/docker"; chmod +x "$DEAD/docker"
env PATH="$DEAD" "$REPO_ROOT/bin/lint" --container >/dev/null 2>&1
assert_status 3 $?

it "the Dockerfile exists where bin/lint expects it"
assert_file_contains "$REPO_ROOT/docker/lint.Dockerfile" "FROM alpine@sha256:"

it "the base image is pinned by digest, never by a mutable tag"
if grep -qE '^FROM alpine:' "$REPO_ROOT/docker/lint.Dockerfile"; then
  fail "base image is pinned by tag; use a digest"
else
  pass
fi

it "the image installs both linters"
assert_file_contains "$REPO_ROOT/docker/lint.Dockerfile" "shellcheck shfmt"

it ".shellcheckrc follows sourced files"
assert_file_contains "$REPO_ROOT/.shellcheckrc" "external-sources=true"

it ".shellcheckrc resolves source paths relative to the script"
assert_file_contains "$REPO_ROOT/.shellcheckrc" "source-path=SCRIPTDIR"

if command -v docker >/dev/null 2>&1 && timeout 20 docker info >/dev/null 2>&1; then
  it "the repo is shellcheck-clean"
  out="$(lint)" && status=0 || status=$?
  assert_status 0 "$status"

  it "reports the image it used"
  assert_contains "$out" "omarchy-scripts/lint:"

  it "catches a real defect, not just syntax errors"
  cat > "$REPO_ROOT/lib/zz-test-defect.sh" <<'BAD'
#!/usr/bin/env bash
f() {
  local x
  x=$(ls)
  echo $x
}
BAD
  out="$(lint lib/zz-test-defect.sh 2>&1)" && status=0 || status=$?
  rm -f "$REPO_ROOT/lib/zz-test-defect.sh"
  assert_contains "$out" "SC2086"

  it "exits 1 when it finds a defect"
  assert_status 1 "$status"
else
  printf '  %s· container tests skipped (no engine)%s\n' "$T_DIM" "$T_RESET"
fi

finish

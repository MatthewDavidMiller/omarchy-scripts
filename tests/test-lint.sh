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

# --- engine selection and uid mapping --------------------------------------
#
# Against stubbed engines, so the flags bin/lint chooses are checked on every
# machine rather than only where a real engine happens to be installed.

ENGINES="$TEST_TMP/engines"
mkdir -p "$ENGINES"
for cmd in bash env cat cut dirname basename grep sed find id timeout sha256sum mktemp; do
  target="$(command -v "$cmd")" && ln -sf "$target" "$ENGINES/$cmd"
done

# A podman that reports whatever FAKE_ROOTLESS says and pretends the image is
# already built, so bin/lint goes straight to the run.
# shellcheck disable=SC2016
stub_bin "$ENGINES" podman '
case "$*" in
  "info --format {{.Host.Security.Rootless}}") echo "${FAKE_ROOTLESS:-true}" ;;
  *) exit 0 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$ENGINES" docker '
case "$*" in
  info) exit "${FAKE_DOCKER_DEAD:-0}" ;;
  *)    exit 0 ;;
esac'

lint_with_engines() {
  rm -f "$ENGINES/podman.log" "$ENGINES/docker.log"
  env PATH="$ENGINES" "$@" "$REPO_ROOT/bin/lint" lib/common.sh 2>&1
}

# The one line that matters: how the linter container was actually invoked.
engine_run_line() {
  grep '^run --rm' "$1" | head -n1
}

out="$(lint_with_engines)"

it "prefers podman over docker when both answer"
assert_contains "$out" "via rootless podman"

it "adds --userns=keep-id under rootless podman"
assert_contains "$(engine_run_line "$ENGINES/podman.log")" "--userns=keep-id"

it "still runs as the caller's own uid, not as container root"
assert_contains "$(engine_run_line "$ENGINES/podman.log")" "--user $(id -u):$(id -g)"

it "keeps the mount read-only for a read-only linter"
assert_contains "$(engine_run_line "$ENGINES/podman.log")" ":/mnt:ro"

it "keeps the network off"
assert_contains "$(engine_run_line "$ENGINES/podman.log")" "--network none"

out="$(lint_with_engines FAKE_ROOTLESS=false)"

it "omits --userns=keep-id for rootful podman, which rejects it"
assert_not_contains "$(engine_run_line "$ENGINES/podman.log")" "keep-id"

it "does not call a rootful engine rootless"
assert_not_contains "$out" "rootless"

out="$(lint_with_engines OMARCHY_CONTAINER_ENGINE=docker)"

it "OMARCHY_CONTAINER_ENGINE pins the engine"
assert_contains "$out" "via docker"

it "never sends keep-id to docker, which has no such flag"
assert_not_contains "$(engine_run_line "$ENGINES/docker.log")" "keep-id"

it "a pinned engine that does not answer is not silently swapped for the other"
env PATH="$ENGINES" OMARCHY_CONTAINER_ENGINE=docker FAKE_DOCKER_DEAD=1 \
  "$REPO_ROOT/bin/lint" --container lib/common.sh >/dev/null 2>&1
assert_status 3 $?

# --- against a real engine, when one is here -------------------------------

real_engine=""
for candidate in podman docker; do
  if command -v "$candidate" >/dev/null 2>&1 && timeout 20 "$candidate" info >/dev/null 2>&1; then
    real_engine="$candidate"
    break
  fi
done

if [[ -n "$real_engine" ]]; then
  it "the repo is shellcheck-clean"
  out="$(lint)" && status=0 || status=$?
  assert_status 0 "$status"

  # bin/ holds commands, not only shell ones. shellcheck aborts with SC1071 on
  # a language it cannot parse, so one Python tool would otherwise fail the
  # whole run.
  it "skips a non-shell command in bin/ instead of failing on it"
  cat > "$REPO_ROOT/bin/zz-test-not-shell" <<'PYSCRIPT'
#!/usr/bin/env python
import sys
sys.exit(0)
PYSCRIPT
  chmod +x "$REPO_ROOT/bin/zz-test-not-shell"
  out="$(lint)" && status=0 || status=$?
  rm -f "$REPO_ROOT/bin/zz-test-not-shell"
  if [[ $status -eq 0 && "$out" != *SC1071* ]]; then
    pass
  else
    fail "expected the Python file to be skipped" "exit $status" "${out:0:400}"
  fi

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

  # The uid mapping only actually bites when the container writes: under
  # rootless podman a bare --user maps to a subuid that does not own the bind
  # mount, and shfmt --write fails on the caller's own files.
  # A Dockerfile edit that only touches comments rebuilds to identical layers,
  # so the superseded tag names the same image as the new one. Pruning has to
  # work by tag for that case, not by image id.
  it "prunes a superseded tag even when it names the same image"
  # The earlier runs already built it, so there is an image here to tag.
  current="$("$real_engine" images --quiet --filter 'reference=omarchy-scripts/lint' | head -n1)"
  "$real_engine" tag "$current" omarchy-scripts/lint:stale0000test >/dev/null 2>&1
  lint --rebuild lib/common.sh >/dev/null 2>&1
  remaining="$("$real_engine" images --format '{{.Repository}}:{{.Tag}}' \
    --filter 'reference=omarchy-scripts/lint')"
  assert_not_contains "$remaining" "stale0000test"

  it "--fix can write to the caller's files through the mount"
  probe="$REPO_ROOT/lib/zz-test-fmt.sh"
  printf '#!/usr/bin/env bash\nif true; then\necho hi\nfi\n' > "$probe"
  lint --fix lib/zz-test-fmt.sh >/dev/null 2>&1
  formatted="$(cat "$probe")"
  rm -f "$probe"
  assert_contains "$formatted" "  echo hi"
else
  printf '  %s· container tests skipped (no engine)%s\n' "$T_DIM" "$T_RESET"
fi

finish

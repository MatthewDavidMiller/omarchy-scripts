#!/usr/bin/env bash
# lib/omarchy.sh — repo pointer, hypr toggles, hooks, and marked-block strip.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/omarchy.sh
source "$REPO_ROOT/lib/omarchy.sh"

HOME_DIR="$(make_fake_home)"
export HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" XDG_STATE_HOME="$HOME_DIR/.local/state"
DRY_RUN=0

it "remember_repo_root writes this clone's path"
remember_repo_root >/dev/null
assert_file_contains "$(omarchy_scripts_repo_file)" "$REPO_ROOT"

it "remember_repo_root is idempotent"
out="$(remember_repo_root)"
assert_contains "$out" "already up to date"

toggle_src="$TEST_TMP/toggle.lua"
printf 'hl.env("PATH", "/tmp")\n' > "$toggle_src"
write_hypr_toggle "example" "$toggle_src" >/dev/null

it "write_hypr_toggle installs Lua under the Omarchy toggles directory"
assert_file_contains "$(hypr_toggles_dir)/example.lua" 'hl.env("PATH", "/tmp")'

hook_src="$REPO_ROOT/config/hooks/post-update.d/no-chromium-extensions"
install_omarchy_hook post-update "$hook_src" >/dev/null

it "install_omarchy_hook copies a wrapper into ~/.config/omarchy/hooks"
assert_file "$(omarchy_hooks_dir)/post-update.d/no-chromium-extensions"

it "install_omarchy_hook makes the copied hook executable"
if [[ -x "$(omarchy_hooks_dir)/post-update.d/no-chromium-extensions" ]]; then
  pass
else
  fail "hook is not executable"
fi

marked="$TEST_TMP/marked.lua"
cat > "$marked" <<'LUA'
keep_before()
-- BEGIN omarchy-scripts example
drop_me()
-- END omarchy-scripts example
keep_after()
LUA
strip_marked_block "$marked" "-- BEGIN omarchy-scripts example" "-- END omarchy-scripts example" >/dev/null

it "strip_marked_block removes the inclusive marked region"
assert_not_contains "$(cat "$marked")" "drop_me"

it "strip_marked_block keeps surrounding user content"
assert_file_contains "$marked" "keep_before()"
assert_file_contains "$marked" "keep_after()"

it "strip_marked_block is a no-op when the file is missing"
strip_marked_block "$TEST_TMP/missing.lua" "BEGIN" "END" >/dev/null
assert_status 0 $?

finish

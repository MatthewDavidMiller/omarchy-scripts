#!/usr/bin/env bash
# lib/common.sh — logging, dry-run, and the idempotent file writer.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

it "run executes the command normally"
# The echo is the subject of the test, not a useless one.
# shellcheck disable=SC2116
DRY_RUN=0 out="$(run echo hello)"
assert_eq "hello" "$out"

it "run prints instead of executing under DRY_RUN"
marker="$TEST_TMP/should-not-exist"
DRY_RUN=1 run touch "$marker" >/dev/null
assert_no_file "$marker"

it "have detects a missing command"
have definitely-not-a-real-command-xyz
assert_status 1 $?

it "write_file creates the file"
DRY_RUN=0
target="$TEST_TMP/written.conf"
write_file "$target" >/dev/null <<<"hello world"
assert_file_contains "$target" "hello world"

it "write_file is idempotent and says so"
out="$(write_file "$target" <<<"hello world")"
assert_contains "$out" "already up to date"

it "write_file leaves no backup when content is unchanged"
assert_eq "0" "$(find "$TEST_TMP" -name 'written.conf.bak.*' | wc -l)" "backup count"

it "write_file backs up before overwriting different content"
write_file "$target" >/dev/null <<<"changed"
assert_eq "1" "$(find "$TEST_TMP" -name 'written.conf.bak.*' | wc -l)" "backup count"

it "write_file backup retains the previous content"
assert_file_contains "$(find "$TEST_TMP" -name 'written.conf.bak.*' | head -1)" "hello world"

it "write_file writes nothing under DRY_RUN"
untouched="$TEST_TMP/dry.conf"
DRY_RUN=1 write_file "$untouched" >/dev/null <<<"nope"
assert_no_file "$untouched"

it "confirm accepts ASSUME_YES without reading stdin"
ASSUME_YES=1 confirm "irrelevant?" </dev/null
assert_status 0 $?

it "confirm rejects a negative answer"
ASSUME_YES=0 confirm "no?" <<<"n" >/dev/null 2>&1
assert_status 1 $?

it "require_cmd dies on a missing command"
out="$(require_cmd definitely-not-a-real-command-xyz 2>&1)" && status=0 || status=$?
assert_status 1 "$status"

finish

# Testing

```bash
./tests/run                    # everything
./tests/run --filter ssh-agent # one file
```

The suite runs automatically on every commit.

## Why plain bash

No test framework. The suite exercises scripts that talk to systemd, ssh, and
docker, so it runs on the host rather than in a container — and adding bats
would mean either a host dependency or a container that cannot see the things
under test. `tests/helpers.sh` provides the handful of assertions needed.

## Safety

Nothing touches your real system. Every test that could write runs against:

- **A throwaway `HOME`** (`make_fake_home`) with its own `XDG_RUNTIME_DIR`,
  removed on exit.
- **Stubbed system commands** (`stub_bin`) — a fake `systemctl`, `ssh-agent`,
  and `ssh-add` that log how they were called, so tests can assert on
  *"did it try to mask gpg-agent-ssh.socket?"* without a real systemd anywhere
  in the picture.
- **A throwaway copy of the repo** (`make_test_repo`) when fixtures need to be
  added to `bin/`.

Real `ssh-keygen` and a real unix socket are used where the behaviour under
test depends on them — key discovery works on fingerprints, and mocking that
would test the mock.

## Layout

| File | Covers |
| --- | --- |
| `tests/run` | Harness: discovers `test-*.sh`, aggregates results |
| `tests/helpers.sh` | Assertions and fixtures |
| `tests/test-common.sh` | `lib/common.sh` — dry-run, idempotent writes, backups |
| `tests/test-setup-all.sh` | Discovery, ordering, `--only`/`--skip`, failure reporting |
| `tests/test-setup-ssh-agent.sh` | Full run against a fake HOME, and idempotence |
| `tests/test-setup-no-idle.sh` | Idle and screensaver toggles against a stubbed `omarchy` |
| `tests/test-setup-no-localsend.sh` | ufw rule deletion against fixture rules files, and package removal |
| `tests/test-setup-cat-background.sh` | The approved generated cat asset, deterministic rendering, live refresh, and idempotence |
| `tests/test-tui.sh` | `lib/tui.sh` fallback menu parsing |
| `tests/test-lint.sh` | `bin/lint` CLI, exit codes, image policy |
| `tests/test-repo.sh` | `.gitignore` — secrets excluded, sources not |

## Writing a test

Each file sources `helpers.sh`, calls `it` before each assertion, and ends with
`finish`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

it "does the thing"
assert_eq "expected" "$(some_command)"

finish
```

Assertions: `assert_eq`, `assert_contains`, `assert_not_contains`,
`assert_status`, `assert_file_contains`, `assert_no_file`, plus `fail` and
`pass` for anything custom.

Test the behaviour that would actually bite. The suite pins down things like
*"a second run leaves the file byte-identical"*, *"`IdentitiesOnly` is not set
under `Host *`"*, and *"a static unit gets masked rather than disabled"* —
the decisions that are easy to undo by accident later.

## What the tests have already caught

- `ssh-add </dev/tty` failed outright with no controlling terminal, so keys
  were silently never added in non-interactive use. Now falls back to inherited
  stdin.
- A comment beginning `# shellcheck` was parsed by shellcheck as a malformed
  directive — in the test suite's own source.

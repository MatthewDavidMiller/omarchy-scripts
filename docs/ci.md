# CI/CD

Everything runs locally, on commit. There is no hosted CI, and nothing runs on
push.

## Install

```bash
./bin/install-hooks
```

Sets `core.hooksPath` to `githooks/`. Run once per clone.

## The pipeline

`githooks/pre-commit`, in order:

| Stage | Tool | Blocks commit? |
| --- | --- | --- |
| Syntax | `bash -n` | Yes |
| Lint | `bin/lint` (shellcheck, containerised) | Yes — unless no linter is available |
| Tests | `tests/run` | Yes |
| Permissions | `git ls-files --stage` | Yes, if a `bin/` script lost its `+x` |

About 5 seconds on a clean tree. Only staged scripts are linted; the test suite
always runs in full, because it is fast and the interactions it covers are
exactly what a partial run would miss.

## Why commit-time only, and nothing on push

A pre-push hook would re-run work already done, on every push, to catch nothing
new — commits cannot exist without having passed. Pushing stays instant, which
matters far more often than the theoretical case it would guard against.

`bin/install-hooks` warns if a stale `.git/hooks/pre-push` exists, since that
would still fire even with `core.hooksPath` pointed elsewhere.

## When it degrades rather than blocks

If neither a container engine nor a host `shellcheck` is available, `bin/lint`
exits 3 — "no linter available", distinct from "lint failed" — and the hook
prints `no linter available, syntax check only` and lets the commit through.
A stopped docker daemon should not stop you committing. (Rootless podman, which
[setup-rootless-podman](setup-rootless-podman.md) installs, has no daemon to
stop — so on a migrated machine this degradation mostly stops happening.)

## Bypassing

`git commit --no-verify` skips the hook. For a work-in-progress commit on a
branch that is fine; the next full commit re-checks everything anyway.

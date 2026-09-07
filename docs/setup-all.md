# setup-all

The single command that brings a machine's config up to date.

```bash
./bin/setup-all              # run everything
./bin/setup-all --list       # show what would run, in order
./bin/setup-all --dry-run    # preview, change nothing
```

Safe to run any time. Every script is idempotent, so a second run reports
`skip` for the work already done and changes nothing.

## How scripts are discovered

`setup-all` globs `bin/setup-*` (excluding itself). A new script joins the run
just by existing and being executable — there is no list to update, and there
is no opt-in tier: every script in `bin/` is listed, shown in the menu, and run.

A script that is disruptive enough to want holding back is held back with
`--skip NAME`, at the call site. That is deliberate. `setup-all` used to honour
a `# default: no` header, and the cost was that such a script vanished from
`--list` and from the menu as well as from the run — leaving no way to discover
it short of reading `bin/`. A choice you can see is worth more than a default
you cannot.

Order comes from a header comment in each script:

```bash
#!/usr/bin/env bash
#
# setup-foo — one-line summary.
#
# order: 20
# description: Shown in --list and in the run header
```

`order` defaults to `50` if absent; ties break alphabetically. Leave gaps
(10, 20, 30) so something can be slotted in later. Rough convention:

| Range | For |
| --- | --- |
| 0–19 | Prerequisites — packages, repos, directories |
| 20–49 | Core system and session config |
| 50–79 | Applications and dotfiles |
| 80–99 | Cleanup, verification, anything wanting the rest done first |

A script in `bin/` that is not executable is skipped with a warning, not
silently ignored.

## One password for the whole run

Eight of the setup scripts shell out to `sudo`. Left to themselves each one
prompts separately, which is both tedious and hard to answer safely — by the
fifth prompt nobody is reading which script is asking.

`setup-all` takes the credential once, before the first script starts, and
refreshes it every 60 seconds until the run finishes. That is the same
credential the first script's own prompt would have cached, for the same
duration; the refresh only stops it expiring partway through a long run, which
a Brave build on its own can outlast.

It asks only when it needs to:

- never under `--dry-run`, which is documented as needing no password —
  `setup-security-hardening` reports UFW as unavailable rather than asking;
- never when a valid credential is already cached;
- never when no selected script actually calls `sudo`. A script that only
  mentions it in a comment does not count.

The refresh stops when the run ends, not when the process exits, so the
credential is not held open while the menu sits idle between runs in the TUI.

If `sudo` is configured not to cache at all — `timestamp_timeout=0` in
`/etc/sudoers` — nothing can carry one prompt to the next. `setup-all` says so
once rather than letting the single prompt look as though it failed to work:

```text
warn sudo is configured not to cache credentials; each script will prompt
```

## Options

| Flag | Effect |
| --- | --- |
| `-t`, `--tui` | Force the interactive menu |
| `--no-tui` | Force the plain runner, even with no arguments |
| `-n`, `--dry-run` | Preview; passed through to every script |
| `-y`, `--yes` | Answer yes to prompts; passed through to every script |
| `-l`, `--list` | List scripts in order, then exit |
| `--only NAME` | Run only `NAME`. Repeatable or comma-separated |
| `--skip NAME` | Skip `NAME`. Repeatable or comma-separated |
| `--fail-fast` | Stop at the first failure |
| `-h`, `--help` | Usage |

`NAME` works with or without the `setup-` prefix: `--only ssh-agent` and
`--only setup-ssh-agent` are the same. An `--only` name matching no script is
an error rather than a silent no-op.

## Failure handling

By default a failing script does not stop the run — the rest still execute, and
the summary at the end lists every script with its result:

```
==> Summary (12s)
  ok setup-ssh-agent
 err setup-something — failed (exit 3)
 err 1 script(s) failed.
```

The exit status is non-zero if anything failed. Use `--fail-fast` when a later
script depends on an earlier one succeeding.

## Omarchy update safety

Do not install `setup-all` itself as a `post-update` hook. A full run would
rebuild Brave, prompt for SSH keys, and touch Docker or OpenSnitch during
`omarchy update`. Scripts that can be rewound by a migration or refresh install
their own thin hooks instead.

## Prompts

Scripts may ask for confirmation, and `setup-ssh-agent` prompts for key
passphrases. `setup-all` runs them attached to your terminal — in the menu too,
which is why scripts are not wrapped in a spinner — so answer as they come.
`--yes` skips confirmations but not passphrase prompts.

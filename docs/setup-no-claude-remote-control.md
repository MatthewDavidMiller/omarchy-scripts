# setup-no-claude-remote-control

Turns off Claude Code's Remote Control feature, so a session on this machine
cannot be driven from claude.ai or from another device.

```bash
./bin/setup-no-claude-remote-control            # disable it
./bin/setup-no-claude-remote-control --dry-run  # preview, change nothing
./bin/setup-no-claude-remote-control --allow-remote-control  # put it back
```

## The problem

Remote Control bridges a local Claude Code session to `claude.ai/code`, so the
session can be watched and driven from a phone or another machine. That is two
things worth being deliberate about: a standing outbound connection while the
session runs, and a remote path into an agent that is already holding a shell
on this box.

It is not on until something starts it, but there are several ways in — the
`claude remote-control` subcommand, the `--remote-control`/`--rc` flags, an
auto-start at session launch (`remoteControlAtStartup`), and an in-session
toggle. Turning off any one of them leaves the rest.

## What it does

Sets one key in the Claude Code **user** settings,
`~/.claude/settings.json`:

```json
{
  "disableRemoteControl": true
}
```

That is the switch that closes every entry point at once — `claude.ai/code`,
`claude remote-control`, `--remote-control`/`--rc`, the auto-start, and the
in-session toggle. Claude Code reads it at startup, so a session already
running keeps whatever it started with; new sessions come up with the feature
gone.

The narrower `"remoteControlAtStartup": false` only stops the auto-start and
leaves the feature one keystroke away, which is why this script uses the hard
switch instead.

Every other setting in the file is preserved, in the order it was written —
the file is hand-edited, and a rewrite that reshuffled it would make the backup
diff unreadable. The previous version is kept beside it as
`settings.json.bak.<timestamp>`. If the file is missing, it is created with
just this key; if it is not parseable JSON, the script refuses rather than
overwriting it.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print actions, change nothing |
| `-y`, `--yes` | Skip confirmation prompts |
| `--allow-remote-control` | Reverse: drop the key and allow Remote Control again |
| `-h`, `--help` | Usage |

## Environment

| Variable | Effect |
| --- | --- |
| `DRY_RUN=1` | Same as `--dry-run` |
| `CLAUDE_SETTINGS_FILE` | Settings path. Default `~/.claude/settings.json` |

## Scope

This is a per-user setting on this machine, not an account-wide one. It covers
Claude Code sessions started as you, here. It does not touch:

- **Other machines.** They have their own `~/.claude/settings.json`.
- **Other users on this box**, for the same reason.
- **Anything else Claude Code does over the network** — the model API calls
  themselves are the product, not a background service, and are unaffected.
- **A managed or project settings file.** Only user settings are written. A
  `disableRemoteControl` in managed settings would win regardless, which is how
  an administrator pins it.

## Verifying

```bash
python -c 'import json;print(json.load(open("'"$HOME"'/.claude/settings.json")).get("disableRemoteControl"))'
```

`True` means it is off. In a new session, the entry points are gone: `claude
--remote-control` and `claude remote-control` will not start a bridge, and the
in-session toggle is unavailable.

## Undo

```bash
./bin/setup-no-claude-remote-control --allow-remote-control
```

That removes the key rather than setting it to `false`, so Claude Code's own
default applies again. Remote Control is still off until you start it.

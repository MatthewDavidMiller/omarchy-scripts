# setup-no-idle

Stops the screensaver and the idle auto-lock from firing, so the machine stays
awake and unlocked until you lock it yourself.

```bash
./bin/setup-no-idle              # stay awake, no screensaver
./bin/setup-no-idle --dry-run    # preview, change nothing
./bin/setup-no-idle --allow-idle # put the stock behaviour back
```

## The problem

Omarchy's idle cycle lives in the Quickshell shell (`omarchy-shell`), not in
`hypridle`. Two timers hang off one idle monitor, configured in
`~/.config/omarchy/shell.json`:

```json
"idle": { "screensaver": 150, "lock": 300 }
```

The obvious edit — setting both to `0` — is the one thing you must not do. The
idle service reads those numbers as delays, and a delay of zero means *fire
immediately*:

```qml
if (root.screensaverDelaySeconds === 0) launchScreensaver()
if (root.lockDelaySeconds === 0) lockSystem("lock-timeout-immediate")
```

So `0` locks the screen the instant you stop typing. Negative and non-numeric
values are rejected and fall back to the 150/300 defaults. Nothing you can put
in `shell.json` turns the timers off.

## What it does

1. **Sets stay-awake** (`omarchy toggle idle stay-awake`), which writes
   `~/.local/state/omarchy/indicators/stay-awake`. The idle service gates its
   entire cycle on that file — the idle monitor itself is disabled, so neither
   the screensaver timer nor the lock timer ever starts. This is the same
   switch as the 󰅶 indicator in the bar.
2. **Disables the screensaver outright** (`omarchy toggle screensaver-off on`),
   so the menu entry and any keybinding cannot start it either. Skip this step
   with `--keep-screensaver` if you still want to launch it by hand.

Both are state files, so both survive a reboot, and the shell watches the state
directory — the change applies immediately, with no restart or logout.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print actions, change nothing |
| `-y`, `--yes` | Skip confirmation prompts |
| `--keep-screensaver` | Only stop the idle timers; leave the screensaver launchable by hand |
| `--allow-idle` | Reverse everything — stock screensaver and auto-lock return |
| `-h`, `--help` | Usage |

## What it does not disable

Only *idle* triggers go away. These still lock the screen:

- `Super + Ctrl + L` (`omarchy-system-lock`) — on demand.
- Suspend, via `omarchy system sleep monitor`, which locks before sleeping.
- Closing the lid, via `omarchy system lid close`.

Suspend itself is unaffected too. Stay-awake is a shell-level flag, not a
sleep inhibitor: on a laptop, systemd may still suspend the machine on battery,
and it will lock on the way down. `logind`'s own `IdleAction` is `ignore` on a
stock Omarchy install, so it is not a second source of idle locking.

## Verifying

```bash
omarchy toggle idle status                  # {"enabled":true,...} means staying awake
omarchy toggle enabled screensaver-off      # exit 0 means the screensaver is off
omarchy-shell idle status                   # the live service's view: timers, cycle state
```

`omarchy-shell idle status` reports `"enabled": false` while stay-awake is set —
that field is the *idle service*, not the toggle, and false is what you want.

## Undo

```bash
./bin/setup-no-idle --allow-idle
```

or, equivalently, click the 󰅶 indicator in the bar (that one only covers
stay-awake; it leaves the screensaver flag alone).

# setup-no-lid-sleep

Stops closing the laptop lid from suspending, hibernating, or powering off the
machine — on battery, on external power, and docked.

```bash
./bin/setup-no-lid-sleep                   # lid close does nothing to power
./bin/setup-no-lid-sleep --dry-run         # preview, change nothing
./bin/setup-no-lid-sleep --allow-lid-sleep # put the stock behaviour back
```

## The problem

Two things react to the lid on Omarchy, and only one of them touches power:

- **Hyprland** binds `switch:on:Lid Switch` to `omarchy-system-lid-close`, which
  locks the session (when no external monitor is connected) and moves the
  displays into clamshell mode. It never suspends.
- **systemd-logind** handles the lid switch itself. Its defaults are:

  ```ini
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend   # inherits HandleLidSwitch when unset
  HandleLidSwitchDocked=ignore
  ```

Omarchy ships logind drop-ins for the power key (`10-ignore-power-button.conf`)
and the pre-suspend inhibit delay (`20-inhibit-delay.conf`), but nothing for the
lid, so the systemd default is what suspends the machine.

## What it does

1. **Installs** `config/systemd/logind.conf.d/90-omarchy-scripts-lid-ignore.conf`
   to `/etc/systemd/logind.conf.d/`, setting all three lid actions to `ignore`.
   It sorts after Omarchy's drop-ins, and `ignore` covers every power action
   logind could take — `suspend`, `hibernate`, `hybrid-sleep`,
   `suspend-then-hibernate`, and `poweroff`.
2. **Reloads** `systemd-logind`. Never restarts it: restarting logind tears
   down the running graphical session.
3. **Checks** what the running logind reports over D-Bus, not just the file. If
   the file is in place but logind never applied it (a failed reload last
   time), the next run reloads again rather than reporting success.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print actions, change nothing |
| `-y`, `--yes` | Skip confirmation prompts |
| `--allow-lid-sleep` | Remove the drop-in; closing the lid suspends again |
| `-h`, `--help` | Usage |

## What it does not change

- **The lid still locks the session** when undocked. That is the Hyprland
  binding, it is a screen lock rather than a power state, and it means a closed
  laptop in a bag is not an unlocked one.
- **Clamshell mode** still works: with an external monitor connected, closing
  the lid moves everything to it.
- **Suspend from the menu, the sleep key, and idle** are untouched. Only the lid
  switch is ignored.

A laptop that stays running with its lid shut can get hot in a bag. Suspend it
from the system menu first when packing it away.

## Omarchy update safety

The drop-in is a new file in `/etc/systemd/logind.conf.d/` that no package owns,
so neither `omarchy update`, `omarchy refresh`, nor an `omarchy-settings`
upgrade touches it. No hook is needed.

## Verifying

```bash
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager HandleLidSwitch               # s "ignore"
systemd-analyze cat-config systemd/logind.conf | grep HandleLid
```

## Undo

```bash
./bin/setup-no-lid-sleep --allow-lid-sleep
```

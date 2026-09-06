# setup-desktop-cpu-priority

Gives the compositor and your editor a decisive share of the CPU against
background container builds, so a long compile cannot get an editor window
killed.

```bash
./bin/setup-desktop-cpu-priority              # containers drop to CPUWeight 20
./bin/setup-desktop-cpu-priority --dry-run    # preview, change nothing
./bin/setup-desktop-cpu-priority --weight 50  # yield less to the desktop
./bin/setup-desktop-cpu-priority --revert     # back to the default 100
```

## The problem

A saturated CPU does not just make an editor slow. It makes it die.

Electron watches its own renderers and kills one that fails to answer a ping
inside a fixed window — Cursor's default, visible in its own log, is 15
seconds:

```
[RendererPing] enabled (intervalMs=5000, blockThresholdMs=15000, stacks=true)
...
CodeWindow: renderer process gone (reason: killed, code: 9)
```

The assumption behind that timeout is that a renderer silent for fifteen
seconds has wedged. A renderer that is merely waiting for a timeslice is
indistinguishable from one that has, so on a machine with far more runnable
compilers than cores, editor windows die of a diagnosis that was wrong.

Two things this is **not**, both worth ruling out before reaching for this
script, because they have their own fixes:

- **Not memory.** Nothing is out of memory when this happens. `systemd-oomd`
  never fires and the kernel logs no OOM kill. `journalctl -k | grep -i
  'out of memory'` staying empty across the crash is what tells you apart.
- **Not a bug in the editor.** The timeout is a reasonable guess about a
  machine that schedules a foreground process within a second or two. The fix
  is to make that guess true again.

By default it is not true. The user manager gives its three slices the same
CPU weight:

```
user@1000.service/session.slice/...                Hyprland          100
user@1000.service/app.slice/app-cursor-<pid>.scope editors, terminals 100
user@1000.service/user.slice/libpod-<id>.scope     containers         100
```

Three siblings, one weight each, so a container population competes with the
compositor on equal terms and wins by outnumbering it. Three concurrent gate
builds on a 4-core laptop is enough to push an editor past fifteen seconds of
starvation.

## What it does

Writes one drop-in and reloads the user manager:

```ini
# ~/.config/systemd/user/user.slice.d/10-cpu-weight.conf
[Slice]
CPUWeight=20
```

Rootless Podman runs every container as a transient scope under the user
manager's `user.slice`, so lowering that one slice separates all containers
from everything else in a single place — no per-project configuration, no
per-container flags, however many run at once.

**Weight is proportional, not a cap.** With the desktop idle a build still gets
every core; when the desktop wants the CPU, containers yield within a
scheduling quantum. That is exactly the property a watchdog timeout needs, and
a fixed quota (`CPUQuota=`, `podman --cpus`) does not give it — a quota leaves
cores idle when nothing else wants them, and still lets a build hold what it
was granted while an editor waits.

At the default weight of 20 against 100, the desktop gets roughly five times
the share of every container put together. That 100 is not an implicit default
to be guessed at — systemd sets it explicitly in the `app.slice` and
`session.slice` unit files it ships, and gives its own `background.slice`
`CPUWeight=30`. So 20 sits just below what systemd already calls background
work, which is where a build you are not waiting on belongs.

The script then reads `cpu.weight` back out of the live cgroup rather than
trusting that systemd accepted the value, and reports what the kernel is
actually scheduling with.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print actions, change nothing |
| `-y`, `--yes` | Skip confirmation prompts |
| `-w`, `--weight N` | CPU weight for container scopes, 1–10000. Default 20 |
| `--revert` | Remove the drop-in; back to the default weight of 100 |
| `-h`, `--help` | Usage |

`CPU_WEIGHT=N` in the environment is the same as `--weight N`.

## What it does not cover

- **Builds run straight on the host.** A `cargo build` in a terminal lands in
  `app.slice` beside your editor, where this does not separate them. Put one
  under the same budget explicitly:

  ```bash
  systemd-run --user --scope --slice=user.slice -- cargo build
  ```

- **Rootful Docker.** Its containers are in the *system* manager's
  `system.slice`, which a user drop-in cannot reach. The script warns when
  `docker.service` is running; `bin/setup-rootless-podman` is what replaces it.

- **I/O.** Only `cpu`, `memory` and `pids` are delegated to a user manager —
  `io` is not, so there is no `io.weight` to set here and heavy build I/O can
  still stall a renderer. Check with:

  ```bash
  cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
  ```

  If CPU weight alone is not enough, the escalation is a scheduler built for
  the problem — `scx_lavd` from the official `scx-scheds` package — rather than
  more cgroup attributes. That is a bigger change and deliberately not part of
  this script.

- **Podman on the cgroupfs manager.** Containers may not land in `user.slice`
  at all. The script warns if `podman info` reports anything but `systemd`.

## Omarchy update safety

Nothing here is Omarchy's to overwrite, and that is checkable rather than
hopeful:

- **`omarchy update` does not write slice drop-ins.** Its migrations touch
  `~/.config/systemd/user/` in exactly one shape — specific *service* units and
  `graphical-session.target.wants` symlinks (`omarchy-sleep-lock`,
  `omarchy-fcitx5`, `omarchy-crash-watch`, `omarchy-migrate-notify`). None
  writes a `*.slice.d` directory.
- **No `omarchy refresh` target covers systemd user units.** The generic one,
  `omarchy refresh config <path>`, copies from `$OMARCHY_PATH/config` into
  `~/.config`, and Omarchy ships nothing under `config/systemd`. There is no
  path by which a refresh reaches this file.
- **Nothing else has a claim on `user.slice`.** `/usr/lib/systemd/user/`,
  `/etc/systemd/user/` and `~/.config/systemd/user/` ship no `user.slice.d` at
  all, so `10-cpu-weight.conf` collides with nothing — and being in the
  highest-priority of those three directories, it cannot be shadowed by one
  appearing later under the same name.

It also does not fight `10-oomd.conf`, the drop-in Omarchy ships at
`/usr/lib/systemd/user/app.slice.d/`. That one sets `ManagedOOM*` on
`app.slice`; this one sets `CPUWeight` on `user.slice`. Different slice,
different property, and drop-ins merge rather than replace. The migration that
installed it (`1785424256.sh`) ends in `systemctl --user daemon-reload`, which
re-applies this drop-in rather than disturbing it.

So no `post-update` hook is needed for this script — unlike the ones in
`config/hooks/post-update.d/`, there is nothing here for an update to rewind.

The one thing that would break it is upstream changing where rootless Podman
puts containers. That is Podman's decision, not Omarchy's, and it would show up
as the script's own verification passing while `systemd-cgtop` shows
`libpod-*` scopes outside `user.slice`.

## Verifying

```bash
systemctl --user show user.slice -p CPUWeight       # CPUWeight=20
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/user.slice/cpu.weight
systemd-cgtop --order=cpu                           # who is actually getting it
```

Under load, `systemd-cgtop` should show the `libpod-*` scopes yielding to
`app.slice` rather than crowding it out. The real test is the one that used to
fail: start a full build, keep typing, and watch for `renderer process gone` in
`~/.config/Cursor/logs/*/main.log` — or `~/.config/Code/logs/*/main.log` — that
should no longer appear.

## Undo

```bash
./bin/setup-desktop-cpu-priority --revert
```

The drop-in is removed and `user.slice` returns to the default weight of 100
immediately. Timestamped backups of earlier versions are left in place.

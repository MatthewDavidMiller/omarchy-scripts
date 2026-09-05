# setup-no-aur-updates

Stops `omarchy update` from reaching the AUR, which this machine takes no
packages from, and removes the AUR helper package.

```bash
./bin/setup-no-aur-updates            # install the shims, remove the helper
./bin/setup-no-aur-updates --dry-run  # preview, change nothing
./bin/setup-no-aur-updates --allow-aur-updates  # put it back
```

Re-run it after any Omarchy update that resets `~/.config/hypr/hyprland.lua` —
see [PATH precedence](#path-precedence). It is idempotent, so re-running when
nothing has changed reports skips and writes nothing.

Run it from a terminal started *after* the override went in. A shell older than
that keeps its own PATH and the script will say so; see
[It only reaches processes started after it](#it-only-reaches-processes-started-after-it).

## The problem

`omarchy update` runs `omarchy-update-aur-pkgs` between the `post-update` hook
and the mise step:

```bash
if pacman -Qem >/dev/null; then
  if omarchy-pkg-aur-accessible; then
    ...
  else
    echo -e "\e[31m\nAUR is unavailable (so skipping updates)\e[0m"
  fi
fi
```

Both halves of that gate are wrong here.

`pacman -Qem` lists foreign — non-repository — packages that were explicitly
installed. On this machine that is exactly one package, `brave-browser-local`,
which [`setup-brave`](setup-brave.md) builds from Brave's signed first-party
release. It is not an AUR package, but it *is* foreign, so the gate opens.

`omarchy-pkg-aur-accessible` is then a bare curl:

```bash
curl -sf --connect-timeout 30 --retry 3 --retry-delay 3 -A "omarchy-update" \
  "https://aur.archlinux.org/rpc/?v=5&type=info&arg=base" >/dev/null
```

What that costs depends on the [OpenSnitch](setup-opensnitch.md) verdict of the
moment, and neither outcome is wanted:

- **Dropped.** OpenSnitch is deny-by-default and drops rather than refuses, so
  curl waits out its whole retry budget — `30s connect + 3s + 30s + 3s + 30s +
  3s + 30s ≈ 129 seconds` — before the update prints "AUR is unavailable (so
  skipping updates)" and carries on. The correct outcome, reached the slowest
  possible way, once per update.
- **Allowed.** A process-wide `allow /usr/bin/curl` answered at some prompt
  outranks the narrower rules, the probe succeeds, and the update goes on to
  run an AUR helper this machine deliberately does not have.

Either way it is a question the
[package-source policy](conventions.md#package-sources) settled long ago:
nothing on this machine comes from the AUR.

## What it does

Installs five shims into `/usr/local/bin`, mode `0755`:

| Shim | Behaviour |
| --- | --- |
| `omarchy-update-aur-pkgs` | Prints one line and exits 0. This is the step that costs the two minutes. |
| `omarchy-pkg-aur-accessible` | Exits 1 with no network call. Reporting the AUR as unreachable is also simply true here. |
| `omarchy-pkg-aur-add` | Refuses, pointing at the package-source policy. |
| `omarchy-pkg-aur-install` | Refuses, the same way. |
| The AUR helper's own name | Forwards read-only `-Q…` queries to `pacman`; refuses everything else. |

Then it removes the AUR helper package with `omarchy pkg drop`, after showing
the `pacman -Rs --print` removal set and asking. The helper is explicitly
installed, required by nothing, not a dependency of `omarchy`, and its own
dependencies are `pacman` and `git` — and `git` is a hard dependency of
`omarchy`, so nothing else goes with it.

Finally it checks that `/usr/local/bin` really is searched before `/usr/bin` on
a **login** shell's PATH, and reports what it found.

### Why `/usr/local/bin`

`omarchy-update` calls these commands by bare name, so the lookup goes through
PATH, and `/usr/local/bin` precedes `/usr/bin` on the default Arch PATH.
Pacman never writes to `/usr/local`, so nothing here is at risk from a package
upgrade.

Preceding `/usr/bin` is not the same as winning, though — see
[PATH precedence](#path-precedence) below, which is the check that turns a shim
into a shim that actually runs.

The alternatives were all worse:

- **Editing `/usr/share/omarchy/bin/…`** does not survive.
  `omarchy-update-system-pkgs` runs `pacman -Syu` with
  `--overwrite '/usr/share/omarchy/*'` on *every* update, so the edit is
  silently reverted, and it would break `pacman -Qkk` in the meantime.
- **A shim in `~/.local/bin`** cannot work. Omarchy's `env-bootstrap`
  *appends* that directory, so a login shell orders it `/usr/local/bin`,
  `/usr/bin`, `~/.local/bin` — it can never shadow `/usr/bin`.
- **Shimming `/usr/share/omarchy/bin` itself**, which would win outright, has
  the same problem as editing anything else under `/usr/share/omarchy`: it is
  pacman-owned and `--overwrite '/usr/share/omarchy/*'` restores it on every
  update. The PATH override above gets the same result without touching it.
- **An `omarchy-hook post-update` entry** runs one line *before* the AUR step
  and cannot cancel it.
- **Blackholing `aur.archlinux.org` in `/etc/hosts`** still leaves curl's
  `--retry 3 --retry-delay 3` budget, about 9 seconds, and blackholes the host
  for everything on the machine.
- **Marking `brave-browser-local` `--asdeps`**, so `pacman -Qem` comes back
  empty, makes it an orphan — and `omarchy-update-orphan-pkgs` runs two lines
  later and offers to remove it.

### Nothing is clobbered

Every shim carries the line `omarchy-scripts:no-aur-updates`. A file in the
shim directory without that marker is reported and left exactly as it is, both
when installing and when reversing. Where a shim does replace an earlier one,
the previous version is kept beside it as `.bak.<timestamp>`.

### Why the helper keeps a shim after the package goes

`omarchy-pkg-remove` — the `omarchy pkg remove` picker, which has nothing to do
with the AUR — runs the helper as `-Qqe` and `-Qi`, purely as local pacman
queries. Removing the package outright would break that picker. The query-only
shim keeps it working, and makes the name structurally incapable of installing
anything, which is a stronger statement than the name merely being absent.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print actions, change nothing |
| `-y`, `--yes` | Skip confirmation prompts |
| `--allow-aur-updates` | Reverse: remove the shims |
| `-h`, `--help` | Usage |

## Environment

| Variable | Effect |
| --- | --- |
| `DRY_RUN=1` | Same as `--dry-run` |
| `OMARCHY_SHIM_DIR` | Where shims go. Default `/usr/local/bin` |
| `OMARCHY_BIN_DIR` | Where Omarchy's commands live. Default `/usr/bin` |
| `OMARCHY_LOGIN_PATH` | PATH to check precedence against, instead of asking a login shell |
| `OMARCHY_MANAGER_PATH` | PATH to check precedence against, instead of asking the systemd user manager. Empty skips that check |
| `OMARCHY_HYPR_DIR` | Hyprland config directory. Default `~/.config/hypr` |

## Scope

This changes what `omarchy update` does on this machine, and nothing else. It
does not:

- **Change any Omarchy file.** The shims live in `/usr/local/bin` and the PATH
  override in `~/.config/hypr`, so an Omarchy upgrade cannot undo the shims and
  `pacman -Qkk` stays clean. An upgrade *can* reset `hyprland.lua` and take the
  require line with it; re-running this script puts it back.
- **Touch the OpenSnitch rules.** The machine-local `191-deny-aur-helpers` rule
  stays as it is. Note it is not a second line of defence for this: it matches
  `process.path` `^/usr/bin/(yay|paru)$`, so it never sees the probe, which is
  `curl`. Nothing at the network layer denies `curl` reaching
  `aur.archlinux.org`, and a process-wide `allow /usr/bin/curl` answered at a
  prompt would outrank `191` anyway, since curated denies are deliberately
  `precedence: false`. PATH is the only thing stopping the probe, which is why
  the precedence check above is not optional.
- **Affect `pacman` or `omarchy pkg add`.** Repository packages install exactly
  as before.
- **Cover other machines or other users.** `/usr/local/bin` is machine-wide but
  each machine gets its own run.

## PATH precedence

A shim is only worth something if the name resolves to it, and
`/usr/local/bin` preceding `/usr/bin` does not settle that. In an Omarchy
Hyprland session it is normally false:

```
$ command -v omarchy-update-aur-pkgs
/usr/share/omarchy/bin/omarchy-update-aur-pkgs
```

`/usr/share/omarchy/default/hypr/envs.lua` prepends `$OMARCHY_PATH/bin`
unconditionally:

```lua
local bin_dir = paths.omarchy_path .. "/bin"
local kept = {}
for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
  if entry ~= bin_dir then table.insert(kept, entry) end
end
table.insert(kept, 1, bin_dir)
hl.env("PATH", table.concat(kept, ":"))
```

`hl.env` is Hyprland's `env =`, which applies to what Hyprland **spawns** rather
than to Hyprland itself — which is why `/proc/<hyprland>/environ` looks clean
while every terminal it opens does not. That directory is a farm of symlinks
into `/usr/bin` (all 428 of them), so the upstream command is reached *without
`/usr/bin` appearing earlier at all*, and a check phrased in terms of
`/usr/local/bin` and `/usr/bin` cannot see it. Only the helper shim ran, because
that directory has no counterpart to shadow it — which is why
`/tmp/omarchy-update.log` showed the helper's refusal while the probe before it
had already gone out to the network.

It is applied fresh on every boot, so there is nothing to repair at runtime.
Note this is not dev-link leftovers: `env-bootstrap` deliberately skips the
prepend on a production install ("would just be noise"), but `envs.lua` does it
unguarded, and `envs.lua` is what the Hyprland session actually uses.

### The fix

User Hyprland config is loaded after Omarchy's defaults, so an override there
wins. It goes in **two** pieces, because a single block appended to
`hyprland.lua` is exactly what an update can take away:

| Piece | Where | Exposure to updates |
| --- | --- | --- |
| The override itself | `~/.config/hypr/omarchy-scripts-path.lua` | **None.** Not a config Omarchy ships, so `omarchy-refresh-config` refuses it (`Not a shipped user config`), `omarchy refresh hyprland` never lists it, and the migrations that replace a stock user file only touch names under `$OMARCHY_PATH/config/hypr/`. |
| One require line | `~/.config/hypr/hyprland.lua` | **Yes.** `omarchy refresh hyprland` overwrites this file, and migrations have rewritten it before (`1781063758`). |

```lua
-- ~/.config/hypr/hyprland.lua, after require("default.hypr.omarchy")
pcall(require, "hypr.omarchy-scripts-path")
```

`setup-no-aur-updates` owns both. It writes the module, and it re-adds the
require line whenever it has gone — so recovering from an update that reset
`hyprland.lua` is one `./bin/setup-no-aur-updates` away, and the precedence
check fails loudly until then.

The module rebuilds the order rather than editing it, because `os.getenv("PATH")`
inside it is Hyprland's own PATH and does not carry what `envs.lua` set for
children. Omarchy's bin directory is re-inserted exactly as `envs.lua` places
it, just behind `/usr/local/bin` — and since every entry in it is a symlink to
the same name in `/usr/bin`, the only names whose resolution changes are the
ones shimmed here.

#### Why `pcall`

Omarchy ships `require_optional`, but it only guards a *missing* module and
depends on an internal path. `pcall` needs nothing and cannot abort config
parsing. Both failure modes were tested against the running compositor:

| State | `hyprctl configerrors` | Session | PATH |
| --- | --- | --- | --- |
| Module missing | clean | starts | falls back to Omarchy's order |
| Module has a syntax error | **reports it** | starts | falls back to Omarchy's order |

So a damaged override degrades to "the shims are shadowed" — which
`setup-no-aur-updates` reports as a failure — and never to a session that will
not start.

#### Applying it

```bash
hyprctl reload && hyprctl configerrors     # must print nothing
```

Then confirm what a *freshly spawned* process gets; a shell you already had open
keeps the PATH it was given:

```bash
hyprctl dispatch 'hl.dsp.exec_cmd("sh -c \'command -v omarchy-update-aur-pkgs > /tmp/p\'")'
cat /tmp/p    # => /usr/local/bin/omarchy-update-aur-pkgs
```

#### It only reaches processes started after it

`hl.env` is applied when a process is spawned. Anything already running keeps
the PATH it was given, and `hyprctl reload` cannot reach back into it. So after
installing the override:

| Started | Gets the new order |
| --- | --- |
| A terminal opened from Hyprland now | yes |
| A systemd user unit started now | yes — Hyprland's autostart imports its environment into the manager |
| An editor, terminal, or session that has been up since boot | **no**, until it is restarted |

This is the common surprise: running `setup-all` from a long-lived VS Code
window reports every shim as shadowed, because that window has held the
boot-time PATH since before the override existed. Nothing is wrong with the
install; restart the program.

### What the script checks

It resolves each shim name the way the shell does, against two PATHs:

| PATH | Why |
| --- | --- |
| A login shell's | What *this* shell runs, inherited from whatever spawned it |
| The systemd user manager's | What user units get; Hyprland's autostart imports its own environment into it |

What a *new* process will get is decided by the override and the manager
environment, not by whatever this shell is carrying, so the two outcomes are
graded differently:

| State | Result |
| --- | --- |
| Override installed, manager PATH clean, login PATH stale | **exit 0**, with a note to restart the program this ran under |
| Manager PATH shadowed, or the override missing or not wired | **exit 1** — a new process would still reach the AUR |

Any shim that loses is named along with the file that beat it either way, so the
warning is never swallowed. `setup-all` reports only the second as a failure.

A failed write is treated the same way. `install_root_file` is called with
`|| true` so a skip can pass through, and that suppresses `set -e` for its whole
body, so every `sudo` in it is checked by hand; without that a `sudo` that could
not read a password printed `ok wrote` over a file it never touched.

## Verifying

In a new shell, so the PATH is not a stale one. The first line is the one that
matters — a shim that is not what the name resolves to changes nothing:

```bash
command -v omarchy-update-aur-pkgs   # => /usr/local/bin/omarchy-update-aur-pkgs
time omarchy-pkg-aur-accessible      # exit 1, ~0.00s real
omarchy pkg remove                   # the picker still lists packages
```

Then time a real update and check the log:

```bash
time omarchy update
grep -i aur /tmp/omarchy-update.log
```

The AUR line should be the shim's own — `AUR updates disabled by
omarchy-scripts` — with no probe and no helper run. Two lines that mean it did
**not** work, both seen on this machine:

- `AUR is unavailable (so skipping updates)` — upstream's probe ran and was
  blocked. The shim was shadowed.
- `Update AUR packages` followed by the helper shim's refusal — upstream's probe
  ran and *succeeded*. The shim was shadowed and the curl was allowed.

The OpenSnitch event list should show no `curl` connection to
`aur.archlinux.org` for that run at all, allowed or denied.

## Undo

```bash
./bin/setup-no-aur-updates --allow-aur-updates
```

That removes the shims and leaves everything else alone. The helper package is
**not** reinstalled; if you want it back:

```bash
omarchy pkg add yay
```

It comes from the `[omarchy]` repository rather than the AUR, and because
nothing depends on it, `omarchy update` will not pull it back on its own.

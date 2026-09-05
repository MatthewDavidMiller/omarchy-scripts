# setup-no-aur-updates

Stops `omarchy update` from reaching the AUR, which on this machine can only
time out, and removes the AUR helper package.

```bash
./bin/setup-no-aur-updates            # install the shims, remove the helper
./bin/setup-no-aur-updates --dry-run  # preview, change nothing
./bin/setup-no-aur-updates --allow-aur-updates  # put it back
```

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

[OpenSnitch](setup-opensnitch.md) is deny-by-default, so that connection is
dropped rather than refused, and curl waits out the full budget:

```
30s connect + 3s + 30s + 3s + 30s + 3s + 30s  ≈  129 seconds
```

Every `omarchy update` therefore spends about two minutes rediscovering
something the [package-source policy](conventions.md#package-sources) settled
long ago: nothing on this machine comes from the AUR. The update then prints
"AUR is unavailable (so skipping updates)" and carries on, which is the correct
outcome reached the slowest possible way.

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

The alternatives were all worse:

- **Editing `/usr/share/omarchy/bin/…`** does not survive.
  `omarchy-update-system-pkgs` runs `pacman -Syu` with
  `--overwrite '/usr/share/omarchy/*'` on *every* update, so the edit is
  silently reverted, and it would break `pacman -Qkk` in the meantime.
- **A shim in `~/.local/bin`** cannot work. Omarchy's `env-bootstrap`
  *appends* that directory, so a login shell orders it `/usr/local/bin`,
  `/usr/bin`, `~/.local/bin` — it can never shadow `/usr/bin`.
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

## Scope

This changes what `omarchy update` does on this machine, and nothing else. It
does not:

- **Change any Omarchy file.** Everything lives in `/usr/local/bin`, so an
  Omarchy upgrade cannot undo it and `pacman -Qkk` stays clean.
- **Touch the OpenSnitch rules.** The machine-local `191-deny-aur-helpers` rule
  is the network-layer statement of the same policy and stays as it is; this is
  the same policy stated where the update tool reads it, so the block is never
  reached rather than being reached slowly.
- **Affect `pacman` or `omarchy pkg add`.** Repository packages install exactly
  as before.
- **Cover other machines or other users.** `/usr/local/bin` is machine-wide but
  each machine gets its own run.

A session started **before** the shims were installed keeps its old PATH. On a
packaged install `/usr/share/omarchy/bin` is not on PATH at all, but a shell
that predates an upgrade can still carry a stale copy of it ahead of
`/usr/local/bin`; the script warns when it sees that. New sessions are fine.

## Verifying

In a new shell, so the PATH is not a stale one:

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

The AUR line should be the shim's own, with no probe and no helper run, and the
update should be about two minutes shorter. The OpenSnitch event list should
show no denied `curl` connection to `aur.archlinux.org` for that run, where
previously there was one per update.

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

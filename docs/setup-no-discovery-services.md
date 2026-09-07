# setup-no-discovery-services

Disables the CUPS printing daemon and the Avahi mDNS daemon on a machine that
does not print and does not need `.local` name resolution.

```bash
./bin/setup-no-discovery-services
./bin/setup-no-discovery-services --dry-run
./bin/setup-no-discovery-services --revert
```

`setup-all` runs it like every other script. On a machine that prints, hold it
back:

```bash
./bin/setup-all --skip no-discovery-services
```

## Why you might skip it

Neither daemon is a live hole on a machine with this repository's baseline
applied. UFW's `deny incoming` means Avahi's `0.0.0.0:5353` and `[::]:5353`
sockets receive nothing from the network, and CUPS listens only on loopback.
Turning them off reduces the local attack surface; it does not close an open
door. Weigh that against losing printing, and `--skip` it if you print.

What it does buy is the removal of the worst-scoring unit on a stock Omarchy
install. `systemd-analyze security` rates `cups.service` 9.6 UNSAFE: it runs as
root behind a print-job parser, a configuration parser, and a filter pipeline.
Avahi is a root-adjacent daemon whose job is parsing multicast packets. On a
laptop that has never printed, both are cost without benefit.

## What it changes

Five units, in this order:

```text
cups.path  cups.socket  cups.service
avahi-daemon.socket  avahi-daemon.service
```

Order matters. `cups.socket` and `cups.path` both activate `cups.service` on
demand, so stopping the service first would only have it started again by the
next print-queue access. The activators go first.

Packages are never removed. `cups` is required by nothing, but `avahi` is a
dependency of `libcups`, `nss-mdns`, `passim`, `pipewire-pulse` and
`tinysparql`. Disabling units is what makes `--revert` a real reversal.

## What stops working

Three things, none of which is an error:

- **`.local` names stop resolving.** `/etc/nsswitch.conf` has
  `hosts: mymachines mdns_minimal [NOTFOUND=return] resolve files ...`. With
  Avahi stopped, `nss-mdns` returns `UNAVAIL` rather than `NOTFOUND`, so the
  `[NOTFOUND=return]` guard is never reached and ordinary DNS still answers —
  but nothing answers for `.local`, and every hostname lookup pays one failed
  socket connect on the way past. Removing `mdns_minimal` from that line
  removes the cost. This script does not edit `/etc/nsswitch.conf`, which glibc
  owns.
- **Network audio sinks stop appearing.** `pipewire-pulse` links Avahi to
  discover RAOP/AirPlay targets. Local audio is unaffected.
- **Printing stops**, discovery and all. A printer added later needs `--revert`
  first.

## Update safety

Omarchy enables both daemons in `install/config/enable-services.sh`:

```bash
systemctl enable cups.service
systemctl enable avahi-daemon.service
```

That runs during installation, not on update, so `omarchy update` will not
re-enable them. No `post-update` hook is installed, and adding one
speculatively would only make every update slower.

## The printer tray applet

`system-config-printer` ships `/etc/xdg/autostart/print-applet.desktop`, which
every session starts. The supported way to suppress a system autostart entry is
a user-level copy carrying `Hidden=true`; Omarchy already writes one. The
script reports whether that is in place and prints the one-liner to create it,
rather than writing it — an entry the user does not have is not this script's
to add, and a printer-less machine losing a tray icon is not a security
finding.

## OpenSnitch

If you also run `bin/setup-opensnitch`, the two shared Avahi rules
(`omarchy-shared-030-allow-avahi-mdns-ipv4` and `-031-...-ipv6`) become allows
for a daemon that no longer runs. They are left in place: a rule that cannot
fire costs nothing, and keeping the shared rule set identical across machines
is worth more than pruning two dead entries.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print changes without applying them |
| `-y`, `--yes` | Accepted for `setup-all` compatibility; there are no prompts |
| `--keep-cups` | Leave CUPS alone; only disable Avahi |
| `--keep-avahi` | Leave Avahi alone; only disable CUPS |
| `--revert` | Re-enable and start both daemons |
| `-h`, `--help` | Show usage |

## Verifying

```bash
systemctl is-enabled cups.service cups.socket cups.path
systemctl is-enabled avahi-daemon.service avahi-daemon.socket
ss -tulpn | grep -E ':(631|5353)'   # expect no output
getent hosts archlinux.org          # ordinary DNS still resolves
```

A second run reports every unit as already handled and changes nothing.

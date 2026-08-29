# OpenSnitch outbound access control

OpenSnitch adds per-application outbound policy without turning the machine
into a second full-time firewall project. UFW remains responsible for the
simple inbound policy established by `setup-security-hardening`; OpenSnitch
uses nftables only to identify and control outgoing connections.

The setup is intentionally opt-in because its default policy is immediately
restrictive:

```bash
./bin/setup-opensnitch --dry-run
./bin/setup-opensnitch
# or
./bin/setup-all --only opensnitch
```

The package comes from Arch's signed `extra` repository through
`omarchy pkg add`. No AUR helper or upstream binary installer is used. The
[official Arch package](https://archlinux.org/packages/extra/x86_64/opensnitch/)
contains the daemon, UI, systemd unit, and eBPF objects in one package.

## Security model

The daemon is configured with:

- default action `deny` and unknown-process interception disabled, so an
  unidentified connection is dropped rather than generating an unhelpful
  permanent exception;
- the eBPF process monitor and nftables firewall backend;
- queue bypass disabled (or overflow action `drop` on newer supported schemas),
  keeping enforcement fail-closed if userspace cannot consume queued traffic;
- checksum collection enabled for high-value local rules, without making
  checksums part of the portable baseline;
- a UI socket under `/run/user/<uid>/opensnitch/`, mode `0700`, rather than the
  shared `/tmp` namespace.

The UI also defaults to deny. New answers last only until restart unless you
deliberately choose `always`; this prevents one troubleshooting click from
becoming an unnoticed permanent permission. OpenSnitch documents how the GUI
policy temporarily overrides the daemon policy while connected in its
[configuration guide](https://github.com/evilsocket/opensnitch/wiki/Configurations).

The setup adds `opensnitch-ui-secure` to Omarchy's user
`~/.config/hypr/autostart.lua`. In a live Hyprland session it validates the
configuration, starts the UI on the private socket, and only then starts the
daemon. Outside a graphical session it enables the daemon for boot but does
not cut off the current session without a UI.

## Portable baseline

Files in `config/opensnitch/rules/` are imported before enforcement. They are
grouped into bands so the difference between "the desktop does not work without
this" and "this repository's own workflow needs it" stays visible:

| Band | What belongs in it | Current rules |
| --- | --- | --- |
| `000`–`039` | System essentials | localhost v4/v6; `systemd-resolved` on 53/853; `systemd-timesyncd` on UDP 123; `NetworkManager` to `ping.archlinux.org:80`; `avahi-daemon` to the mDNS multicast groups on UDP 5353 |
| `040`–`059` | Scheduled system maintenance | `fwupd` to `fwupd.org`/`cdn.fwupd.org` for LVFS firmware metadata and images |
| `060`–`079` | This repository's own tooling | `podman`/`docker` to Docker Hub for the `bin/lint` base image; rootless container egress to `dl-cdn.alpinelinux.org`; `curl` to the four hosts `packages/brave` downloads from |

The essentials keep login-time local IPC, name resolution, clock
synchronization, connectivity detection, and `.local` discovery working without
granting general network access to a shell, interpreter, browser, or download
tool. The DNS rule follows OpenSnitch's recommendation to let the resolver
perform external DNS while applications use the local stub. See the upstream
[rules and best-practices guide](https://github.com/evilsocket/opensnitch/wiki/Rules).

Every baseline rule names a single executable and pins the destination as
tightly as the protocol allows. The Avahi pair is deliberately narrower than a
process-wide allow: it covers the multicast queries and announcements that make
`.local` names resolve, but not unicast replies to a LAN peer that queried from
an ephemeral port. If a peer on your network cannot see this host's services,
that is the rule to widen — by adding the peer's subnet, not by allowing
`avahi-daemon` everywhere.

Without the NetworkManager rule the connectivity check fails closed and every
network is reported as "limited", which is a confusing first symptom of a
correctly working firewall rather than a broken one.

Two of the tooling rules are worth reading before you copy them:

- **Container egress is not attributed to `podman`.** Rootless podman routes
  container traffic through pasta, so `apk add` inside a build shows up as the
  pasta helper, not as podman. Worse, `pasta` is a symlink that dispatches to a
  CPU-specific build, so the path OpenSnitch reports is `/usr/bin/passt.avx2`
  on a machine with AVX2 and `/usr/bin/passt` without it. The rule matches both
  by pattern. A literal `/usr/bin/pasta` matches neither. Destination matching
  does work for container traffic — OpenSnitch resolves `dl-cdn.alpinelinux.org`
  normally — so the rule stays host-scoped rather than granting the helper
  blanket access.
- **The `curl` rule is the documented alternative to a global one.** It names
  the four hosts `packages/brave/prepare-latest` and the PKGBUILD actually
  fetch from, including the `*.githubusercontent.com` hosts that GitHub
  redirects release assets to. Constraining `curl` by destination is the point;
  a process-wide `curl` allow would be worse than no rule at all.

Something that reaches the network on a timer rather than when you ask it to
needs a permanent rule or it will prompt when nobody is at the machine.
`setup-security-hardening` enables `arch-audit.timer`, which fires overnight
against `security.archlinux.org`; that rule is machine-local here only because
its counterpart, `pacman`, has to name host-specific mirrors.

Avoid permanent global rules for `curl`, `wget`, Python, Node, shells, or other
general-purpose interpreters. Constrain those by command line and destination
when a durable exception is genuinely needed. A dedicated browser executable
may reasonably receive a process-wide allow because maintaining every CDN and
site domain would defeat the purpose of a manageable policy.

## Normalizing learned rules

Rules created by clicking through the GUI get machine-generated names like
`allow-12h-list-usr-lib-electron40-electron-cursor-sh-443`. They work, but the
name encodes the answer's shape rather than its purpose, the `12h` is a leftover
from the prompt duration and no longer true once the rule is permanent, and any
version number baked into a path becomes a silent expiry date.

Rules on this machine are kept in two numbered ranges:

| Range | Owner | Lives in |
| --- | --- | --- |
| `000`–`099` | this repository, portable to any machine | `config/opensnitch/rules/` |
| `100`–`199` | machine-local, personal paths and private hosts | `/etc/opensnitchd/rules/` only |

Machine-local rules stay out of Git. Back them up with
`export-opensnitch-rules --allow-machine-specific`, which is also the check that
they really are machine-specific rather than something that belongs in the
shared baseline.

Three habits matter more than the numbering:

- **Match a versioned install by pattern, not by version.** A rule pinned to
  `.../mise/installs/claude/2.1.251/claude` stops matching the moment the tool
  updates, and the first symptom is an agent that has lost the network in the
  middle of a session. Use a `regexp` on `process.path`, for example
  `^/home/<user>/\.local/share/mise/installs/claude/[^/]+/claude$`.
- **Do not grant a shared runtime.** `/usr/lib/electron39/electron` is not
  Bitwarden; it is every Electron 39 application installed. Identify the
  application by `process.command`, which carries the app path
  (`/usr/lib/bitwarden/app.asar`, `/usr/share/cursor/`) that the interpreter
  path does not.
- **Write a description.** The GUI leaves it empty. A year later the only thing
  that distinguishes a deliberate exception from a panicked click is the
  sentence explaining why the destination is as wide as it is.

A permanent `deny` is occasionally the right answer, but only as the explicit
complement to a narrower allow. `190-deny-avahi-non-mdns` denies `avahi-daemon`
process-wide; it is safe purely because `omarchy-shared-030`/`031` allow the
mDNS multicast groups with `precedence: true` and are therefore matched first.
The pair reads as "mDNS multicast, nothing else, stop asking". Written that way
a deny is a policy; written alone it is a time bomb, because the day someone
prunes the allows the deny keeps working and nothing explains what broke. Say
so in the description, and give the deny a number that sorts after everything
it must not shadow.

Two other things reach the network on a schedule rather than when you ask them
to, so both need permanent rules or they will prompt at an hour when nobody is
watching:

- `pacman`, to whichever hosts `/etc/pacman.conf` and
  `/etc/pacman.d/mirrorlist` actually name — on this machine
  `pkgs.omarchy.org` for `[omarchy]` and `stable-mirror.omarchy.org` for
  `core`/`extra`/`multilib`. Scope the rule to those hosts rather than to
  `pacman` as a process, so editing the mirrorlist is a visible event.
- `arch-audit`, to `security.archlinux.org`. `setup-security-hardening` enables
  `arch-audit.timer`, which fires overnight. A vulnerability scanner that has
  quietly stopped scanning is worse than no scanner at all.

### Replacing a rule without losing connectivity

Replacing the allow that the current session depends on is the one edit that
can fail unrecoverably, because the failure removes the access needed to fix it.
Do it in this order:

1. Back up the whole rules directory somewhere outside `/etc`.
2. Install the replacement **first**, and confirm the daemon picked it up:

   ```bash
   grep -a 'Ruleset changed due to' /var/log/opensnitchd.log | tail
   ```

   opensnitchd watches its rules directory, so a new file is live within
   seconds. Do not restart the service to force it — a restart is exactly the
   moment a half-finished migration becomes a lockout.
3. Confirm the session still has network access.
4. Only then remove the predecessor, backing it up beside itself.

Never remove both the old and new form of an agent's own allow in one step. A
duplicate rule costs nothing; deleting the wrong one costs the session. When
verification is inconclusive, leave the old rule in place and clean it up later
from a session that does not depend on it.

## Sharing learned rules

After using the UI to create an enabled `allow` rule with duration `always`,
export selected rules to a local directory outside this project:

```bash
./bin/export-opensnitch-rules
./bin/export-opensnitch-rules allow-firefox
./bin/export-opensnitch-rules browser-rule.json
./bin/export-opensnitch-rules --output-dir "$HOME/Documents/opensnitch-rules" allow-firefox
./bin/export-opensnitch-rules --dry-run allow-firefox
```

The bare command opens a rule multiselect followed by a local directory picker.
When rules are supplied as arguments, the directory picker still opens unless
`--output-dir` or `OPEN_SNITCH_EXPORT_DIR` is set. Project directories are
rejected as export destinations. Arguments must match an internal rule name or
filename exactly. Exported JSON is normalized and gets a stable
`omarchy-shared-<slug>-<hash>.json` filename, so exporting it again is a no-op.

Rules containing a numeric UID, a home-directory path, a process hash, an
exact command line, an interface, or a private/link-local address are rejected
as non-portable. After reviewing the JSON, an intentional exception can be
exported with `--allow-machine-specific`.

To import an exported collection on another machine, point setup at its local
directory:

```console
OPEN_SNITCH_SHARED_RULES_DIR="$HOME/Documents/opensnitch-rules" ./bin/setup-opensnitch
```

Imported shared rules are added or updated. A same-named local rule is backed
up and replaced to avoid duplicate evaluation. A deleted shared file prunes the
installed file with the `omarchy-shared-` prefix, also after a backup. No
GUI-created file outside that namespace is ever pruned.

## Verification and recovery

```bash
systemctl status opensnitchd.service
grep -E 'DefaultAction|ProcMonitorMethod|Firewall' /etc/opensnitchd/default-config.json
ls -l /run/user/"$(id -u)"/opensnitch/osui.sock
sudo nft list ruleset | grep -i opensnitch
```

If an application is unexpectedly blocked, inspect the OpenSnitch Events view
and grant the narrowest temporary rule first. Promote it to `always` only after
the application works and the match fields are understood.

### A rule can be active and still be missing from the UI

The GUI's rule list is built when it connects to the daemon, and its database
is `file::memory:` by default. The daemon notices a file dropped into its rules
directory through inotify and reloads immediately — but it does not push that
change to a UI that is already connected. So every rule installed from outside
the GUI, which is every rule `setup-opensnitch` imports and every one migrated
by hand, is enforced at once and invisible until the UI reconnects.

The UI is therefore not the place to check whether a rule is live. These are:

```bash
ls /etc/opensnitchd/rules/
grep -a 'Ruleset changed due to' /var/log/opensnitchd.log | tail
```

Together they say the file is installed and that the daemon accepted it. The
third check is the one that actually matters: exercise the traffic and see it
work.

To refresh the UI's view, restart it — the launcher this setup installs is
enough, and it reconnects on its own:

```bash
pkill -x opensnitch-ui
~/.local/bin/opensnitch-ui-secure &
```

While the UI is down there is no one to answer prompts, so a new connection
gets the default action — `deny` — with no dialog. Keep the gap short.

To pause enforcement without deleting rules:

```bash
sudo systemctl stop opensnitchd.service
```

To keep it off after reboot:

```bash
sudo systemctl disable --now opensnitchd.service
```

Every modified configuration and pruned/replaced rule is backed up with a
timestamp. Restore the relevant backup and rerun the setup if policy files are
damaged; OpenSnitch automatically reloads changes under its rules directory.

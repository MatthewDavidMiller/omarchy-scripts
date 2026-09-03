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
becoming an unnoticed permanent permission. That setting is stored as a combo
box *index*, not a duration — `default_duration=7` is "until restart", and
index `6`, which upstream's own `DEFAULT_DURATION_IDX` labels "until restart",
is really `12h`. The distinction matters more than it looks: the prompt also
has a 30 second timeout that applies the default action unattended, so with
index 6 every prompt nobody was there to answer became a twelve-hour rule. OpenSnitch documents how the GUI
policy temporarily overrides the daemon policy while connected in its
[configuration guide](https://github.com/evilsocket/opensnitch/wiki/Configurations).

That index also decides whether a mis-click survives a reboot, which is the
part that is easy to miss. Under index `6` the daemon **wrote temporary rules
to `/etc/opensnitchd/rules`**: this machine's log shows an
`allow-12h-list-....json` file appearing seconds after each "Added new rule"
line, root-owned and `0600`. Under index `7` it does not — every "Added new
rule" since the setting changed has no matching "Ruleset changed due to", and
the rules live in the daemon's memory until it restarts. So the difference
between the two indices is not twelve hours versus one login. It is whether an
unanswered prompt leaves a durable file behind.

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
| `080`–`099` | Other projects' build toolchains, and the tool managers that install them | rootless container egress to the Rust distribution and crate registry, the Python package index, GitHub release assets and the RustSec advisory database, and the registries `trivy` pulls its vulnerability database from; `mise` to its version manifest, GitHub releases, and the sigstore TUF root |

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

The `080` band covers build toolchains belonging to other projects on this
machine — currently `rpi-omt-client`, whose gates run entirely inside a
container and therefore reach the network as pasta, exactly as `061` does.
Because every rootless container shares that one helper, these rules cannot be
scoped to a project; they are scoped to what the project downloads. That is the
honest description of what they grant: any rootless container may reach
`crates.io`, PyPI, GitHub, and the trivy database hosts. Keeping each purpose in
its own numbered rule is what makes that reviewable — deleting the Python rule
tells you immediately which gate stops working, where one merged
"development" allow would not.

Two consequences are worth stating plainly. A rule naming `github.com` alone
would allow the request and deny the payload, because GitHub redirects release
assets to `*.githubusercontent.com`; that alternation is load-bearing rather
than defensive. And `083` deliberately omits `storage.googleapis.com`, which
trivy's preferred `mirror.gcr.io` may redirect to: allowing it would open every
Google Cloud Storage bucket to every container, and the `ghcr.io` fallback
already completes the scan. A stall on the mirror is a prompt worth answering
by hand rather than a hole worth opening permanently.

`084` and `085` cover `mise`, which is a different shape of dependency: not a
project's toolchain but the thing that installs everything else, including the
tools rules `100`, `101` and `122` are written for. Two honest notes about it.
`084` names `github.com` and `api.github.com`, so it grants mise all of GitHub
— unavoidable when the job is fetching arbitrary release assets, and still far
narrower than the process-wide allow it replaces. And `085` is separate on
purpose: it is the sigstore TUF root mise checks signatures against, so if it
is ever deleted the symptom is "mise stopped verifying what it downloads" and
the named rule says so. Denying that host does not harden mise, it blinds it.

`084` also pins `release-assets.githubusercontent.com` exactly rather than
reusing the `[a-z0-9-]+\.githubusercontent\.com` alternation that `062`, `082`
and `122` need. If GitHub ever serves an asset from a different subdomain the
result is a prompt, which is the trade this baseline prefers.

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
- **Do not grant a shared runtime, and do not identify it by app path alone.**
  `/usr/lib/electron39/electron` is not Bitwarden; it is every Electron 39
  application installed. The obvious narrowing — match `process.command` for
  `/usr/lib/bitwarden/app.asar` — installs cleanly, reads correctly, and never
  fires. See [Why an Electron rule silently misses](#why-an-electron-rule-silently-misses).
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
it must not shadow. The denies this machine actually runs are listed under
[The permanent denies on this machine](#the-permanent-denies-on-this-machine).

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

### Promoting a temporary rule

A rule answered at a prompt is a decision made under time pressure, with a
30 second clock running, by someone who wanted to get on with something else.
Left alone it evaporates at the next reboot and the same prompt comes back, so
the machine keeps re-deciding rather than deciding once. Two commands close
that loop:

```bash
./bin/opensnitch-rulectl list --temporary   # what a reboot is about to lose
./bin/opensnitch-rulectl promote allow-until-restart-list-usr-bin-mise-github-com-443 \
    --scope shared --number 084 --slug allow-mise-tool-downloads \
    --description "why this exists" -o config/opensnitch/rules
```

`promote` writes one curated file — `duration: always`, `enabled: true`, a
banded name, and `precedence` set to `true` for an allow and `false` for a deny
— and then stops. It installs nothing, deliberately: the safe order is install,
verify, remove, and only a person can do the verifying. It prints those steps
with the temporary rule's name already filled in.

It also refuses, rather than warns, on anything the committed baseline would
reject later — a deny with `--scope shared`, a `process.command` operand, a
home path, a number outside its band — so a bad rule never reaches the tree.
The one thing it only warns about is a version-pinned `process.path`, because
sometimes that really is what you mean.

`promote --from-file rule.json` runs the same transformation on a file from
`show`, and never touches the socket. Note that `-o` accepts a path inside this
repository, which is the opposite of `export-opensnitch-rules`: export is a
backup and belongs outside the project, while a promoted portable rule belongs
in `config/opensnitch/rules/`.

### The permanent denies on this machine

Four, all machine-local, all `precedence: false`. That last part is
deliberate: none of them is the highest-priority thing that matches, so a
curated allow — which always carries `precedence: true` — beats them without
anyone having to edit the deny.

- **`190-deny-avahi-non-mdns`** — the complement to `030`/`031`, described
  above.
- **`191-deny-aur-helpers`** — `process.path` regexp `^/usr/bin/(yay|paru)$`.
  This repository's [package-source policy](conventions.md#package-sources)
  says nothing comes from the AUR; this is that policy stated where it cannot
  be forgotten. The blast radius is small on this machine: `pacman -Qm` lists
  only `brave-browser-local`, which this repository builds itself, `omarchy pkg
  add` shells out to `pacman` directly, and nothing under
  `/usr/share/omarchy/bin` mentions `yay`. `paru` is named although it is not
  installed — a deny for an absent binary costs nothing. For a deliberate
  exception, disable the rule for that session rather than deleting it.
- **`192-deny-vscode-network`** — `process.path` simple
  `/usr/share/code/code`, process-wide: no marketplace, no settings sync, no
  update check. It replaces a deny this machine re-created by hand from a
  prompt ten times. It matches the `code` binary and the children Chromium
  re-executes through `/proc/self/exe`, but **not** the separate Node
  processes VS Code spawns under `~/.config/Code/` — those still prompt on
  their own, and one of them (the Claude agent SDK) carries a version-pinned
  path, so settle it with a `regexp` rather than the literal path from the
  prompt.
- **`193-deny-bitwarden-breach-check`** — Bitwarden's data-breach check sends
  the leading five characters of a password's SHA-1 to Have I Been Pwned. The
  point of a self-hosted vault is that nothing about its contents leaves the
  network, and a k-anonymity prefix is still a query about a password you
  hold. It reuses `160`'s two-clause match verbatim, for the reason set out in
  [Why an Electron rule silently misses](#why-an-electron-rule-silently-misses)
  — `process.path` alone would be every Electron application installed:

  ```
  process.path     regexp  ^/usr/lib/electron[0-9]+/electron$
  process.command  regexp  (^|\s)/usr/lib/bitwarden/app\.asar(\s|$)|(^|\s)--user-data-dir=/home/matthew/\.config/Bitwarden(\s|$)
  dest.host        simple  api.pwnedpasswords.com
  dest.port        simple  443
  ```

  Narrowing a *deny* this way is worth a sentence, because the instinct is
  that a deny should be as broad as possible so it cannot be slipped past.
  That instinct is wrong here, and the reason is the default action: nothing
  allows Bitwarden to this host — `160` is scoped to the vault host, `170`
  requires Cursor's own `process.command` — so if this match ever stops
  fitting, the connection meets the daemon's `deny` default and prompts. A
  narrow deny that misses does not become an allow. What it does buy is that
  the rule denies the application named in it rather than every Electron app
  on the machine.

  `electron[0-9]+` rather than the literal `electron39` the prompt produced,
  so an Electron major bump does not change what this matches.

None is in `config/opensnitch/rules/`, because the shared baseline is
allow-only and `tests/test-setup-opensnitch.sh` enforces that. A shared deny
would ship to a machine whose local allows it had never seen. Back these up
with `export-opensnitch-rules --allow-machine-specific`, and rebuild them from
`opensnitch-rulectl apply` after a reinstall.

### Why an Electron rule silently misses

An Electron application does not open its own sockets. The process you launch
is the browser process; all networking is handed to a child utility process,
and that child is what OpenSnitch sees. On this machine Bitwarden's two
processes look like this:

```
main     /usr/lib/electron39/electron /usr/lib/bitwarden/app.asar
network  /proc/self/exe --type=utility --utility-sub-type=network.mojom.NetworkService \
         --user-data-dir=/home/matthew/.config/Bitwarden ...
```

Three things follow, and each one breaks an obvious-looking rule:

- **The app path is not on the connecting process.** `app.asar` appears only on
  the main process. A `process.command` rule that requires it matches the one
  process that barely touches the network and misses every TLS connection.
- **`argv[0]` is the literal string `/proc/self/exe`.** Chromium re-executes
  itself through `/proc/self/exe`, so a pattern anchored with
  `^/usr/lib/electron[0-9]+/electron ` cannot match the child either. The
  OpenSnitch GUI knows about this case — it refuses to trust `process.command`
  when `argv[0]` starts with `/proc` and silently adds a `process.path` clause.
- **`process.path` is the shared interpreter.** It resolves through
  `/proc/<pid>/exe` to `/usr/lib/electron39/electron` for the child as well as
  the parent, so on its own it would grant every Electron 39 application the
  same access.

What *is* both present on the connecting process and specific to the
application is `--user-data-dir`. So an Electron rule needs `process.path` to
pin the interpreter and a `process.command` alternation to pin the application:

```
process.path     regexp  ^/usr/lib/electron[0-9]+/electron$
process.command  regexp  (^|\s)/usr/lib/bitwarden/app\.asar(\s|$)|(^|\s)--user-data-dir=/home/matthew/\.config/Bitwarden(\s|$)
dest.host        simple  vaultwarden.internal.mdmiller.dev
dest.port        simple  443
```

The first alternative covers the main process, the second the network child.
The trailing `(\s|$)` is not decoration: without it `--user-data-dir=.../Cursor`
also matches a hypothetical `.../CursorEvil`.

Read that rule back and the capitals are gone — the daemon stores
`.../bitwarden`. That is not corruption. An operator with `sensitive: false`,
which is the default and what the GUI writes, is case-insensitive, and
OpenSnitch implements it by lowercasing the pattern when it loads the rule and
the value before matching. Verified here with a rule whose `process.command`
pattern was `MiXeDcAsEpRoBe`: it matched a command line carrying exactly that
mixed-case argument three times out of three, and a command line without it was
denied. So write the path with its real capitalisation for the next reader, and
do not be alarmed when it comes back lowercased. Set `sensitive: true` only if
you actually need case to be significant.

This is why the rule is machine-local rather than part of the portable
baseline — `--user-data-dir` contains a home path, which is exactly what
`export-opensnitch-rules` refuses to treat as portable.

Do not guess at any of this. `opensnitch-rulectl watch` prints the command line
the rule engine actually matches against, which is how the shape above was
established.

### Precedence is not optional for a curated allow

When two enabled rules match the same connection, a `deny` beats an `allow` of
equal precedence. Verified on this machine with two throwaway rules matching
the same `curl` connection: with both at `precedence: false` the connection was
denied twelve times out of twelve; setting `precedence: true` on the allow
flipped it to allowed ten times out of ten.

That turns the prompt timeout into a policy bug. A prompt nobody answers
applies the default action — deny — and saves it as a temporary rule. From
that moment a permanent, deliberate, non-precedence `allow` is dead until the
temporary rule expires, and nothing in the UI shows the allow as inactive. This
machine collected a `deny-12h-simple-usr-lib-electron39-electron` that way more
than once.

So every curated `allow` in `000`–`170` carries `precedence: true`. The rules
that deliberately do not are the denies in `190`–`193`: `190` must lose to
`030`/`031` and does, for the same reason, and `191`–`193` are left low so a
future curated allow can override them without an edit.

A `deny` you actually want still works — it just has to be the highest
precedence thing that matches, or the only thing that matches.

### Managing rules without root

`opensnitchd` runs as root and owns `/etc/opensnitchd/rules`, but it is the
gRPC *client* of the pair. The UI is the server: it listens on
`/run/user/<uid>/opensnitch/osui.sock`, and the daemon dials out to it and asks
what to do. Rules travel back down that connection. The UI never writes to
`/etc` — it sends a `CHANGE_RULE` or `DELETE_RULE` notification and the daemon
writes the root-owned file itself. That is why clicking "allow, always" in the
GUI has never asked for a password.

`bin/opensnitch-rulectl` borrows the same channel, so nothing in the rule
workflow needs `sudo`:

```bash
./bin/opensnitch-rulectl list                     # what the daemon has loaded
./bin/opensnitch-rulectl list --temporary         # only what a reboot will lose
./bin/opensnitch-rulectl show -o ~/rules-backup   # every rule as on-disk JSON
./bin/opensnitch-rulectl apply rule.json          # install or replace
./bin/opensnitch-rulectl delete <rule-name>       # remove
./bin/opensnitch-rulectl promote <rule-name> ...  # stage one as a curated rule
./bin/opensnitch-rulectl watch -s 60              # what the daemon decides, and why
```

`show` is also the answer to reading rules at all: the daemon writes GUI-created
rules `0600 root:root`, so `cat` cannot read them either. The daemon hands its
entire ruleset to whatever UI subscribes, which is where `list` and `show` get
their data.

Only one process can hold the socket, so the tool stops the GUI, serves the
socket itself, and starts the GUI again — roughly ninety seconds, most of it
waiting for the daemon's reconnect backoff. During that window:

- **Enforcement continues.** Rules are evaluated by the daemon, not the UI, so
  every permanent rule keeps working and the session keeps its network.
- **Prompts have nowhere to go.** A connection matching no rule is answered
  `deny` for that one connection and not saved, so the window cannot leave a
  permanent decision behind. `--allow-prompts` inverts the answer; it is still
  once-only. Either way `watch` reports what asked.
- **`--dry-run` does not take the socket at all**, because stopping the GUI is
  itself a change.

This adds no privilege. Anything that can run as your user can already bind
that socket when the GUI is not running and answer prompts however it likes —
that is inherent to OpenSnitch's design, and it is why the socket lives in a
`0700` directory under `/run/user/<uid>` rather than in `/tmp`. The tool makes
the existing trust boundary usable; it does not move it.

The one thing this cannot do is edit `/etc/opensnitchd/default-config.json`,
which is a genuine root file with no UI-side equivalent. `setup-opensnitch`
still uses `sudo` for that single write.

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

`opensnitch-rulectl show -o DIR` dumps every rule as JSON with no filtering and
no root, which is the right tool for a backup. `export-opensnitch-rules` is the
curated path: it selects rules, normalizes them, and refuses the ones that
cannot be portable. After using the UI to create an enabled rule with duration
`always`, export selected rules to a local directory outside this project:

```bash
./bin/export-opensnitch-rules
./bin/export-opensnitch-rules allow-firefox
./bin/export-opensnitch-rules browser-rule.json
./bin/export-opensnitch-rules --output-dir "$HOME/Documents/opensnitch-rules" allow-firefox
./bin/export-opensnitch-rules --dry-run allow-firefox
```

The bare command opens a rule multiselect followed by a local directory picker.
When rules are supplied as arguments, the directory picker still opens unless
`--output-dir` or `OPEN_SNITCH_EXPORT_DIR` is set. The directory of the last
successful export is recorded in
`~/.local/state/omarchy-scripts/opensnitch-export-dir` and offered first the
next time the picker opens, so a repeat export is one confirmation. `--yes`
takes it without asking; a run with no terminal and no `--yes` never inherits
it — an unattended run that names no destination still fails, rather than
writing to whichever directory was last picked by hand. Project directories are
rejected as export destinations. Arguments must match an internal rule name or
filename exactly. Exported JSON is normalized and gets a stable
`omarchy-shared-<slug>-<hash>.json` filename, so exporting it again is a no-op.

Rules containing a numeric UID, a home-directory path, a process hash, an
exact command line, an interface, or a private/link-local address are rejected
as non-portable. After reviewing the JSON, an intentional exception can be
exported with `--allow-machine-specific`.

Both `allow` and `deny` are exportable, because the shared baseline uses a
permanent deny as the explicit complement to a narrower allow — see
[Normalizing learned rules](#normalizing-learned-rules). Exporting a deny
warns: on its own it is only half a policy, so carry the allows it must lose to
across with it and check their `precedence` and numbering on the target
machine. Two rules that share a `name` also share an export filename; the
export refuses to write both and names them, rather than letting the second
replace the first.

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
./bin/opensnitch-rulectl list
./bin/opensnitch-rulectl list --temporary
sudo nft list ruleset | grep -i opensnitch
```

If an application is unexpectedly blocked, grant the narrowest temporary rule
first, and promote it to `always` — with `opensnitch-rulectl promote`, see
[Promoting a temporary rule](#promoting-a-temporary-rule) — only after the
application works and the match fields are understood. Find the match fields with

```bash
./bin/opensnitch-rulectl watch -s 60 -f bitwarden
```

rather than from the application's launcher or its `ps` output. What a rule
matches is the connecting process, which for anything Chromium-based is not the
process you started.

### A rule can be active and still be missing from the UI

The GUI's rule list is built when it connects to the daemon, and its database
is `file::memory:` by default. The daemon notices a file dropped into its rules
directory through inotify and reloads immediately — but it does not push that
change to a UI that is already connected. So every rule installed from outside
the GUI, which is every rule `setup-opensnitch` imports and every one migrated
by hand, is enforced at once and invisible until the UI reconnects.

The UI is therefore not the place to check whether a rule is live. These are:

```bash
./bin/opensnitch-rulectl list
grep -a 'Ruleset changed due to' /var/log/opensnitchd.log | tail
```

The first is authoritative: it asks the daemon for the ruleset it is actually
enforcing, rather than reading files the daemon may not have loaded. The second
says the daemon accepted a change. Neither needs root, and `ls
/etc/opensnitchd/rules/` is a poor substitute for either — it shows filenames,
and GUI-created rules are `0600 root:root` so their contents are unreadable
without `sudo`. The third check is the one that actually matters: exercise the
traffic and see it work.

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

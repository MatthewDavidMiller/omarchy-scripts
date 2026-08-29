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

## Small portable baseline

Files in `config/opensnitch/rules/` are imported before enforcement. The
committed baseline contains only:

- IPv4 and IPv6 localhost;
- `systemd-resolved` to DNS/DNS-over-TLS ports 53 and 853;
- `systemd-timesyncd` to UDP port 123.

These keep login-time local IPC, name resolution, and clock synchronization
working without granting general network access to a shell, interpreter,
browser, or download tool. The DNS rule follows OpenSnitch's recommendation to
let the resolver perform external DNS while applications use the local stub.
See the upstream [rules and best-practices guide](https://github.com/evilsocket/opensnitch/wiki/Rules).

Avoid permanent global rules for `curl`, `wget`, Python, Node, shells, or other
general-purpose interpreters. Constrain those by command line and destination
when a durable exception is genuinely needed. A dedicated browser executable
may reasonably receive a process-wide allow because maintaining every CDN and
site domain would defeat the purpose of a manageable policy.

## Sharing learned rules

After using the UI to create an enabled `allow` rule with duration `always`,
export selected rules into this repository:

```bash
./bin/export-opensnitch-rules
./bin/export-opensnitch-rules allow-firefox
./bin/export-opensnitch-rules browser-rule.json
./bin/export-opensnitch-rules --dry-run allow-firefox
```

The bare command opens a multiselect. Arguments must match an internal rule
name or filename exactly. Exported JSON is normalized and gets a stable
`omarchy-shared-<slug>-<hash>.json` filename, so exporting it again is a no-op.

Rules containing a numeric UID, a home-directory path, a process hash, an
exact command line, an interface, or a private/link-local address are rejected
as non-portable. After reviewing the JSON, an intentional exception can be
exported with `--allow-machine-specific`.

On the next setup run, shared rules are added or updated. A same-named local
rule is backed up and replaced to avoid duplicate evaluation. A deleted shared
file prunes the installed file with the `omarchy-shared-` prefix, also after a
backup. No GUI-created file outside that namespace is ever pruned.

Review and commit the exported JSON before using it on another machine:

```bash
git diff -- config/opensnitch/rules
./bin/setup-opensnitch
```

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

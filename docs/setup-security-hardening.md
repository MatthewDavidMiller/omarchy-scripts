# setup-security-hardening

Applies a conservative security baseline to an Omarchy workstation without
changing login convenience, desktop idle behavior, discovery, Bluetooth,
peripheral access, or boot configuration.

```bash
./bin/setup-security-hardening
./bin/setup-security-hardening --dry-run
```

It is also discovered automatically by `setup-all` and runs after the scripts
that remove Docker and LocalSend firewall rules.

## What it changes

### Omarchy package signatures

Older Omarchy installs carried a permissive override on their package
repository:

```ini
[omarchy]
SigLevel = Optional TrustAll
```

That validates a signature when one is present but does not reject an unsigned
package. Omarchy 4 now signs its packages and dropped that override in its own
migration, so a current install inherits the global `SigLevel = Required
DatabaseOptional` instead.

The script verifies the expected Omarchy fingerprint is present and fully
trusted, then states the requirement on the repository itself:

```ini
SigLevel = Required DatabaseOptional TrustedOnly
```

`TrustedOnly` is pacman's default, so on an up-to-date machine this is the
inherited policy written down where it applies: the repository keeps requiring
trusted signatures even if the global default is later loosened, and a machine
that never ran Omarchy's migration is repaired here. Repository database
signatures remain optional because the Omarchy database is not signed.
`LocalFileSigLevel` is left alone so the vetted Brave recipe in this repository
can still install its locally built package.

The old pacman configuration is backed up before the change. A missing,
different, or untrusted Omarchy signing key stops the script before it changes
anything.

`omarchy refresh pacman` replaces `/etc/pacman.conf` from a channel template.
This setup installs a `pre-refresh-pacman` hook that re-applies the `[omarchy]`
SigLevel line after that copy (`./bin/setup-security-hardening --siglevel-only`).

### Vulnerability monitoring

The script installs `arch-audit` from Arch's official Extra repository through
`omarchy pkg add`, enables the packaged `arch-audit.timer`, and runs an initial
non-fatal check. A temporary network or advisory-service failure is reported
but does not undo the rest of the baseline.

`arch-audit` covers packages represented in the Arch Security Team data. It
does not establish that Omarchy-specific or locally built packages are free of
vulnerabilities.

### Firewall

UFW is kept active with these defaults:

```text
deny incoming
allow outgoing
logging low
```

The script never deletes or rewrites explicit UFW rules. Services you chose to
expose therefore keep working, while traffic without an allow rule remains
blocked.

### Kernel and network settings

`/etc/sysctl.d/60-omarchy-security.conf` is copied from
`config/sysctl/60-omarchy-security.conf` and sets:

- `kernel.kptr_restrict=1`, hiding kernel pointers from unprivileged users
  while retaining privileged debugging.
- `kernel.dmesg_restrict=1`, keeping the ring buffer away from unprivileged
  readers.
- `kernel.yama.ptrace_scope=1`, so a process may only ptrace its own
  descendants — this is what stops one compromised desktop application from
  reading another's browser cookies, unlocked keyring, or agent keys.
- `kernel.perf_event_paranoid=2` and `kernel.unprivileged_bpf_disabled=2`, so
  neither the perf subsystem nor the BPF verifier is reachable without
  privilege. OpenSnitch's eBPF probe is loaded by `opensnitchd` as root and is
  unaffected.
- `dev.tty.ldisc_autoload=0`, so rarely-exercised TTY line disciplines are not
  autoloaded on demand from an unprivileged `TIOCSETD`.
- `kernel.kexec_load_disabled=1`, removing the boot-another-kernel-from-userspace
  path. This is one-way until the next reboot and it breaks `systemctl kexec`.
  It does **not** affect hibernation: `resume=` uses swsusp, not kexec.
- IPv4 accept, secure, and send redirects to `0`.
- IPv6 accept redirects to `0`.

The first four of those are already at these values on a current Arch kernel,
set by the kernel's own build configuration rather than by any file. They are
pinned so the machine's posture stops depending on a default upstream is free
to change, and so `sysctl` disagreeing becomes reportable drift rather than an
unrecorded choice.

It deliberately does not change unprivileged user namespaces, module loading,
SysRq, or routing behavior used by development and container tools. It also
leaves `fs.suid_dumpable` alone: `/usr/lib/sysctl.d/50-coredump.conf` sets it to
`2` on purpose so `systemd-coredump` can capture privileged crashes, and the
crash-diagnosis workflow depends on that. The resulting dump store is reported
instead.

#### The drop-in does not own every key it sets

`/etc/default/ufw` carries `IPT_SYSCTL=/etc/ufw/sysctl.conf`, and ufw applies
that file on every enable and reload — after `systemd-sysctl` has already run
at boot. For any key both files name, ufw is what the kernel ends up with:

```text
accept_redirects (v4 and v6, all and default)
rp_filter    accept_source_route
log_martians    icmp_echo_ignore_broadcasts
```

The values agree today, so nothing is being reverted. But a key ufw claims
cannot be governed from the drop-in, which is why `net.ipv4.conf.all.log_martians`
is documented as excluded rather than simply set.

Because agreeing today is not the same as agreeing after the next ufw update,
the script now reads every key in the drop-in back from the live kernel after
applying it, and warns on a mismatch — naming `/etc/ufw/sysctl.conf` when ufw
is the likely arbiter. A contested key is a posture finding, not a failed
install: the script still exits `0`, so `setup-all` does not report it as a
failed script.

### Credential-file permissions

Group and world permissions are removed from the home directory, `~/.ssh`, and
`~/.local/share/keyrings`. Existing owner permissions are preserved: a `0400`
private key stays `0400`, rather than being loosened to `0600`.

## Report-only findings

The final audit reports, but never changes:

- disk encryption and non-loopback listeners;
- SDDM autologin and Omarchy's stay-awake state;
- whether the default desktop keyring locks;
- `docker`, `empower`, and `input` group membership — Omarchy 4 no longer
  grants `input`, so membership that remains is reported with the command that
  drops it;
- Avahi and Bluetooth availability, and `cups-browsed` if it is still enabled
  after Omarchy 4 removed automatic printer discovery;
- `LocalFileSigLevel = Optional`, so it reads as the recorded decision it is
  (the vetted Brave recipe installs a locally built package) rather than an
  omission;
- the effective PAM lockout, which Omarchy loosens to ten failed attempts in
  `install/config/increase-lockout-limit.sh` and in its own
  `etc-overrides/security-faillock.conf`. Both files are Omarchy's, so
  re-tightening them here would be undone by the next update;
- the size of `/var/lib/systemd/coredump`, since `fs.suid_dumpable=2` means
  dumps of privileged processes land there and can hold whatever those
  processes had in memory;
- AppArmor, kernel lockdown, IOMMU, and Secure Boot status.

Two of those are worded to say how far away the missing control is:

- **Secure Boot.** On a machine with a TPM that already boots a measured UKI —
  which an Omarchy install with `ENABLE_UKI=yes` does — the report says so and
  names `sbctl` (Arch `extra`, so policy-compliant) as the enrolment path,
  rather than reporting a flat "not enabled".
- **Kernel command line.** `limine-entry-tool` reads
  `/etc/limine-entry-tool.d/*.conf` and appends each `KERNEL_CMDLINE[default]+=`
  to the command line. Omarchy writes its own named files there for hardware
  quirks (`install/hardware/intel/fred.sh`, `apple/fix-t2.sh`, `asus/*`) and its
  migrations only ever touch `omarchy-defaults.conf`, so a drop-in of another
  name survives an update. Nothing is installed there deliberately — AppArmor,
  kernel lockdown, and the allocator hardening flags are all boot-sensitive and
  outside this profile — but the report names the directory so the option stays
  visible.

The keyring check reads only the `[keyring]` metadata block. Stored credential
entries and secret values are never read or printed.

## Intentionally out of scope

This safe profile does not enable AppArmor, USBGuard, a hardened kernel, Secure
Boot, IOMMU boot parameters, kernel lockdown, service sandbox overrides, or
coredump restrictions. It also preserves autologin, disabled idle locking,
unlimited SSH-agent lifetime, Bluetooth, discovery services, and `input` group
membership. Group membership and service state are reported, never changed:
dropping the `input` group or a withdrawn discovery daemon is left to you.

Turning off CUPS and Avahi is a separate script — see
[setup-no-discovery-services.md](setup-no-discovery-services.md). It is not part
of this baseline because UFW's `deny incoming` already blocks inbound mDNS and
CUPS listens only on loopback, so it trades printing for defence in depth rather
than closing an open door. `setup-all` runs it; `--skip no-discovery-services`
holds it back on a machine that prints.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print changes without applying them or prompting for sudo |
| `-y`, `--yes` | Accepted for `setup-all` compatibility; there are no prompts |
| `--siglevel-only` | Re-apply the `[omarchy]` SigLevel line only (used by the pacman refresh hook) |
| `-h`, `--help` | Show usage |

## Verifying

```bash
grep -A2 '^\[omarchy\]' /etc/pacman.conf
systemctl status arch-audit.timer
sudo ufw status verbose
sysctl kernel.kptr_restrict kernel.dmesg_restrict kernel.yama.ptrace_scope \
       kernel.perf_event_paranoid kernel.unprivileged_bpf_disabled \
       dev.tty.ldisc_autoload kernel.kexec_load_disabled \
       net.ipv6.conf.all.accept_redirects
```

Re-running the script is the normal repair path if one of these settings
drifts. Every managed file is compared before it is written, so an unchanged
second run is a no-op.

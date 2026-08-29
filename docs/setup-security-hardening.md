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

Omarchy packages are signed by the key in `omarchy-keyring`, but Omarchy 4.0.1
ships its repository with this permissive policy:

```ini
[omarchy]
SigLevel = Optional TrustAll
```

That validates a signature when one is present but does not reject an unsigned
package. The script verifies the expected Omarchy fingerprint is present and
fully trusted, then changes only that repository to:

```ini
SigLevel = Required DatabaseOptional TrustedOnly
```

Package signatures therefore become mandatory and must come from a fully
trusted key. Repository database signatures remain optional because the
Omarchy database is not signed. `LocalFileSigLevel` is left alone so the vetted
Brave recipe in this repository can still install its locally built package.

The old pacman configuration is backed up before the change. A missing,
different, or untrusted Omarchy signing key stops the script before it changes
anything.

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

`/etc/sysctl.d/60-omarchy-security.conf` sets:

- `kernel.kptr_restrict=1`, hiding kernel pointers from unprivileged users
  while retaining privileged debugging.
- IPv4 accept, secure, and send redirects to `0`.
- IPv6 accept redirects to `0`.

It deliberately does not change ptrace, perf events, unprivileged user
namespaces, BPF, module loading, SysRq, or routing behavior used by development
and container tools.

### Credential-file permissions

Group and world permissions are removed from the home directory, `~/.ssh`, and
`~/.local/share/keyrings`. Existing owner permissions are preserved: a `0400`
private key stays `0400`, rather than being loosened to `0600`.

## Report-only findings

The final audit reports, but never changes:

- disk encryption and non-loopback listeners;
- SDDM autologin and Omarchy's stay-awake state;
- whether the default desktop keyring locks;
- `docker`, `empower`, and `input` group membership;
- Avahi, printer discovery, and Bluetooth availability;
- AppArmor, kernel lockdown, IOMMU, and Secure Boot status.

The keyring check reads only the `[keyring]` metadata block. Stored credential
entries and secret values are never read or printed.

## Intentionally out of scope

This safe profile does not enable AppArmor, USBGuard, a hardened kernel, Secure
Boot, IOMMU boot parameters, kernel lockdown, service sandbox overrides, or
coredump restrictions. It also preserves autologin, disabled idle locking,
unlimited SSH-agent lifetime, Bluetooth, discovery services, and `input` group
membership.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print changes without applying them or prompting for sudo |
| `-y`, `--yes` | Accepted for `setup-all` compatibility; there are no prompts |
| `-h`, `--help` | Show usage |

## Verifying

```bash
grep -A2 '^\[omarchy\]' /etc/pacman.conf
systemctl status arch-audit.timer
sudo ufw status verbose
sysctl kernel.kptr_restrict net.ipv6.conf.all.accept_redirects
```

Re-running the script is the normal repair path if one of these settings
drifts. Every managed file is compared before it is written, so an unchanged
second run is a no-op.

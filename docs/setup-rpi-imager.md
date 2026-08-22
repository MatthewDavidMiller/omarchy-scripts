# setup-rpi-imager

Installs Raspberry Pi Imager from Arch's signed official `extra` repository.

```bash
./bin/setup-rpi-imager           # install it
./bin/setup-rpi-imager --dry-run # preview without installing
./bin/setup-all --only rpi-imager
```

## Why the Arch package

Raspberry Pi offers an AppImage for Linux distributions without a native
package. Omarchy is Arch-based, and `rpi-imager` is already maintained in
Arch's official `extra` repository. The native package supplies its desktop
entry, icon, and polkit policy, and it updates through the normal Omarchy/Arch
system-update path. The script also installs `xorg-xhost`, which Raspberry Pi
Imager 2.x uses to authorize its polkit-elevated GUI on Omarchy's Xwayland
display.

This script deliberately does not use AUR, download release assets from
GitHub, or maintain a custom AppImage wrapper. Package signatures and checksums
are verified by pacman using the system's configured Arch keyring and policy.

## What it does

1. Checks for `rpi-imager` and `xorg-xhost` with `omarchy pkg present`.
2. Installs either missing package with `omarchy pkg add`.
3. Verifies that Omarchy reports both packages as installed.

Raspberry Pi Imager remains responsible for requesting elevation through its
packaged polkit policy. Omarchy's polkit agent displays that authentication
prompt. This setup does not add a `sudo` launcher, replace the desktop entry,
or grant passwordless device access. Once authenticated, Imager uses `xhost`
to let the elevated process reconnect to Xwayland; without it, Qt fails with
`Authorization required, but no authorization protocol specified`.

The explicit first check makes repeat runs a visible no-op instead of asking
pacman to reconsider an already-installed package.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print the install command without running it |
| `-y`, `--yes` | Accepted for `setup-all` compatibility |
| `-h`, `--help` | Show usage |

## Updates and removal

The package is not version-pinned; normal system updates keep it current. To
remove it later:

```bash
omarchy pkg drop rpi-imager
omarchy pkg drop xorg-xhost # optional if no other application needs it
```

The package lists `dosfstools` as optional for specialized SD-card bootloader
support. It is not installed explicitly by this script.

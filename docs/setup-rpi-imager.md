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
entry, icon, polkit policy, and dependencies, and it updates through the normal
Omarchy/Arch system-update path.

This script deliberately does not use AUR, download release assets from
GitHub, or maintain a custom AppImage wrapper. Package signatures and checksums
are verified by pacman using the system's configured Arch keyring and policy.

## What it does

1. Checks for the package with `omarchy pkg present rpi-imager`.
2. If missing, installs it with `omarchy pkg add rpi-imager`.
3. Verifies that Omarchy reports the package as installed.

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
```

The package lists `dosfstools` as optional for specialized SD-card bootloader
support. It is not installed explicitly by this script.

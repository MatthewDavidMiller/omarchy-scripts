# setup-ventoy

Builds a locally maintained Arch package from Ventoy's pinned first-party
Linux release and installs it with pacman. Ventoy turns a USB drive into a
multiboot disk: copy ISO files onto it and pick one at boot.

```bash
./bin/setup-ventoy           # build and install the pinned release
./bin/setup-ventoy --dry-run # preview, change nothing
./bin/setup-all --only ventoy
```

Then:

```bash
sudo ventoy -i /dev/sdX      # install Ventoy onto a drive (erases it)
sudo ventoy -u /dev/sdX      # update Ventoy on a drive, keeping the ISOs
ventoy-gui                   # GTK app; asks for your password through polkit
```

## Package trust model

Ventoy is not in the official Arch or Omarchy repositories. This setup never
invokes `yay`, `paru`, an AUR endpoint, or an AUR recipe. The complete recipe,
launcher and desktop entry live in `packages/ventoy/` and can be reviewed with
the rest of this repository.

Ventoy publishes SHA-256 sums with each release but no signatures, so there
is no upstream key to authenticate a "latest" lookup against. The recipe pins
the release version and the tarball's SHA-256 instead, and makepkg refuses to
package a download that does not match. New releases are picked up only when
the pin is bumped here.

That pin is as far as verification reaches. Ventoy's release ships prebuilt
binaries — GRUB and boot images, the exFAT tools, the GUI — that are not
reproducibly built from its published source, so installing it still trusts
upstream's build machine. The pin guarantees every machine gets the same bytes
that were reviewed when the pin was set, not that those bytes match the source.

## What gets installed

| Path | What |
| --- | --- |
| `/opt/ventoy` | The release, trimmed to x86_64, the CLI and the GTK3 GUI |
| `/usr/bin/ventoy` | Runs `Ventoy2Disk.sh`; refuses to run without root |
| `/usr/bin/ventoy-gui` | Runs `VentoyGUI.x86_64 --gtk3`, which elevates through pkexec |
| `/usr/share/applications/ventoy.desktop` | Launcher entry for the GUI |
| `/var/log/ventoy.log` | Log both front ends write (`/opt/ventoy/log.txt` links here) |

The web UI (`VentoyWeb.sh`) and the plugin configurator (`VentoyPlugson.sh`)
are left out, along with the local HTTP servers they start. So are the other
architectures' binaries and the GTK2/Qt5 GUI builds.

Ventoy expects to run from an unpacked, writable release directory. It
unpacks its tools on first run, swaps in a static `mkexfatfs` when the shared
one cannot run, and writes scratch files next to itself. To keep `/opt/ventoy`
exactly as pacman installed it:

- the recipe unpacks the tools at build time, and keeps only the glibc
  `mkexfatfs`;
- the `ventoy` CLI runs from a private root-owned directory under `/tmp`,
  made of symlinks into `/opt/ventoy` and removed afterwards.

`pacman -Qkk ventoy-local` should report no altered files after use.

## Updating

Run the setup script again after the pin is bumped; it builds only when the
installed version differs from the recipe's. To bump the pin:

1. Set `pkgver` (and reset `pkgrel=1`) in `packages/ventoy/PKGBUILD`.
2. Take the new `ventoy-<version>-linux.tar.gz` SHA-256 and confirm it matches
   in all three places upstream publishes it: the release notes, the
   release's `sha256.txt`, and GitHub's asset digest
   (`gh api repos/ventoy/Ventoy/releases/latest --jq '.assets[].digest'`).
3. Put it in `sha256sums`, rerun `tests/run`, and commit.

Editing `ventoy-launcher` or `ventoy.desktop` also means updating their
`sha256sums` entries; the test suite fails until they match.

## Supported architecture

x86_64 only. Upstream ships aarch64 binaries as well; packaging them would
need its own review.

## Removal

```bash
omarchy pkg drop ventoy-local
```

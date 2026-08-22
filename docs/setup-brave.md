# setup-brave

Builds a locally maintained Arch package from Brave's latest first-party stable
RPM, applies Omarchy's browser integration, and makes Brave the default.

```bash
./bin/setup-brave           # build, install, integrate, and select Brave
./bin/setup-brave --dry-run # verify release metadata and preview system changes
./bin/setup-all --only brave
```

## Package trust model

This setup never invokes `yay`, `paru`, an AUR endpoint, an AUR recipe, or
Omarchy's AUR-backed Brave installer. The complete package recipe and launcher
live in `packages/brave/` and can be reviewed with the rest of this repository.

The resolver follows Brave's official public-stable version endpoint. It then
downloads the matching checksum, detached signature, and Brave checksum key.
The key file's SHA-256 and allowed signing fingerprints are pinned in this
repository. Only after the signature validates does it render a PKGBUILD with
the authenticated version and RPM digest. Makepkg verifies that digest again
after downloading the RPM.

The vendor RPM is repackaged rather than installed directly so pacman owns and
can cleanly remove every installed file. Its RPM auto-update cron job is omitted:
updates are discovered and authenticated on each setup run instead.

## Omarchy integration

After package installation, the script:

1. Installs Omarchy's Chromium flags for native Wayland, filtered through
   `setup-no-chromium-extensions` so Copy URL, Download Video, and WhatsApp Slim
   remain disabled.
2. Creates Brave's managed-policy directory and applies the current theme.
3. Selects Brave through `omarchy default browser brave`, which updates XDG URL
   handlers.

It deliberately does not install the Copy URL or video-download native
messaging integrations. This keeps standalone Brave setup consistent with the
repository's Chromium-extension removal script.

Each state is checked independently, making the script safe to rerun or use to
repair a partial setup.

## Supported architecture

The reviewed recipe currently supports x86_64 only. Supporting aarch64 requires
a separately pinned first-party artifact and checksum.

## Updating

Run the setup script again. It compares the installed package with Brave's
current public stable version and builds only when the versions differ.
If Brave rotates its checksum signing key, the pinned key digest and signer list
must be reviewed and updated in `packages/brave/prepare-latest`.

## Removal

Select another browser before removing the local package:

```bash
omarchy default browser chromium
omarchy pkg drop brave-browser-local
```

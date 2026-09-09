# setup-cat-background

Renders a full-color pixel-art cat wallpaper on a neutral-gray background and
uses the same corrected cat for Omarchy's Plymouth disk-encryption prompt.

```bash
./bin/setup-cat-background              # render it and make it current
./bin/setup-cat-background --dry-run    # preview without writing anything
./bin/setup-cat-background --no-activate
./bin/setup-all --only cat-background
```

## Why

Every stock theme ships `backgrounds/omarchy.png`, a 3840x2160 pixel-art
wallpaper. This produces the same kind of crisp wallpaper with a cat in place
of the wordmark. Its colors come from the reference photo rather than the
active theme, so the black cat remains black on both dark and light themes.

The output goes to `~/.config/omarchy/backgrounds/<theme>/pixel-cat.png`, the
per-theme user background directory that `omarchy theme bg install` creates and
that `omarchy theme bg next` merges into the wallpaper cycle. Nothing under
`/usr/share/omarchy` is touched, and the stock `omarchy.png` stays available
alongside the cat. It appears in the background switcher as "Pixel Cat".

## The art

`assets/cat-wallpaper.png` is the approved full-color source artwork. The cat's
chin is black while its white chest bib begins below it. It was
generated from two cat photographs: the first supplied the curled body pose,
and the second supplied the coherent front-facing identity, facial proportions,
eyes, ears, markings, and whiskers. The generated source is 1672x941 RGB pixel
art with the cat centered against a neutral-gray background.

The PNG is committed and is the only artwork consumed at runtime. The script
does not reconstruct or recolor the cat, so the approved face, pose, shading,
and markings remain intact across themes.

## What it does

1. Installs `imagemagick` with `omarchy pkg add` if it is not already present.
2. Reads the active theme from `~/.local/state/omarchy/current/theme.name` to
   select its per-theme user background directory.
3. Scales `assets/cat-wallpaper.png` into the requested desktop canvas and an
   `800x450` transparent Plymouth image with ImageMagick's `point` filter,
   preserving hard pixel edges and the full RGB palette. The transparent cutout
   blends into Plymouth's flat neutral-gray background without a rectangular
   edge. Non-16:9 desktop sizes receive neutral-gray padding rather than
   distortion. The unlock image lives under `~/.config/omarchy/plymouth/`, so it
   does not appear in the desktop background switcher.
4. Compares the result with the existing wallpaper and rewrites it only if the
   bytes differ, backing the old one up first.
5. Sets it as the current background with `omarchy theme bg set`, then bounces
   Omarchy Shell through a private cache alias and back to the stable path. This
   defeats the shell's same-path guard and image cache so changed pixels reload
   immediately.
6. Applies the smaller image to the early-boot disk-encryption prompt with
   `omarchy plymouth set`, which rebuilds the initramfs using Omarchy's supported
   Plymouth workflow. It skips that rebuild when the installed image is already
   current. `--no-activate` skips both activation steps.
7. Installs a `theme-set` hook and a `post-update` hook, so neither a theme
   switch nor an Omarchy update leaves the cat behind.

Rendering is deterministic: `-strip` and excluded PNG date chunks mean the same
source and canvas size produce the same bytes. That makes step 4 a real
idempotence check rather than a timestamp comparison.

## Options

| Flag | Effect |
| --- | --- |
| `--size WxH` | Canvas size, default `3840x2160` |
| `--no-activate` | Render both images without applying either one |
| `--plymouth-only` | Re-apply just the Plymouth unlock image; what the `post-update` hook runs |
| `--force` | Re-render even when the existing wallpaper matches |
| `-n`, `--dry-run` | Print what would happen, change nothing |
| `-y`, `--yes` | Accepted for `setup-all` compatibility |
| `-h`, `--help` | Show usage |

## Surviving an update

The wallpaper lives under `~/.config` and an update never touches it. The
Plymouth image does not: `omarchy plymouth set` publishes into
`/usr/share/plymouth/themes/omarchy/`, and `pacman -Qo` puts that directory in
`omarchy-settings`. Every upgrade of that package restores the packaged logo,
and the `90-mkinitcpio-install.hook` that runs later in the same transaction —
usually because the kernel was upgraded too — bakes the stock logo into
`/boot/EFI/Linux/omarchy_linux.efi`. That is why the cat used to disappear from
the boot splash after an update.

So the setup installs a `post-update` hook that runs
`setup-cat-background --plymouth-only`. `omarchy update` runs `post-update`
hooks after packages and migrations and before it offers a reboot, so the UKI is
rebuilt with the cat in it before the machine next boots.

`--plymouth-only` renders and installs just the `800x450` unlock image, compares
it against `/usr/share/plymouth/themes/omarchy/logo.png`, and calls
`omarchy plymouth set` only when the two differ — one `limine-mkinitcpio` run,
and only when it is actually needed. It leaves the wallpaper, the live shell
background, and the switcher thumbnail cache alone, because an update does not
disturb any of them.

## Switching themes

The wallpaper is stored per-theme so it participates in each theme's background
cycle, but the same full-color artwork is used everywhere. The setup installs a
`theme-set` hook that re-runs this script in full after `omarchy theme set`, so
changing theme does not require a manual re-run.

## Removal

```bash
rm ~/.config/omarchy/backgrounds/<theme>/pixel-cat.png
omarchy theme bg next    # move off it if it was current
```

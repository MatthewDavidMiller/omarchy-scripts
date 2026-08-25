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

Rendering is deterministic: `-strip` and excluded PNG date chunks mean the same
source and canvas size produce the same bytes. That makes step 4 a real
idempotence check rather than a timestamp comparison.

## Options

| Flag | Effect |
| --- | --- |
| `--size WxH` | Canvas size, default `3840x2160` |
| `--no-activate` | Render both images without applying either one |
| `--force` | Re-render even when the existing wallpaper matches |
| `-n`, `--dry-run` | Print what would happen, change nothing |
| `-y`, `--yes` | Accepted for `setup-all` compatibility |
| `-h`, `--help` | Show usage |

## Switching themes

The wallpaper is stored per-theme so it participates in each theme's background
cycle, but the same full-color artwork is used everywhere. After changing the
theme with `omarchy theme set <name>`, re-run the script to install it there.

## Removal

```bash
rm ~/.config/omarchy/backgrounds/<theme>/pixel-cat.png
omarchy theme bg next    # move off it if it was current
```

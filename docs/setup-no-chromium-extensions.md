# Remove Omarchy's Chromium extensions

`setup-no-chromium-extensions` disables the three unpacked extensions Omarchy
loads into Chromium-family browsers: Copy URL, Download Video, and WhatsApp
Slim.

It edits existing `~/.config/*-flags.conf` files and removes only those three
paths from `--load-extension`. Other extensions and flags remain intact. Changed
files receive a timestamped backup. The extension names live in
`config/chromium/omarchy-extensions`. A `post-update` hook re-runs the strip
after `omarchy update`, so migrations that append `--load-extension=` do not
bring the bundled extensions back.

Close affected browsers first, then run:

```bash
./bin/setup-no-chromium-extensions
```

Use `--dry-run` to preview or `--yes` to skip confirmation. The script covers
Chromium, Chrome, Brave variants, and Microsoft Edge Stable. Re-running it is
safe and reports that the extensions are already disabled.

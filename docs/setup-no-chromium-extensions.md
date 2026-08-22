# Remove Omarchy's Chromium extensions

`setup-no-chromium-extensions` disables the three unpacked extensions Omarchy
loads into Chromium-family browsers: Copy URL, Download Video, and WhatsApp
Slim.

It edits existing `~/.config/*-flags.conf` files and removes only those three
paths from `--load-extension`. Any user-added unpacked extensions and all other
flags remain intact. Changed files receive a timestamped backup.

Close affected browsers first, then run:

```bash
./bin/setup-no-chromium-extensions
```

Use `--dry-run` to preview or `--yes` to skip confirmation. The script covers
Chromium, Chrome, Brave variants, and Microsoft Edge Stable. Re-running it is
safe and reports that the extensions are already disabled.

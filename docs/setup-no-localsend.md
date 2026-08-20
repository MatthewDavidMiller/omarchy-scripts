# setup-no-localsend

Deletes the firewall rules omarchy adds for LocalSend, and uninstalls the app
they were opened for.

```bash
./bin/setup-no-localsend                    # close the port, remove the app
./bin/setup-no-localsend --dry-run          # preview, change nothing
./bin/setup-no-localsend --keep-package     # close the port only
./bin/setup-no-localsend --allow-localsend  # put the stock setup back
```

## The problem

Omarchy's installer opens LocalSend's port to the whole network
(`install/config/firewall.sh`):

```bash
# Allow ports for LocalSend.
ufw allow 53317/udp
ufw allow 53317/tcp
```

ufw expands each of those into an IPv4 and an IPv6 rule, so it is four rules in
total. On a stock install they are the only inbound holes apart from the pair
that lets docker containers reach the host's DNS resolver:

```
To                         Action      From
--                         ------      ----
53317/udp                  ALLOW       Anywhere
53317/tcp                  ALLOW       Anywhere
53317/udp (v6)             ALLOW       Anywhere (v6)
53317/tcp (v6)             ALLOW       Anywhere (v6)
```

`Anywhere` means anywhere — not just the LAN. If you never use LocalSend, that
is an inbound allowance for a service you do not run, and the app sits in the
tray advertising itself over mDNS on top of it.

## What it does

1. **Deletes the two rules** — `ufw delete allow 53317/udp` and
   `ufw delete allow 53317/tcp`. One delete covers both address families, and
   the docker DNS rules are matched on port 53, so they are untouched.
2. **Uninstalls the package** — `pacman -Rs localsend`, which also collects the
   dependencies nothing else still needs (`libayatana-appindicator` and its
   tray stack, on a stock install). The exact list is printed before the
   confirmation, so nothing is removed unseen. `--keep-package` skips this.
3. **Uninstalls a flatpak LocalSend** if one is present. Omarchy's nautilus
   "Send via LocalSend" action falls back to `org.localsend.localsend_app`, so
   a machine can have the app without the pacman package.

Both `sudo` steps are single commands; the script itself refuses to run as
root. Reading the current rules does *not* need sudo — `/etc/ufw/user.rules` is
world-readable on a stock install, so `--dry-run` and the no-op second run
never trigger a password prompt. If that file is unreadable it falls back to
`sudo ufw show added`.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print actions, change nothing |
| `-y`, `--yes` | Skip confirmation prompts |
| `--keep-package` | Close the firewall only; leave LocalSend installed |
| `--allow-localsend` | Reverse — re-add both rules and reinstall the package |
| `-h`, `--help` | Usage |

| Variable | Effect |
| --- | --- |
| `UFW_RULES_DIR` | Where `user.rules` lives. Default `/etc/ufw`; the tests point it at a fixture |

## What it does not touch

Omarchy owns these and they live under `/usr/share/omarchy`, so the script
leaves them alone rather than editing files a `omarchy update` will rewrite:

- The menu's **Share → Receive** entry (`omarchy-menu.jsonc`), which runs
  `uwsm-app -- localsend`.
- The nautilus **Send via LocalSend** action
  (`nautilus-python/extensions/localsend.py`).
- The Hyprland float rule for LocalSend's window (`hypr/apps/localsend.lua`).

With the app gone, all three simply do nothing. `omarchy share clipboard` also
stops working for the same reason.

Nothing re-adds the firewall rules on update: they are written once by the
installer, and no migration touches port 53317. LocalSend is an explicitly
installed package with no reverse dependencies, so `omarchy update` will not
pull it back in either.

## Verifying

```bash
sudo ufw status                # no 53317 lines
grep 53317 /etc/ufw/user.rules # no output; same for user6.rules
pacman -Qq localsend           # "error: package not found"
```

## Undo

```bash
./bin/setup-no-localsend --allow-localsend
```

That re-adds both rules and reinstalls the repo package. It does not reinstall
a flatpak — omarchy ships the pacman package, so that is what comes back.

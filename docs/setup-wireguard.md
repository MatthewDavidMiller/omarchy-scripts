# setup-wireguard

Installs the WireGuard client, imports a tunnel config into NetworkManager, and
adds a bar widget that switches the tunnel on and off with one click.

```bash
./bin/setup-wireguard                      # asks for the .conf path
./bin/setup-wireguard --config ~/wg0.conf  # no prompt
./bin/setup-wireguard --dry-run            # preview without changing anything
./bin/setup-all --only wireguard
```

## Why NetworkManager, not wg-quick

Omarchy already runs NetworkManager with systemd-resolved, and NetworkManager
supports WireGuard natively. An imported tunnel pushes its `DNS =` servers into
resolved, appears in `nmcli` beside every other connection, and can be brought
up or down by the logged-in user without a password: NetworkManager's polkit
policy allows `network-control` for the active session.

`wg-quick` would need `systemd-resolvconf` for the `DNS =` line and a root
`wg-quick@<name>.service` per tunnel, and toggling it from the bar would need
sudo every time.

`wireguard-tools` comes from Arch's signed `extra` repository through
`omarchy pkg add`. NetworkManager does not need it to run the tunnel; it is
installed for `wg show`, which is the quickest way to see handshakes and
transfer counters.

## What it does

1. Installs `wireguard-tools` if `omarchy pkg present` says it is missing.
2. Imports the tunnel:
   - from `--config PATH`, or
   - from a path it asks for, but only when no WireGuard connection exists
     yet and stdin is a terminal. A blank answer skips the import. Re-runs
     under `setup-all` therefore never ask again.

   The file must contain `[Interface]` and `PrivateKey`, and its name becomes
   the connection and interface name, so it must be a valid interface name of
   at most 15 characters: `wg0.conf` becomes `wg0`. The import runs
   `sudo nmcli connection import`, then turns autoconnect off and takes the
   tunnel down if NetworkManager brought it straight up. A connection with the
   same name is left alone.
3. Copies the `omarchy-scripts.wireguard` shell plugin from
   `config/omarchy/plugins/` to `~/.config/omarchy/plugins/`, rescans plugins
   when the files changed, and enables the widget on the right of the bar if
   it is not already enabled. When an already-enabled widget's files changed,
   it restarts the shell with `omarchy-restart-shell`: the shell's live plugin
   reload keeps running the copy it compiled earlier, so an update would
   otherwise not show. If the restart fails (it refuses while the session is
   locked), it warns and you can run `omarchy-restart-shell` yourself. If
   `omarchy-shell` is not running — over SSH, say — it warns and leaves the
   widget step for a re-run from the desktop.

The private key is copied into
`/etc/NetworkManager/system-connections/<name>.nmconnection`, which is root
only. The script warns that the original `.conf` still holds the key; it never
deletes the file itself.

## The bar widget

A padlock that is lit when the tunnel is up and dimmed when it is down. Click
it to toggle; the tooltip names the connection. It polls
`nmcli connection show` every five seconds, so a tunnel changed elsewhere
catches up quickly. A failed `up` or `down` raises a notification with
nmcli's error.

With several WireGuard connections it shows whichever is active, or else the
first one. To pin a specific one, set the widget's `connection` setting in the
bar settings, or in its entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "omarchy-scripts.wireguard", "connection": "wg0" }
```

The widget hides itself when NetworkManager has no WireGuard connection.

### Details on right-click

NetworkManager reports a WireGuard connection as activated as soon as the
interface exists, whether or not the peer ever answers, so a lit padlock does
not prove the tunnel works. Right-click the widget for a popup that does:

- **Status.** A WireGuard interface only counts received bytes for packets
  that authenticated, so any received traffic means a handshake completed
  ("Connected"). If nothing arrives within 15 seconds of opening the popup, it
  says "No reply from peer". The usual causes are a wrong endpoint, a wrong
  key, or a firewall dropping the UDP port. `wg show` would give the exact
  handshake time, but it needs root.
- **Endpoint, address, DNS** from the NetworkManager profile, and the received
  and sent byte counters with the time of the last packet from the peer.
- **Turn on/off**, the same as a left click.
- **Test** sends one uncached DNS query through the tunnel
  (`resolvectl query --cache=no -i <device>`). WireGuard has to handshake to
  carry it, and the popup reports "Peer answered" if received bytes grow within
  six seconds. It uses DNS rather than ping because ICMP is often blocked
  behind a tunnel. It needs the profile to have a DNS server.

These checks run only while the popup is open: the counters every two seconds,
nothing in the background. With the popup closed, the widget does only the
five-second on/off poll.

From a terminal, the same switch is:

```bash
nmcli connection up wg0
nmcli connection down wg0
```

## Options

| Flag | Effect |
| --- | --- |
| `-c`, `--config PATH` | Import this WireGuard client config |
| `-n`, `--dry-run` | Print what would change without changing anything |
| `-y`, `--yes` | Accepted for `setup-all` compatibility |
| `-h`, `--help` | Show usage |

## Omarchy update safety

The package updates with the system. The connection lives in
`/etc/NetworkManager/system-connections/`, which no Omarchy package owns. The
widget lives in the user-owned `~/.config/omarchy/plugins/`, which updates do
not touch. `omarchy refresh shell` can reset the bar layout in `shell.json` and
drop the widget from it; re-run this script to put it back. No hook is needed.

## Full tunnels and `rp_filter`

`setup-security-hardening` keeps UFW, which sets strict reverse-path filtering
(`rp_filter = 1`). NetworkManager routes a full tunnel (`AllowedIPs =
0.0.0.0/0`) with policy routing instead of replacing the main default route.
If a full tunnel connects (`wg show` reports a recent handshake) but no
traffic flows, check strict reverse-path filtering first, and do not loosen
it globally to get things working.

## Removal

```bash
nmcli connection delete wg0
omarchy plugin disable omarchy-scripts.wireguard
rm -r ~/.config/omarchy/plugins/omarchy-scripts.wireguard
omarchy pkg drop wireguard-tools
```

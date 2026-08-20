# setup-ssh-agent

Makes `ssh-agent` persistent across the whole login session, so a key
passphrase is typed once per login instead of once per terminal.

```bash
./bin/setup-ssh-agent            # configure and load keys
./bin/setup-ssh-agent --dry-run  # preview, change nothing
```

## The problem

Starting an agent from a shell rc file (`eval "$(ssh-agent)"`) gives every
terminal its own agent and its own passphrase prompt, and leaves orphaned
agent processes behind at exit. Programs launched from the Hyprland session
rather than from a shell — editors, GUI git clients — get no agent at all.

## What it does

1. **Stands down competing agents.** `gcr-ssh-agent` (GNOME Keyring) and
   `gpg-agent`'s SSH socket both want to own `SSH_AUTH_SOCK`. Enabled ones are
   disabled; static-but-running ones are masked. Each is confirmed first.
2. **Exports `SSH_AUTH_SOCK` session-wide** by writing
   `~/.config/environment.d/10-ssh-agent.conf`:
   ```
   SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/ssh-agent.socket
   ```
   `systemd --user` reads this at login, so Hyprland and everything it spawns
   inherit it — not just shells.
3. **Enables `ssh-agent.socket`**, the socket-activated user unit shipped with
   OpenSSH. The agent starts on first connection to the socket and lives until
   logout. Nothing to clean up.
4. **Appends to `~/.ssh/config`** (backing up the old file first):
   ```
   Host *
       AddKeysToAgent yes
   ```
   The first `ssh` that uses a key hands it to the agent; later connections
   reuse it.
5. **Runs `ssh-add`** for every private key it finds in `~/.ssh`, skipping keys
   the agent already holds (compared by fingerprint, not filename).

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print actions, change nothing |
| `-y`, `--yes` | Skip confirmation prompts |
| `--no-add-keys` | Configure the agent, skip `ssh-add` |
| `--lifetime T` | Expire loaded keys after `T` (e.g. `8h`). Default: until logout |
| `-h`, `--help` | Usage |

## After running

The `environment.d` file only takes effect at the next login. Log out and back
in, then check:

```bash
systemctl --user status ssh-agent.socket
echo $SSH_AUTH_SOCK      # /run/user/1000/ssh-agent.socket
ssh-add -l               # your keys
ssh -T git@github.com
```

## Notes and gotchas

- **`IdentitiesOnly` is deliberately not set.** Under `Host *` it would
  restrict ssh to default `id_*` filenames, so keys named anything else
  (`github_key_2026`) would stop being offered.
- **Per-host keys** still belong in `~/.ssh/config` above the managed block —
  `Host *` is a fallback, and for each keyword ssh takes the first value it
  sees:
  ```
  Host github.com
      IdentityFile ~/.ssh/github_key_2026
      IdentitiesOnly yes
  ```
- **GNOME Keyring** is disabled for SSH only. It keeps handling other secrets.
- **Timed unlock:** `--lifetime 8h` re-locks keys after a workday, at the cost
  of a passphrase prompt when they expire.
- **A stray agent blocks the unit.** `ssh-agent.socket` and `ssh-agent.service`
  both carry `ConditionEnvironment=!SSH_AGENT_PID`, so they silently refuse to
  start if something leaked `SSH_AGENT_PID` into the systemd user environment.
  The script detects this and offers to clear it. A shell that already has an
  old `SSH_AUTH_SOCK` keeps using the old agent until you log out — the script
  warns when it sees that.
- **Re-running is safe.** Already-configured steps report `skip`.

## Undo

```bash
systemctl --user disable --now ssh-agent.socket
rm ~/.config/environment.d/10-ssh-agent.conf
# remove the marked block from ~/.ssh/config, or restore a .bak.* copy
```

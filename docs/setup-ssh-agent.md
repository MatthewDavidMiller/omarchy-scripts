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
4. **Writes a managed block in `~/.ssh/config`** (backing up any existing file
   first), naming every private key it found:
   ```
   Host *
       AddKeysToAgent yes
       IdentityFile ~/.ssh/github_key_2026
       IdentityFile ~/.ssh/homelab_key_2023
   ```
   The `IdentityFile` lines are load-bearing. On its own `ssh` only ever tries
   the six default `id_*` filenames, so a key called `github_key_2026` is never
   offered, `AddKeysToAgent` never fires for it, and the agent stays empty after
   every login. With the key named, the first `ssh` that uses it prompts once,
   hands it to the agent, and later connections reuse it.

   The block is regenerated on every run, so a key added to `~/.ssh` later is
   picked up the next time you run the script. Anything above the block is left
   alone.
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
ssh-add -l               # empty until the first ssh, then your keys
ssh -T git@github.com    # prompts once, then the key is in the agent
```

## Notes and gotchas

- **Every listed key is offered to every host.** `Host *` is a fallback, so a
  server you connect to sees the public half of each key before one of them
  authenticates. With a handful of keys that is fine; past six or so you can
  hit the server's `MaxAuthTries` and get refused before the right key is
  reached. Give those hosts their own block (below).
- **`IdentitiesOnly` is deliberately not set.** Under `Host *` it would confine
  every host to exactly this key list, overriding per-host `IdentityFile`
  entries that ssh should still be free to use.
- **Per-host keys** still belong in `~/.ssh/config` above the managed block —
  for each keyword ssh takes the first value it sees, so an entry above wins:
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
- **Re-running is safe.** Unchanged steps report `skip`; the `~/.ssh/config`
  block is rewritten only when the key list actually changed, and the old file
  is backed up (at mode 600) when it is.
- **Keys do not survive a reboot.** The agent lives for the login session. What
  makes that painless is step 4: after a reboot the first `ssh` re-adds the key
  with one passphrase prompt, and every later connection that session is free.

## Undo

```bash
systemctl --user disable --now ssh-agent.socket
rm ~/.config/environment.d/10-ssh-agent.conf
# remove the marked block from ~/.ssh/config, or restore a .bak.* copy
```

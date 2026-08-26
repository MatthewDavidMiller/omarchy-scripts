# setup-rootless-podman

Makes rootless Podman the container engine and removes Docker, along with the
firewall rules omarchy opened for it.

```bash
./bin/setup-rootless-podman                       # swap engines
./bin/setup-rootless-podman --dry-run             # preview, change nothing
./bin/setup-rootless-podman --keep-docker         # add podman, keep docker
./bin/setup-rootless-podman --keep-firewall-rules # leave the ufw rules alone
./bin/setup-all --only rootless-podman
```

## The problem

Omarchy installs Docker and enables `docker.socket`
(`install/config/all.sh`, `install/config/enable-services.sh`). The daemon runs
as root and owns a root-owned socket, which leaves two ways to use it and no
good one. Omarchy's own install notes lay out the trade-off
(`install/config/docker.sh`):

```
# The Docker daemon runs as root and its socket is root-owned, so membership in
# the docker group is equivalent to passwordless root: any process in it can
# `docker run -v /:/host` and rewrite the host as root. We therefore do NOT add
# the install user to the docker group by default...
```

So omarchy picks the safe half: no group membership, and every Docker call goes
through `sudo` or a polkit prompt instead. That is the right call given a
root-owned daemon — it is just paying for a daemon that does not have to be
root in the first place.

Rootless Podman removes the choice. There is no daemon: `podman run` forks the
container from your own shell, inside a user namespace where you are root and
every other uid comes out of a subordinate range that only you own. A container
escape lands on an unprivileged uid with no path back to the host's root, so
nothing needs elevating and nothing needs a group that is root by another name.

## What it does

1. **Installs `podman` and `crun`** with `omarchy pkg add`, from Arch's signed
   `extra` repository. crun is podman's own documented default runtime
   (`runtime = "crun"` in `containers.conf`) and it also keeps an `oci-runtime`
   provider on the system once docker's `runc` is no longer being held in place
   by containerd.
2. **Grants a subuid/subgid range** with `usermod --add-subuids/--add-subgids`,
   if the account has none. This is the one step that needs root. The range
   starts above every range already handed out in `/etc/subuid`, so a second
   account cannot be given overlapping host uids — an overlap is a silent
   cross-user id collision, not an error anything reports. If a rootless store
   already exists it is moved onto the new mapping with `podman system migrate`.
3. **Enables `podman.socket`** as a user unit. Podman itself needs no socket;
   anything speaking the Docker API over one does. It is socket-activated, so
   nothing runs until something connects.
4. **Writes `~/.config/environment.d/20-podman.conf`** — see below.
5. **Stops and removes Docker**: `docker.socket`, `docker.service` and
   `containerd.service` are disabled first, then `omarchy pkg drop` removes
   `docker`, `docker-buildx` and `ufw-docker` (plus `containerd`, which nothing
   else needs). The full list `pacman -Rs` would take is printed before the
   confirmation, so nothing goes unseen.
6. **Deletes the docker DNS firewall rules** — see below.
7. **Installs `podman-docker`**, which provides `/usr/bin/docker`. This has to
   come last: the package `Conflicts With docker`, so pacman will not accept it
   until the real Docker is gone.
8. **Verifies** that podman reports itself rootless, and reports the runtime and
   storage driver it settled on.

Both `sudo` steps are single commands; the script itself refuses to run as root.

## Keeping the Docker interface

The point is to change the engine, not to make you relearn the commands. Three
things carry the old interface over:

| Set to | Reads it |
| --- | --- |
| `/usr/bin/docker` (podman-docker) | omarchy's `d` alias, muscle memory, scripts |
| `DOCKER_HOST` | lazydocker, `docker compose`, testcontainers, anything else speaking the Docker API |
| `OMARCHY_DOCKER_SOCKET` | omarchy's `omarchy-sudo-docker` |

The environment file is:

```
DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock
OMARCHY_DOCKER_SOCKET=${XDG_RUNTIME_DIR}/podman/podman.sock
```

`OMARCHY_DOCKER_SOCKET` is the interesting one. `omarchy-launch-docker-tui`
(Super + Shift + D) asks `omarchy-sudo-docker` whether it needs to elevate, and
that answers by testing whether the socket is writable:

```bash
DOCKER_SOCKET="${OMARCHY_DOCKER_SOCKET:-/var/run/docker.sock}"
[[ -w $DOCKER_SOCKET ]] && exit 1   # no sudo needed
```

Pointing it at the user's podman socket makes that answer "no elevation
needed", so the TUI runs `lazydocker` directly against podman instead of
`pkexec`-ing to a daemon that no longer exists. It is a documented environment
variable, so nothing under `/usr/share/omarchy` is edited and `omarchy update`
cannot undo it.

## Two packages that deliberately stay

- **`docker-compose`** is a standalone Go binary with no dependency on the
  daemon — it drives the Docker API, which podman's socket serves. Podman's own
  `compose` command looks for exactly this binary first
  (`compose_providers` defaults to `["docker-compose", "podman-compose"]`), so
  `docker compose up` keeps working through the shim. Replacing it with the
  Python `podman-compose` would be a downgrade, not a migration.
- **`lazydocker`** is likewise just an API client, so it follows `DOCKER_HOST`.

`docker-buildx` does not stay: it drives BuildKit inside the daemon, which
podman has no equivalent for. `podman build` (buildah) is the replacement.

## The firewall rules

Omarchy opens the host resolver to the docker bridge
(`install/config/firewall.sh`):

```bash
ufw allow in proto udp from 172.16.0.0/12 to 172.17.0.1 port 53 comment 'allow-docker-dns'
ufw allow in proto udp from 192.168.0.0/16 to 172.17.0.1 port 53 comment 'allow-docker-dns'
```

`172.17.0.1` is `docker0`'s gateway address. Rootless podman never creates it:
containers reach DNS through `pasta` inside the user's own network namespace,
so nothing on the host has to be opened at all. With Docker gone the address
does not exist and both rules are inbound allowances for nothing, so the script
deletes them. `--keep-firewall-rules` leaves them.

Reading the current rules does not need sudo — `/etc/ufw/user.rules` is
world-readable on a stock install, so `--dry-run` and the no-op second run
never trigger a password prompt. A rule that will not delete is a warning, not
a failure: the packages are already gone by then.

The `# BEGIN UFW AND DOCKER` block in `/etc/ufw/after.rules` is left alone. It
declares its own `DOCKER-USER` chain (`:DOCKER-USER - [0:0]`), so it is
self-contained and inert without Docker, and editing ufw's after.rules to
remove something that does nothing is the riskier of the two options.

## What is not carried over

Images, containers and volumes. Podman keeps its own store under
`~/.local/share/containers`, and nothing converts one to the other — pull or
rebuild what you still need.

`/var/lib/docker` also survives the uninstall: the daemon created it at
runtime, so pacman never owned it and does not remove it. The script reports it
rather than deleting it, because that is the one part of this migration that
cannot be undone:

```bash
sudo du -sh /var/lib/docker   # see what is in there first
sudo rm -rf /var/lib/docker
```

The `docker` group is left behind too. It is empty on a stock omarchy — that is
the whole point of omarchy's install note — and an empty group grants nothing.

## Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print actions, change nothing |
| `-y`, `--yes` | Skip confirmation prompts |
| `--keep-docker` | Set up Podman only; leave Docker installed and running |
| `--keep-firewall-rules` | Leave the `allow-docker-dns` ufw rules in place |
| `-h`, `--help` | Usage |

| Variable | Effect |
| --- | --- |
| `SUBUID_FILE`, `SUBGID_FILE` | Where the subordinate ranges live. Default `/etc/subuid`, `/etc/subgid`; the tests point them at fixtures |
| `UFW_RULES_DIR` | Where `user.rules` lives. Default `/etc/ufw` |
| `DOCKER_DATA_DIR` | The daemon's data directory to report. Default `/var/lib/docker` |

With `--keep-docker`, `DOCKER_HOST` still points at podman — that is what makes
podman the session's engine. Reach the Docker daemon explicitly with
`DOCKER_HOST=unix:///var/run/docker.sock docker ps`.

## Verifying

```bash
podman info --format '{{.Host.Security.Rootless}}'   # true
podman unshare cat /proc/self/uid_map                # your uid, then the subuid range
systemctl --user status podman.socket
echo $DOCKER_HOST                                    # .../podman/podman.sock
docker run --rm docker.io/library/alpine echo ok     # through the shim
sudo ufw status | grep 172.17.0.1                    # no output
```

`DOCKER_HOST` reaches a process only after the systemd user manager has read
`environment.d`, so log out and back in — or run
`systemctl --user import-environment` — after the first run.

## Undo

There is no `--restore-docker`. Putting it back is three commands, and the part
that matters is the data, which no flag can bring back:

```bash
omarchy pkg drop podman-docker
omarchy pkg add docker docker-buildx ufw-docker
sudo systemctl enable --now docker.socket
rm ~/.config/environment.d/20-podman.conf
```

If `/var/lib/docker` was not deleted, the old images and containers are still
in it and come back with the daemon.

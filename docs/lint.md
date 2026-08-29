# lint

Runs shellcheck over the repo's shell scripts, inside a throwaway container.

```bash
./bin/lint              # lint everything, including tests/
./bin/lint bin/setup-ssh-agent   # lint specific files
./bin/lint --fmt        # also check formatting with shfmt
```

Runs automatically on commit — see [ci.md](ci.md).

## Why a container

The only dependency is a container engine. Nothing gets installed on the host,
and every machine lints identically — a script that passes here passes
everywhere, and a linter release cannot quietly change what does or does not
commit.

Rootless Podman is preferred over Docker, and is what
[setup-rootless-podman](setup-rootless-podman.md) leaves on the machine. Either
engine works; `OMARCHY_CONTAINER_ENGINE=docker` pins one explicitly. The
Dockerfile format is engine-neutral — podman builds it unchanged — so the file
keeps its name.

## What gets linted

`bin/*`, `lib/*.sh`, `githooks/*`, `tests/run`, and `tests/*.sh`, minus
`.bak.*` copies — and minus anything whose shebang is not a shell. `bin/` holds
commands rather than shell scripts specifically, and shellcheck refuses a
language it cannot parse with `SC1071 (error)`, which fails the run rather than
skipping the file. So discovery reads the first line and passes on the rest.
A Python command in `bin/` is therefore unlinted, not broken; give it its own
checks if it grows enough to need them.

## The image

Built locally from [`docker/lint.Dockerfile`](../docker/lint.Dockerfile):

```dockerfile
FROM alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
RUN apk add --no-cache shellcheck shfmt
```

**Supply chain.** `alpine` is a Docker Official Image — maintained by Docker
and the Alpine team, and among the most scrutinised images that exist. It is
pinned **by digest, not tag**, because a tag can be repointed at new content
while a digest cannot: the bytes that built this image are the bytes that will
build it again. shellcheck and shfmt come from Alpine's signed package
repositories. No third-party image sits anywhere in the chain, and both tools
live in one image rather than two separately-trusted ones.

**Size and speed.** 41 MB total (13.8 MB Alpine + shellcheck + shfmt), built in
about 5 seconds, once. After that the tag is cached and a full lint of the repo
takes ~1.3 s, of which ~0.5 s is container startup — the same startup cost as
any prebuilt image, so nothing is lost by building our own.

**Rebuilds.** The tag is the Dockerfile's own SHA-256 prefix
(`omarchy-scripts/lint:0c02b4ebe533`), so editing the file rebuilds on the next
run with no version constant to bump, and the superseded image is pruned
automatically. `--rebuild` forces it. `OMARCHY_LINT_IMAGE=<ref>` uses a
prebuilt image instead and never builds over it.

**Runtime isolation.** Containers run with `--network none`, as your own uid,
with the repo mounted read-only — a linter reads code, so it gets no more than
that. The build context is `docker/` alone, so the repo is never sent to the
daemon. `--fix` is the one exception: shfmt needs the mount writable.

**"As your own uid" is spelled differently per engine.** Under Docker the
daemon is root, so `--user 1000:1000` simply drops to that uid and the bind
mount is seen with the host's own ids. Under rootless Podman the container
already runs as you, inside a user namespace where you are uid 0 and every
other uid is drawn from your subuid range — so `--user 1000` there means
*subuid* 1000, which is host uid 100999, a stranger to your own files:

```
$ podman run --user 1000:1000 -v "$PWD:/mnt" … shfmt --write lib/probe.sh
open lib/.probe.sh579088012144235543: permission denied
```

`--userns=keep-id` maps your host uid to itself inside the namespace, which
makes `--user` mean what it says and keeps written files owned by you. It is
rootless-only — rootful podman rejects it — so `bin/lint` adds it only after
asking the engine `podman info --format '{{.Host.Security.Rootless}}'` rather
than guessing from the engine's name.

To refresh the base image, follow the instructions in the Dockerfile header.

## Fallbacks

1. `podman`, then `docker` — but only if it actually answers. An installed
   client with a dead daemon is skipped rather than left to fail slowly.
   Podman goes first because it needs neither a daemon nor root, so on a
   machine with both it is the one that will answer.
2. A host-installed `shellcheck`, with a warning that versions may differ.
3. Neither: exit 3, meaning "no linter available" rather than "lint failed".

`--container` demands a container and fails otherwise; `--no-container` uses
host tools only. `OMARCHY_CONTAINER_ENGINE` pins a single engine — naming one
means that one, so a pinned engine that does not answer is an error rather than
a silent swap to the other.

## Options

| Flag | Effect |
| --- | --- |
| `--fmt` | Also check formatting with shfmt |
| `--fix` | Reformat in place with shfmt (implies `--fmt`) |
| `--rebuild` | Rebuild the image even if cached |
| `--no-container` | Use host tools instead of containers |
| `--container` | Require containers; fail rather than fall back |
| `-h`, `--help` | Usage |

| Variable | Effect |
| --- | --- |
| `OMARCHY_CONTAINER_ENGINE` | Use exactly this engine instead of trying podman then docker |
| `OMARCHY_LINT_IMAGE` | Use a prebuilt image; never build over it |

Exit codes: `0` clean, `1` problems found, `3` no linter available.

## On shfmt

shfmt is available but **not enforced**, and not run by the commit hook. Its
canonical style expands the aligned one-line `case` arms this repo uses for
argument parsing:

```bash
    -n|--dry-run)  DRY_RUN=1 ;;      # what we write
    -n | --dry-run)                  # what shfmt wants
      DRY_RUN=1
      ;;
```

That is a taste call, not a defect, so it stays opt-in. Run `./bin/lint --fix`
if you would rather adopt shfmt's formatting across the repo — then it is
worth adding `--fmt` to the commit hook so it stays that way.

## Suppressing a finding

Only when the finding is genuinely wrong, with a comment saying why:

```bash
# Written verbatim into environment.d; systemd expands it, not us.
# shellcheck disable=SC2016
AGENT_SOCK='${XDG_RUNTIME_DIR}/ssh-agent.socket'
```

Repo-wide settings live in `.shellcheckrc`, which turns on `external-sources`
and sets `source-path=SCRIPTDIR` so `source "$SCRIPT_DIR/../lib/common.sh"` is
followed and analysed rather than skipped.

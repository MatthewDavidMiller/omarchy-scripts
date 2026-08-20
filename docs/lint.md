# lint

Runs shellcheck over the repo's shell scripts, inside a throwaway container.

```bash
./bin/lint              # lint everything, including tests/
./bin/lint bin/setup-ssh-agent   # lint specific files
./bin/lint --fmt        # also check formatting with shfmt
```

Runs automatically on commit — see [ci.md](ci.md).

## Why a container

The only dependency is the container engine omarchy already ships. Nothing gets
installed on the host, and every machine lints identically — a script that
passes here passes everywhere, and a linter release cannot quietly change what
does or does not commit.

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
(`omarchy-scripts/lint:8a6f97fd1f84`), so editing the file rebuilds on the next
run with no version constant to bump, and the superseded image is pruned
automatically. `--rebuild` forces it. `OMARCHY_LINT_IMAGE=<ref>` uses a
prebuilt image instead and never builds over it.

**Runtime isolation.** Containers run with `--network none`, as your own uid,
with the repo mounted read-only — a linter reads code, so it gets no more than
that. The build context is `docker/` alone, so the repo is never sent to the
daemon. `--fix` is the one exception: shfmt needs the mount writable.

To refresh the base image, follow the instructions in the Dockerfile header.

## Fallbacks

1. `docker`, then `podman` — but only if the daemon actually answers. An
   installed client with a dead daemon is skipped rather than left to fail
   slowly.
2. A host-installed `shellcheck`, with a warning that versions may differ.
3. Neither: exit 3, meaning "no linter available" rather than "lint failed".

`--container` demands a container and fails otherwise; `--no-container` uses
host tools only.

## Options

| Flag | Effect |
| --- | --- |
| `--fmt` | Also check formatting with shfmt |
| `--fix` | Reformat in place with shfmt (implies `--fmt`) |
| `--rebuild` | Rebuild the image even if cached |
| `--no-container` | Use host tools instead of containers |
| `--container` | Require containers; fail rather than fall back |
| `-h`, `--help` | Usage |

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

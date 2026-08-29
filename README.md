# omarchy-scripts

Setup scripts for my [Omarchy](https://omarchy.org) installs — the things I
re-do on every fresh machine, kept in one place so they run the same way twice.

## Layout

```
bin/          Executable scripts, one per task
lib/          Shared bash helpers (logging, dry-run, safe file writes, TUI)
packages/     Vetted local package recipes built from first-party releases
config/       Portable configuration imported by setup scripts
assets/       Committed artwork used by scripts
tests/        Test suite, plain bash, no framework
docker/       Dockerfile for the containerised lint toolchain
githooks/     Local git hooks — the entire CI/CD pipeline
docs/         One page per script, plus conventions
```

## Usage

```bash
git clone https://github.com/matthewdavidmiller/omarchy-scripts.git
cd omarchy-scripts
./bin/setup-all
```

That is the whole thing — one command, safe to re-run whenever config drifts.
Run bare in a terminal it opens a menu (run everything, pick a subset, toggle
dry-run); pass any flag and it runs non-interactively instead.

```bash
./bin/setup-all --no-tui        # run everything, no menu
./bin/setup-all --list          # what would run, in order
./bin/setup-all --dry-run       # preview, change nothing
./bin/setup-all --only ssh-agent
./bin/install-hooks             # only needed if you plan to commit
```

Every script supports `--help`, and `--dry-run` to preview changes without
touching the system.

## Scripts

| Script | What it does | Docs |
| --- | --- | --- |
| `bin/setup-all` | Menu + runner for every script below, in order | [docs/setup-all.md](docs/setup-all.md) |
| `bin/setup-ssh-agent` | Persistent socket-activated ssh-agent, unlocked once per login | [docs/setup-ssh-agent.md](docs/setup-ssh-agent.md) |
| `bin/setup-no-idle` | Stop the screensaver and idle auto-lock from firing | [docs/setup-no-idle.md](docs/setup-no-idle.md) |
| `bin/setup-brave` | Build vetted Brave package and make it the default browser | [docs/setup-brave.md](docs/setup-brave.md) |
| `bin/setup-rpi-imager` | Install Raspberry Pi Imager from Arch Extra | [docs/setup-rpi-imager.md](docs/setup-rpi-imager.md) |
| `bin/setup-cat-background` | Set a pixel-art cat desktop and disk-unlock background | [docs/setup-cat-background.md](docs/setup-cat-background.md) |
| `bin/setup-no-chromium-extensions` | Remove Omarchy's bundled Chromium extensions | [docs/setup-no-chromium-extensions.md](docs/setup-no-chromium-extensions.md) |
| `bin/setup-no-background-network` | Stop optional polling and application telemetry | [docs/setup-no-background-network.md](docs/setup-no-background-network.md) |
| `bin/setup-no-localsend` | Remove LocalSend and the ufw rules that expose it | [docs/setup-no-localsend.md](docs/setup-no-localsend.md) |
| `bin/setup-rootless-podman` | Swap Docker for rootless Podman, keeping the docker CLI | [docs/setup-rootless-podman.md](docs/setup-rootless-podman.md) |
| `bin/setup-security-hardening` | Enforce a safe package, firewall, kernel, and credential-file baseline | [docs/setup-security-hardening.md](docs/setup-security-hardening.md) |
| `bin/setup-opensnitch` | Opt-in deny-by-default outbound application firewall | [docs/setup-opensnitch.md](docs/setup-opensnitch.md) |
| `bin/export-opensnitch-rules` | Export reviewed permanent allows for reuse across machines | [docs/setup-opensnitch.md](docs/setup-opensnitch.md) |
| `bin/lint` | shellcheck in a container — no host tooling to install | [docs/lint.md](docs/lint.md) |

Container images follow two rules: **reputable sources only** — Docker Official
Images, pinned by digest — and **small**, so a lint run costs seconds rather
than minutes. The engine that runs them is Podman or Docker, whichever answers.

Scripts are discovered automatically — a new `bin/setup-*` joins `setup-all`
just by existing. Scripts marked `# default: no`, such as OpenSnitch, run only
when explicitly selected with `setup-all --only NAME`.

## Development

```bash
./bin/install-hooks   # once per clone — installs the CI/CD pipeline
./bin/lint            # shellcheck, in a container
./tests/run           # run the complete test suite
```

**CI/CD runs on commit and nowhere else.** `git commit` gates on syntax → lint
→ tests → permissions, about 5 seconds. Nothing runs on push, so pushes stay
instant — a commit cannot exist without having passed already. There is no
hosted CI by design. See [docs/ci.md](docs/ci.md).

Linting runs in a throwaway container built on `alpine` — a Docker Official
Image, pinned by digest — with shellcheck and shfmt from Alpine's signed
repositories. No third-party images, nothing installed on the host, and the
same versions on every machine. Rootless Podman is preferred over Docker and
either works; `bin/setup-rootless-podman` is what leaves the machine with the
former.

Tests are plain bash against a throwaway `HOME` with stubbed system commands,
so they never touch your real config. See [docs/testing.md](docs/testing.md).

## Conventions

See [docs/conventions.md](docs/conventions.md) for the rules new scripts follow
(idempotence, dry-run, backups before edits), and
[docs/testing.md](docs/testing.md) for how to test one.

## License

MIT — see [LICENSE](LICENSE).

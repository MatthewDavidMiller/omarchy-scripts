# Conventions

Rules every script in `bin/` follows. They exist so a script can be re-run on a
half-configured machine without fear.

## Shape

- Named `bin/setup-<thing>` — that prefix is what `setup-all` discovers.
- `#!/usr/bin/env bash` and `set -euo pipefail`.
- Source `lib/common.sh` for logging, `run`, and `write_file`.
- Executable, no `.sh` extension — these are commands, not libraries.
- One script per task. If two tasks are useful separately, they are two scripts.
- A header block declaring its slot in the run:

  ```bash
  #!/usr/bin/env bash
  #
  # setup-foo — one-line summary.
  #
  # order: 20
  # description: Shown by setup-all --list
  ```

  A disruptive or specialized setup may declare `# default: no`. It remains
  runnable directly and through `setup-all --only <name>`, but is omitted from
  ordinary run-everything discovery.

  `order` defaults to 50. See [setup-all.md](setup-all.md) for the ranges.
  Keep `description` short and comma-free — it is a menu label, and `setup-all`
  rewrites commas to `·` so they cannot corrupt gum's selection list.

## Behaviour

- **Idempotent.** This is the load-bearing rule: `setup-all` is meant to be run
  on an already-configured machine, so a second run must change nothing and say
  so (`skip ...`). In practice that means checking before acting — is the unit
  already enabled, is the marker block already in the file, does the key already
  match — rather than blindly re-applying. `write_file` handles the common case.
- **`--dry-run`.** Prints every action it would take, changes nothing. Wrap
  side effects in `run` so this is free.
- **`--help`.** Usage text listing every flag.
- **Backs up before editing.** `write_file` copies the old file to
  `<file>.bak.<timestamp>` first.
- **Never runs as root.** Call `require_not_root`. Use `sudo` for the single
  command that needs it, never for the whole script.
- **Confirms destructive steps.** Use `confirm`, which `--yes` bypasses.
- **Accepts `-n`/`--dry-run` and `-y`/`--yes`.** `setup-all` passes both through
  to every script, so a script that rejects them breaks the whole run.
- **Exits non-zero on failure**, so `setup-all` can report it. Exit 0 when the
  work was already done — that is a skip, not a failure.

## Two ways `set -euo pipefail` bites

Both of these have shipped in this repository and both failed the same way: the
script aborted partway through, with no error message and a confusing exit code,
on the path where nothing had gone wrong.

- **A function whose last command is a test.** `stop_existing_ui` ended with
  `pgrep ... && die "the UI did not stop"`. When the UI *had* stopped, `pgrep`
  returned 1, that became the function's return value, and `set -e` killed the
  script — after it had already terminated the user's UI. Use an explicit `if`
  for the failure branch, or end the function with something that returns 0.
  A predicate function that is only ever called inside `if` is fine; an action
  function is not.
- **A pipeline whose reader exits early.** `pacman -Si <pkg> | awk '... exit'`
  looks harmless, but `awk` closes the pipe as soon as it has what it needs, and
  a still-writing `pacman` takes SIGPIPE. `pipefail` promotes that to exit 141
  for the whole script. It is a race, so it fails intermittently and looks like
  a flaky test rather than a bug. Let the reader consume all of its input —
  track "already found it" with a flag instead of `exit`.

When a test that exercises one of these passes reliably, check that the fixture
is actually big enough to lose the race. `tests/test-setup-opensnitch.sh` pads
its `pacman` stub past the pipe buffer on purpose.

## Helpers in `lib/common.sh`

| Helper | Purpose |
| --- | --- |
| `log`, `ok`, `skip`, `warn`, `die` | Consistent, colourised output |
| `run cmd...` | Execute, or echo under `DRY_RUN=1` |
| `have cmd` | Is a command on `$PATH`? |
| `require_cmd cmd...` | Die unless all commands exist |
| `require_not_root` | Refuse to run as root |
| `confirm "prompt"` | Ask, unless `ASSUME_YES=1` |
| `write_file path <<<content` | Idempotent write with backup |

`lib/tui.sh` adds the menu layer used by `setup-all` — `tui_menu`,
`tui_multiselect`, `tui_confirm`, `tui_title`, `tui_banner`. Each prefers `gum`
and falls back to plain bash prompts, so gum is never a hard dependency.
Individual scripts do not need it; they just print.

## Testing

Every script gets tests in `tests/`. A new `bin/setup-*` should at minimum pin
down that it is idempotent — a second run changes nothing — because that is the
property everything else depends on and the easiest one to break later. See
[testing.md](testing.md).

## CI/CD

`bin/install-hooks` points `core.hooksPath` at `githooks/`. On commit the hook:

1. Runs `bash -n` over staged scripts — no dependencies, always available.
2. Runs `bin/lint`, which shellchecks them inside a pinned container.
3. Runs `tests/run`, the whole suite.
4. Refuses commits that drop the executable bit on anything in `bin/`.

Nothing runs on push. See [ci.md](ci.md) for why, and for how the hook degrades
rather than blocks when docker is not running.

`bin/lint` needs no host tooling: it uses the docker omarchy already ships. If
neither a container engine nor a host `shellcheck` is available it exits 3 and
the hook lets the commit through with a warning, rather than blocking work on a
stopped daemon.

## Container images

Two rules, applied to anything this repo runs in a container:

- **Reputable sources only.** Prefer a Docker Official Image as the base and
  install tools from the distro's signed repositories, over pulling a
  third-party prebuilt image — even the tool author's. Fewer parties to trust,
  and the ones that remain are the most scrutinised.
- **Pin by digest, not tag.** A tag can be repointed at new content; a digest
  cannot.
- **Small and cached.** Lint runs happen on every commit, so image size and
  startup are a tax on the edit loop. Build once, tag by the Dockerfile's hash,
  prune what it supersedes.
- **Engine-neutral.** Podman and Docker both have to work, and podman is tried
  first — it needs neither a daemon nor root. Where they genuinely differ, ask
  the engine rather than branching on its name: rootless podman needs
  `--userns=keep-id` for `--user` to mean the caller's uid, and rootful podman
  rejects that flag, so the name alone does not answer it. See
  [lint.md](lint.md).

## Package sources

AUR packages and helpers are not allowed. Prefer official Arch or Omarchy
repository packages installed with `omarchy pkg add`.

When no approved repository package exists, a recipe maintained in this
repository may repackage a first-party upstream release. The recipe must be
complete and reviewable here, avoid importing an AUR recipe, and install through
pacman so every system file remains tracked. Pin the version and checksum, or
authenticate dynamic release metadata with a pinned upstream signing key and
verify the resolved artifact checksum.

There is no hosted CI by design — everything runs locally. See
[lint.md](lint.md) for the images, fallbacks, and how to suppress a finding.

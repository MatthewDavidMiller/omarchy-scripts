# Stop optional background network traffic

`setup-no-background-network` disables optional features that otherwise poll
the network without a direct user action:

```bash
./bin/setup-no-background-network --dry-run
./bin/setup-no-background-network
```

It makes four targeted changes:

- disables the `omarchy.weather` and `omarchy.agents` shell plugins through
  `omarchy plugin disable`, stopping their weather and subscription-usage
  timers without editing Omarchy's packaged plugin code;
- disables VS Code telemetry, experiments, update and extension checks,
  recommendations, natural-language settings search, and Settings Sync;
- writes `telemetry=false` to Raspberry Pi Imager's user settings;
- backs up and removes the four reviewed process-wide OpenSnitch denies for
  `curl`, Python, Raspberry Pi Imager, and VS Code.

The OpenSnitch cleanup is intentionally exact. It does not delete arbitrary
deny rules, and it does not touch any allow rule. The daemon's global default
remains `deny`, so a new unmatched connection is still blocked or prompted.

## Why remove the broad denies?

The `curl` and Python rules were caused by Omarchy's built-in weather and AI
usage widgets. Blocking either executable globally also blocks unrelated
commands and scripts. Disabling the widgets at their supported configuration
boundary stops the connection attempts without turning general-purpose tools
into permanently offline programs.

The Raspberry Pi Imager and VS Code rules had the same problem: a process-wide
deny also blocks intentional catalog downloads, extensions, and AI workflows.
Their unwanted telemetry and background services have first-party settings,
so the setup switches those off instead.

## Files and recovery

User files are backed up as `<path>.bak.<timestamp>` before they change. Each
removed OpenSnitch rule is copied beside itself with the same backup suffix.
The script also records a successful `code --sync off` call at:

```text
~/.local/state/omarchy-scripts/vscode-sync-disabled
```

To reverse an individual choice, restore the relevant backup or re-enable the
feature explicitly:

```bash
omarchy plugin enable omarchy.weather
omarchy plugin enable omarchy.agents
code --sync on
```

Re-enabling a feature may require a new narrow OpenSnitch allow. Do not restore
the old process-wide deny rules merely to suppress a prompt.

## OpenSnitch rule migration safety

Agent HTTPS allows are migrated separately from this setup. A replacement
Codex allow must be installed and observed in the daemon's live reload before
the old exact-version allow is removed. OpenSnitch should not be restarted
during that transition. If verification is uncertain, retain both allows;
the duplicate is safer than interrupting the active agent session.


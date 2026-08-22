# Repository instructions

## Package sources

- Never install or depend on packages from the Arch User Repository (AUR).
- Do not use `yay`, `paru`, `omarchy pkg aur add`, `omarchy-pkg-aur-add`, or
  higher-level Omarchy installers that delegate to an AUR helper.
- Install system packages only from the configured official Arch or Omarchy
  repositories, using `omarchy pkg add`.
- Before adding an installer, verify its package is available through
  `omarchy pkg add`/the configured pacman repositories. If it is unavailable,
  stop and report that no policy-compliant package source exists; do not add a
  third-party repository or an alternative package format without explicit
  approval.

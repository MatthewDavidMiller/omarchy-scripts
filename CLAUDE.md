# Repository instructions

## Package sources

- Never install or depend on packages from the Arch User Repository (AUR).
- Do not use `yay`, `paru`, `omarchy pkg aur add`, `omarchy-pkg-aur-add`, or
  higher-level Omarchy installers that delegate to an AUR helper.
- Prefer system packages from the configured official Arch or Omarchy
  repositories, installed with `omarchy pkg add`.
- A repository-owned package recipe is allowed when it is built directly from
  a first-party upstream release and fully reviewable here. Pin the version and
  checksum, or authenticate dynamic stable-release metadata with a pinned
  upstream signing key and verify the resolved artifact checksum. Do not import
  an AUR recipe as its basis.
- Before adding an installer, verify its package is available through
  `omarchy pkg add`/the configured pacman repositories. If it is unavailable,
  use a repository-owned recipe only when the first-party release can be
  packaged and vetted under the rule above; otherwise stop and report that no
  policy-compliant source exists.

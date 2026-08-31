#!/usr/bin/env bash
# bin/setup-security-hardening — against a throwaway HOME and stubbed package,
# firewall, systemd, sysctl, firmware, and network commands. No real system
# configuration or service is read or changed.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STUBS="$TEST_TMP/stubs"

# sudo executes only the fixture-safe command that follows it. Dry-run status
# checks use sudo -n, which this strips before dispatching to the ufw stub.
# shellcheck disable=SC2016
stub_bin "$STUBS" sudo '
[[ ${1:-} == "-n" ]] && shift
exec "$@"'

# shellcheck disable=SC2016
stub_bin "$STUBS" pacman-key '
fingerprint="${OMARCHY_KEY_FINGERPRINT:-40DFB630FF42BCFFB047046CF0134EE680CAC571}"
case "${FAKE_KEY_STATE:-trusted}" in
  missing) exit 1 ;;
  wrong) fingerprint=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ;;
  untrusted) trust=unknown ;;
  *) trust=full ;;
esac
printf "pub   ed25519 2025-08-28 [SC]\n"
printf "      %s %s %s %s %s  %s %s %s %s %s\n" \
  "${fingerprint:0:4}" "${fingerprint:4:4}" "${fingerprint:8:4}" \
  "${fingerprint:12:4}" "${fingerprint:16:4}" "${fingerprint:20:4}" \
  "${fingerprint:24:4}" "${fingerprint:28:4}" "${fingerprint:32:4}" \
  "${fingerprint:36:4}"
printf "uid           [  %s  ] Omarchy <pkgs@omarchy.org>\n" "${trust:-full}"'

# shellcheck disable=SC2016
stub_bin "$STUBS" omarchy '
db="${FAKE_PKG_DB:?}"
case "$1 $2" in
  "pkg present") [[ -f "$db/$3" ]] ;;
  "pkg add")     : > "$db/$3" ;;
  *) echo "unexpected omarchy call: $*" >&2; exit 1 ;;
esac'

# shellcheck disable=SC2016
# shellcheck disable=SC2016
stub_bin "$STUBS" pacman '
REPO_VALUE="${FAKE_ARCH_REPO:-extra}"
PKG_NAME=arch-audit
# Real `pacman -Si` prints Repository first, then ~20 more fields. The large
# tail here is deliberate: a reader that exits at the Repository line leaves
# this writer blocked on a full pipe, and under `set -o pipefail` that SIGPIPE
# becomes exit 141 for the whole script. Without the padding the race is won
# often enough that the bug only shows up as an occasional flake.
printf "Repository      : %s\nName            : %s\n" "$REPO_VALUE" "$PKG_NAME"
printf "Description     : "
head -c 200000 /dev/zero | tr "\0" "x"
printf "\n"'

# shellcheck disable=SC2016
stub_bin "$STUBS" systemctl '
state="${FAKE_UNIT_STATE:?}"
case "$*" in
  "cat arch-audit.timer") exit 0 ;;
  "is-enabled --quiet arch-audit.timer") [[ -f "$state/arch-audit.timer" ]] ;;
  "enable --now arch-audit.timer") : > "$state/arch-audit.timer" ;;
  "is-enabled --quiet avahi-daemon.service"|\
  "is-enabled --quiet cups-browsed.service"|\
  "is-enabled --quiet bluetooth.service") exit 0 ;;
  "is-active --quiet "*) exit 1 ;;
  *) exit 1 ;;
esac'

# shellcheck disable=SC2016
stub_bin "$STUBS" ufw '
state="${FAKE_UFW_STATE:?}"
rules="${FAKE_UFW_RULES:?}"
. "$state"
write_state() {
  printf "active=%q\nincoming=%q\noutgoing=%q\nlogging=%q\n" \
    "$active" "$incoming" "$outgoing" "$logging" > "$state"
}
case "$*" in
  "status verbose")
    printf "Status: %s\n" "$([[ $active == 1 ]] && echo active || echo inactive)"
    printf "Logging: %s\n" "$([[ $logging == low ]] && echo "on (low)" || echo off)"
    printf "Default: %s (incoming), %s (outgoing), disabled (routed)\n" "$incoming" "$outgoing"
    cat "$rules"
    ;;
  "default deny incoming") incoming=deny; write_state ;;
  "default allow outgoing") outgoing=allow; write_state ;;
  "logging low") logging=low; write_state ;;
  "--force enable") active=1; write_state ;;
  *) echo "unexpected ufw call: $*" >&2; exit 1 ;;
esac'

stub_bin "$STUBS" sysctl 'exit 0'
stub_bin "$STUBS" arch-audit 'exit 0'
stub_bin "$STUBS" lsblk 'printf "btrfs\ncrypto_LUKS\nvfat\n"'
stub_bin "$STUBS" ss 'printf "udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:*\n"'
stub_bin "$STUBS" fwupdmgr 'printf "UEFI secure boot: Disabled\n"'

# The real account running tests is irrelevant; make the audit deterministic
# and expose the input-group warning.
# shellcheck disable=SC2016
stub_bin "$STUBS" id '
case "$1" in
  -nG) echo "tester input" ;;
  *) /usr/bin/id "$@" ;;
esac'

make_machine() {
  local home root pkgdb units ufw_state ufw_rules
  home="$(make_fake_home)"
  root="$TEST_TMP/root.$RANDOM"
  pkgdb="$TEST_TMP/pkgdb.$RANDOM"
  units="$TEST_TMP/units.$RANDOM"
  ufw_state="$TEST_TMP/ufw-state.$RANDOM"
  ufw_rules="$TEST_TMP/ufw-rules.$RANDOM"
  mkdir -p "$root/etc/sysctl.d" "$root/etc/sddm.conf.d" \
    "$pkgdb" "$units" "$home/.local/share/keyrings" \
    "$home/.local/state/omarchy/indicators"

  cat > "$root/etc/pacman.conf" <<'EOF'
[options]
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch

[personal]
SigLevel = Optional TrustAll
Server = https://packages.example.invalid/$arch
EOF

  cat > "$root/etc/sddm.conf.d/autologin.conf" <<'EOF'
[Autologin]
User=tester
Session=omarchy.desktop
EOF

  cat > "$home/.local/share/keyrings/Default_keyring.keyring" <<'EOF'
[keyring]
display-name=Default keyring
lock-on-idle=false
lock-after=false

[1]
secret=DO_NOT_PRINT_THIS_SECRET
EOF
  : > "$home/.local/state/omarchy/indicators/stay-awake"
  printf '%s\n' 'Host *' > "$home/.ssh/config.bak.20260819224126"
  printf '%s\n' 'PRIVATE KEY' > "$home/.ssh/private-key"
  chmod 755 "$home" "$home/.local/share/keyrings"
  chmod 644 "$home/.ssh/config.bak.20260819224126" \
    "$home/.local/share/keyrings/Default_keyring.keyring"
  chmod 400 "$home/.ssh/private-key"

  cat > "$ufw_state" <<'EOF'
active=0
incoming=allow
outgoing=allow
logging=off
EOF
  printf '%s\n' '53317/tcp ALLOW Anywhere' > "$ufw_rules"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$home" "$root" "$pkgdb" "$units" "$ufw_state" "$ufw_rules"
}

run_setup() {
  env HOME="$HOME_DIR" \
      USER=tester \
      PATH="$STUBS:/usr/bin" \
      PACMAN_CONF="$ROOT_DIR/etc/pacman.conf" \
      SYSCTL_FILE="$ROOT_DIR/etc/sysctl.d/60-omarchy-security.conf" \
      SDDM_CONFIG_DIR="$ROOT_DIR/etc/sddm.conf.d" \
      STAY_AWAKE_FILE="$HOME_DIR/.local/state/omarchy/indicators/stay-awake" \
      KEYRING_DIR="$HOME_DIR/.local/share/keyrings" \
      SSH_DIR="$HOME_DIR/.ssh" \
      FAKE_PKG_DB="$PKGDB" \
      FAKE_UNIT_STATE="$UNITS" \
      FAKE_UFW_STATE="$UFW_STATE" \
      FAKE_UFW_RULES="$UFW_RULES" \
      "$REPO_ROOT/bin/setup-security-hardening" "$@" 2>&1
}

IFS=$'\t' read -r HOME_DIR ROOT_DIR PKGDB UNITS UFW_STATE UFW_RULES <<< "$(make_machine)"
PACMAN_CONF="$ROOT_DIR/etc/pacman.conf"
SYSCTL_FILE="$ROOT_DIR/etc/sysctl.d/60-omarchy-security.conf"
KEYRING_FILE="$HOME_DIR/.local/share/keyrings/Default_keyring.keyring"
SSH_BACKUP="$HOME_DIR/.ssh/config.bak.20260819224126"
PRIVATE_KEY="$HOME_DIR/.ssh/private-key"

# --- dry run ---------------------------------------------------------------

pacman_before="$(cat "$PACMAN_CONF")"
ufw_before="$(cat "$UFW_STATE")"
out="$(run_setup --dry-run --yes)"

it "--dry-run leaves pacman configuration unchanged"
assert_eq "$pacman_before" "$(cat "$PACMAN_CONF")" "pacman.conf"

it "--dry-run writes no sysctl drop-in"
assert_no_file "$SYSCTL_FILE"

it "--dry-run installs no package"
assert_no_file "$PKGDB/arch-audit"

it "--dry-run enables no timer"
assert_no_file "$UNITS/arch-audit.timer"

it "--dry-run leaves firewall state unchanged"
assert_eq "$ufw_before" "$(cat "$UFW_STATE")" "UFW state"

it "--dry-run leaves sensitive-file permissions unchanged"
assert_eq "644" "$(stat -c '%a' "$SSH_BACKUP")" "SSH backup mode"

it "--dry-run previews package signature hardening"
assert_contains "$out" "would write $PACMAN_CONF"

it "--dry-run previews sysctl application"
assert_contains "$out" "sysctl -p $SYSCTL_FILE"

# --- real run --------------------------------------------------------------

out="$(run_setup --yes)"

it "requires trusted signatures for Omarchy packages"
assert_file_contains "$PACMAN_CONF" "SigLevel = Required DatabaseOptional TrustedOnly"

it "removes the permissive Omarchy signature policy"
assert_not_contains "$(awk '/^\[omarchy\]/{repo=1; next} /^\[/{repo=0} repo{print}' "$PACMAN_CONF")" "Optional TrustAll"

it "preserves LocalFileSigLevel for vetted local recipes"
assert_file_contains "$PACMAN_CONF" "LocalFileSigLevel = Optional"

it "does not change another repository's policy"
assert_contains "$(awk '/^\[personal\]/{repo=1; next} repo{print}' "$PACMAN_CONF")" "SigLevel = Optional TrustAll"

it "backs up pacman.conf before editing"
if compgen -G "$PACMAN_CONF.bak.*" >/dev/null; then pass; else fail "pacman.conf backup missing"; fi

it "installs arch-audit through Omarchy"
assert_file "$PKGDB/arch-audit"

it "enables the packaged arch-audit timer"
assert_file "$UNITS/arch-audit.timer"

it "enables UFW with deny-incoming and allow-outgoing defaults"
# The fixture is shell syntax and contains no untrusted content.
active="" incoming="" outgoing="" logging=""
# shellcheck disable=SC1090
. "$UFW_STATE"
assert_eq "1 deny allow low" "$active $incoming $outgoing $logging" "UFW baseline"

it "preserves explicit UFW allow rules"
assert_file_contains "$UFW_RULES" "53317/tcp ALLOW Anywhere"

it "installs kernel pointer restriction"
assert_file_contains "$SYSCTL_FILE" "kernel.kptr_restrict = 1"

it "disables IPv4 redirect emission"
assert_file_contains "$SYSCTL_FILE" "net.ipv4.conf.all.send_redirects = 0"

it "disables IPv6 redirect acceptance"
assert_file_contains "$SYSCTL_FILE" "net.ipv6.conf.all.accept_redirects = 0"

it "applies only the managed sysctl file"
assert_contains "$(cat "$STUBS/sysctl.log")" "-p $SYSCTL_FILE"

it "removes group/world access from an SSH backup"
assert_eq "600" "$(stat -c '%a' "$SSH_BACKUP")" "SSH backup mode"

it "does not add owner write permission to a read-only private key"
assert_eq "400" "$(stat -c '%a' "$PRIVATE_KEY")" "private key mode"

it "removes group/world access from the desktop keyring"
assert_eq "600" "$(stat -c '%a' "$KEYRING_FILE")" "keyring mode"

it "reports deliberately preserved convenience and device risks"
assert_contains "$out" "SDDM autologin remains enabled by choice"

it "warns that input-group membership is no longer something Omarchy grants"
assert_contains "$out" "input-group membership allows unprivileged keylogging"

it "warns about the printer-discovery daemon Omarchy withdrew"
assert_contains "$out" "cups-browsed is still enabled"

it "reports a real non-loopback listener without inventing a blank one"
assert_contains "$out" "udp 0.0.0.0:5353"

it "does not print stored keyring secret values"
assert_not_contains "$out" "DO_NOT_PRINT_THIS_SECRET"

# --- idempotence -----------------------------------------------------------

backups_before="$(compgen -G "$PACMAN_CONF.bak.*" | wc -l)"
adds_before="$(grep -c '^pkg add arch-audit$' "$STUBS/omarchy.log")"
enables_before="$(grep -c '^enable --now arch-audit.timer$' "$STUBS/systemctl.log")"
out2="$(run_setup --yes)"

it "a second run creates no new pacman backup"
assert_eq "$backups_before" "$(compgen -G "$PACMAN_CONF.bak.*" | wc -l)" "backup count"

it "a second run installs no package"
assert_eq "$adds_before" "$(grep -c '^pkg add arch-audit$' "$STUBS/omarchy.log")" "package adds"

it "a second run enables no service"
assert_eq "$enables_before" "$(grep -c '^enable --now arch-audit.timer$' "$STUBS/systemctl.log")" "timer enables"

it "a second run reports the managed files as current"
assert_contains "$out2" "$PACMAN_CONF already up to date"

it "a second run exits successfully"
run_setup --yes >/dev/null 2>&1
assert_status 0 $?

# --- signing-key failure is fail-closed -----------------------------------

IFS=$'\t' read -r HOME_DIR ROOT_DIR PKGDB UNITS UFW_STATE UFW_RULES <<< "$(make_machine)"
PACMAN_CONF="$ROOT_DIR/etc/pacman.conf"
pacman_before="$(cat "$PACMAN_CONF")"
status=0
FAKE_KEY_STATE=untrusted run_setup --yes >/dev/null 2>&1 || status=$?

it "an untrusted Omarchy signing key fails setup"
if [[ "$status" -ne 0 ]]; then pass; else fail "expected non-zero exit"; fi

it "signing-key failure leaves pacman.conf untouched"
assert_eq "$pacman_before" "$(cat "$PACMAN_CONF")" "pacman.conf after key failure"

it "signing-key failure performs no later hardening actions"
assert_no_file "$PKGDB/arch-audit"

# --- package-source policy is fail-closed ---------------------------------

IFS=$'\t' read -r HOME_DIR ROOT_DIR PKGDB UNITS UFW_STATE UFW_RULES <<< "$(make_machine)"
status=0
FAKE_ARCH_REPO=omarchy run_setup --yes >/dev/null 2>&1 || status=$?

it "a non-official arch-audit package source fails setup"
if [[ "$status" -ne 0 ]]; then pass; else fail "expected non-zero exit"; fi

it "a rejected arch-audit source installs nothing"
assert_no_file "$PKGDB/arch-audit"

it "a rejected arch-audit source enables no timer"
assert_no_file "$UNITS/arch-audit.timer"

finish

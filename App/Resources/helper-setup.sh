#!/bin/bash
#
# Installs or removes Battery Trace's optional privileged helper. Runs as root.
#
# Shipped inside the app, in Contents/Resources; the helper binary it installs
# is in Contents/MacOS. The app runs this through macOS's administrator dialog,
# so nobody has to open Terminal. `make install-helper` runs the same file with
# sudo for a build from source, so there is one installer, not two.
#
# What gets installed:
#
#   /Library/PrivilegedHelperTools/app.batterytrace.helper
#       root:wheel 755. Two verbs, `status` and `serve`, and no other
#       arguments. What `serve` will do is fixed in the binary: a powermetrics
#       sample with fixed samplers, and rusage for numeric PIDs. See the header
#       of BatteryTraceKit/Sources/HelperServer/HelperServer.swift.
#
#   /etc/sudoers.d/batterytrace
#       NOPASSWD for exactly those two invocations of that binary, for one
#       user. Validated with `visudo -c` before it goes into sudoers.d.
#
# Nothing else. No LaunchDaemon: the helper runs only while Battery Trace
# runs, started by it, and it changes nothing on the system, so a copy left
# behind after the app is deleted does nothing.
#
# Usage (as root):
#   helper-setup.sh install <helper-binary> <user>
#   helper-setup.sh uninstall

set -euo pipefail

HELPER_NAME="app.batterytrace.helper"
HELPER_DEST="/Library/PrivilegedHelperTools/${HELPER_NAME}"
# No dot in the file name: sudo's #includedir skips files whose name has one.
SUDOERS_DEST="/etc/sudoers.d/batterytrace"

fail() { echo "helper-setup: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root"

install_helper() {
  local source="$1" user="$2"

  # The user name goes into a sudoers rule, so it is checked against the
  # characters a macOS short name can contain and against real accounts.
  [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || fail "not a valid user name: ${user}"
  id -u "$user" >/dev/null 2>&1 || fail "no such user: ${user}"
  [ -f "$source" ] && [ -x "$source" ] || fail "helper binary not found at ${source}"

  # Copied beside the destination and renamed over it, so the binary the
  # sudoers rule names is never half-written. A helper already running keeps
  # its old copy until Battery Trace restarts it.
  mkdir -p /Library/PrivilegedHelperTools
  install -m 755 -o root -g wheel "$source" "${HELPER_DEST}.new"
  mv -f "${HELPER_DEST}.new" "$HELPER_DEST"

  # Ownership is the security boundary. A NOPASSWD rule naming a binary the
  # user could rewrite would be a one-line root escalation.
  local perms
  perms=$(stat -f "%Sp %Su:%Sg" "$HELPER_DEST")
  [ "$perms" = "-rwxr-xr-x root:wheel" ] \
    || fail "helper is ${perms}, expected -rwxr-xr-x root:wheel"

  # Validated before it goes near /etc/sudoers.d: a malformed file there can
  # break sudo for the whole Mac.
  local sudoers
  sudoers=$(mktemp)
  cat > "$sudoers" <<RULE
# Installed by Battery Trace for its optional privileged helper.
# Grants exactly two invocations of one root-owned binary, no other arguments.
# Remove from Battery Trace: Settings > General > Privileged helper > Uninstall.
${user} ALL=(root) NOPASSWD: ${HELPER_DEST} status
${user} ALL=(root) NOPASSWD: ${HELPER_DEST} serve
RULE
  if ! visudo -c -f "$sudoers" >/dev/null 2>&1; then
    rm -f "$sudoers"
    fail "the generated sudoers rule did not validate"
  fi
  install -m 440 -o root -g wheel "$sudoers" "$SUDOERS_DEST"
  rm -f "$sudoers"

  "$HELPER_DEST" status >/dev/null || fail "the installed helper does not run"
  echo "installed"
}

uninstall_helper() {
  # The rule goes first, so nothing can start the helper while it is removed.
  rm -f "$SUDOERS_DEST" "$HELPER_DEST" "${HELPER_DEST}.new"
  echo "uninstalled"
}

case "${1:-}" in
  install)
    [ $# -eq 3 ] || fail "usage: $0 install <helper-binary> <user>"
    install_helper "$2" "$3" ;;
  uninstall)
    uninstall_helper ;;
  *)
    fail "usage: $0 install <helper-binary> <user> | uninstall" ;;
esac

#!/bin/bash
# Run a command where the real desktop cannot be reached.
#
#   sandbox.sh <theme name> <command> [args...]
#
# The overview's Service evals gesture.lua into Hyprland the moment it exists,
# so instantiating it against the live session would register gestures for real.
# Unsetting the signature is not enough: hyprctl falls back to scanning the
# runtime dir, and Quickshell's module has an opinion of its own. So:
#
#   - bwrap, with new user, pid, net, ipc and uts namespaces. A new net
#     namespace also cuts off abstract sockets, which is where X lives.
#   - /run, /tmp, /var/tmp and $HOME are empty tmpfs mounts. No Hyprland socket,
#     no Wayland socket, no D-Bus, no ~/.config, no ~/.local/state.
#   - the environment is cleared, and only what is below is set.
#   - /usr/bin/hyprctl is replaced by fake-hyprctl, which opens no socket.
#   - the plugins are mounted read-only.
#
# preflight() proves all of that from inside before the command runs, and the
# command does not run if any of it fails.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/../.." && pwd)
plugins=$(cd "$plugin/.." && pwd)
themes=$plugins/../themes
real_sig=${HYPRLAND_INSTANCE_SIGNATURE:-}

if [[ ${1:-} != --inside ]]; then
  theme=$1
  shift
  # Reached only from the outside; the inside is the same script with --inside.
  out=()
  # Only where a run was told to leave pictures, and only there.
  [[ -n ${TEST_OUT:-} ]] && out=(--bind "$TEST_OUT" /tmp/out)
  exec bwrap \
    --unshare-all --die-with-parent --new-session \
    --ro-bind / / --dev /dev --proc /proc \
    --tmpfs /run --tmpfs /tmp --tmpfs /var/tmp --tmpfs "$HOME" \
    --ro-bind "$plugins" "$plugins" \
    --ro-bind-try "$themes" "$themes" \
    "${out[@]}" \
    --ro-bind "$here/fake-hyprctl" /usr/bin/hyprctl \
    --ro-bind /usr/bin/hyprctl /run/real-hyprctl \
    --clearenv \
    --setenv HOME "$HOME" \
    --setenv PATH /usr/bin \
    --setenv LANG C.UTF-8 \
    --setenv XDG_RUNTIME_DIR /run/test \
    --setenv XDG_CACHE_HOME /tmp/cache \
    --setenv XDG_STATE_HOME "$HOME/.local/state" \
    --setenv XDG_CONFIG_HOME "$HOME/.config" \
    --setenv HYPRLAND_INSTANCE_SIGNATURE test-sandbox \
    --setenv QT_QPA_PLATFORM offscreen \
    --setenv QT_LOGGING_RULES "qt.qml.typeresolution=false" \
    --setenv FAKE_HYPR_LOG /tmp/hypr.log \
    --setenv FAKE_HYPR_FIXTURES "$here/harness/fixtures.json" \
    --setenv FAKE_HYPR_FAIL_FILE /tmp/hypr.fail \
    --setenv REAL_SIG "$real_sig" \
    --setenv TEST_THEME "$theme" \
    --setenv TEST_OUT "${TEST_OUT:+/tmp/out}" --setenv TEST_ALLOW "${TEST_ALLOW:-}" --setenv TEST_VERBOSE "${TEST_VERBOSE:-}" \
    --setenv TEST_TIMEOUT "${TEST_TIMEOUT:-60}" \
    --setenv TEST_PLUGINS "$plugins" \
    --setenv TEST_THEMES "$themes" \
    "$0" --inside "$@"
fi
shift

die() { echo "ISOLATION FAILED: $*" >&2; exit 99; }

preflight() {
  local uid sock
  uid=$(id -u)
  [[ ! -e /run/user/$uid ]] || die "/run/user/$uid is reachable"
  [[ -z ${WAYLAND_DISPLAY:-} && -z ${DISPLAY:-} && -z ${DBUS_SESSION_BUS_ADDRESS:-} ]] || die "a session variable leaked"
  [[ $HYPRLAND_INSTANCE_SIGNATURE == test-sandbox ]] || die "signature is $HYPRLAND_INSTANCE_SIGNATURE"
  [[ ! -e $HOME/.config && ! -e $HOME/.local ]] || die "the real home is reachable"
  [[ ! -e /tmp/.X11-unix ]] || die "a real X socket directory is reachable"
  grep -q FAKE-HYPRCTL /usr/bin/hyprctl || die "/usr/bin/hyprctl is not the fake"
  touch "$TEST_PLUGINS/.w" 2>/dev/null && die "the plugins are writable"
  # Any socket file at all, anywhere a client could look.
  sock=$(find /run /tmp /var/tmp "$HOME" -xdev -type s 2>/dev/null | head -1)
  [[ -z $sock ]] || die "a socket is reachable: $sock"
  # And the real client, given every chance it has, finds nothing.
  /run/real-hyprctl version >/dev/null 2>&1 && die "the real hyprctl reached a compositor with the test signature"
  [[ -z $REAL_SIG ]] || ! HYPRLAND_INSTANCE_SIGNATURE=$REAL_SIG /run/real-hyprctl version >/dev/null 2>&1 \
    || die "the real hyprctl reached a compositor with the real signature"
  env -u HYPRLAND_INSTANCE_SIGNATURE /run/real-hyprctl version >/dev/null 2>&1 \
    && die "the real hyprctl reached a compositor with no signature"
  [[ $(tail -n +3 /proc/net/dev | grep -vc '^ *lo:' || true) == 0 ]] || die "a network interface is reachable"
}
preflight

# A shell root that resolves `import qs.*` as the running shell does, with the
# plugins in it, and this test's choice of theme where the plugins look for it.
root=/tmp/root
mkdir -p "$root" /run/test /tmp/cache "$HOME/.local/state/omarchy/current"
ln -s /usr/share/omarchy/shell/Commons /usr/share/omarchy/shell/Ui "$root/"
ln -s "$TEST_PLUGINS" "$root/plugins"
printf '%s\n' "$TEST_THEME" >"$HOME/.local/state/omarchy/current/theme.name"
ln -s "$here/harness/wallpaper.png" "$HOME/.local/state/omarchy/current/background"
# Where the shell reads a theme's files at startup, for a theme this tree ships. A tree
# without it, or a theme that isn't there, runs on the shell's own defaults.
if [[ -f $TEST_THEMES/$TEST_THEME/shell.toml ]]; then
  ln -s "$TEST_THEMES/$TEST_THEME" "$HOME/.local/state/omarchy/current/theme"
fi
: >"$FAKE_HYPR_LOG"
export TEST_ROOT=$root

python3 "$here/fake-hypr.py" /run/test test-sandbox "$FAKE_HYPR_LOG" "$FAKE_HYPR_FIXTURES" &
for _ in {1..100}; do
  [[ -S /run/test/hypr/test-sandbox/.socket.sock && -S /run/test/hypr/test-sandbox/.socket2.sock ]] && break
  sleep 0.02
done

exec "$@"

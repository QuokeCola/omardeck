#!/bin/bash
# Inside the sandbox: run one harness as a shell of its own, with `qs.*` resolving
# as it does in the real shell, and fail on its verdict rather than its exit code
# (quickshell exits 0 whatever a script did).
#
#   run-qs.sh <dir under harness/> [xcb|xcb-strip]
#
# With no display it runs offscreen, which is enough for anything without a
# PanelWindow. xcb gets a private Xvfb, with llvmpipe doing the shaders for real.
# xcb-strip also lets a Surface be instantiated: see below.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
name=$1
display=${2:-}

if [[ $display == xcb* ]]; then
  Xvfb :77 -screen 0 1600x1000x24 -nolisten tcp >/dev/null 2>&1 &
  for _ in {1..100}; do
    [[ -e /tmp/.X11-unix/X77 ]] && break
    sleep 0.02
  done
  export DISPLAY=:77 QT_QPA_PLATFORM=xcb QSG_RENDER_LOOP=basic
fi

if [[ $display == xcb-strip ]]; then
  # Layer-shell attached properties cannot be created on X, and everything else
  # about a Surface can. So this run uses a copy with just those lines taken
  # out, which is the one difference from the shipped files.
  rm "$TEST_ROOT/plugins"
  mkdir "$TEST_ROOT/plugins"
  cp -r "$TEST_PLUGINS/quokecola.omardeck" "$TEST_PLUGINS/quokecola.hud" "$TEST_ROOT/plugins/"
  sed -i -E '/WlrLayershell\.(namespace|layer):/d; /WlrLayershell\.keyboardFocus:/,+1d' \
    "$TEST_ROOT"/plugins/quokecola.omardeck/overview/shell/*.qml "$TEST_ROOT"/plugins/quokecola.omardeck/dock/*.qml
  # The settings popout's window: its keyboard focus runs to three lines.
  sed -i -E '/WlrLayershell\.keyboardFocus: open/,+2d; /WlrLayershell\.(namespace|layer|keyboardFocus):/d' \
    "$TEST_ROOT"/plugins/quokecola.omardeck/notifications/NotificationPopup.qml
  if grep -q 'WlrLayershell\.' "$TEST_ROOT"/plugins/quokecola.omardeck/overview/shell/*.qml "$TEST_ROOT"/plugins/quokecola.omardeck/dock/*.qml; then
    echo "FAIL a layer-shell line this harness does not know about"
    exit 1
  fi
fi

if [[ $display == xcb-panels ]]; then
  # The bar's panels, opened for real on X: the same layer-shell lines out, in the shared
  # Ui as well, and doubles for the two services a fixture can't otherwise reach, as
  # their readers are read-only bindings. The panels' other state is theirs to be set.
  export OMARCHY_PATH=/usr/share/omarchy    # for the strings: layout is what this checks
  rm "$TEST_ROOT/plugins" "$TEST_ROOT/Ui"
  mkdir "$TEST_ROOT/plugins"
  cp -rL "$TEST_PLUGINS"/quokecola.* "$TEST_ROOT/plugins/"
  cp -rL /usr/share/omarchy/shell/Ui "$TEST_ROOT/Ui"
  sed -i -E '/WlrLayershell\.keyboardFocus: open$/,+2d; /WlrLayershell\.keyboardFocus: shownKeyboardFocus/d; /WlrLayershell\.(namespace|layer|keyboardFocus):/d' "$TEST_ROOT"/Ui/*.qml
  sed -i -E '/WlrLayershell\./d' "$TEST_ROOT"/plugins/quokecola.{audio,bluetooth,clock,network,power,tailscale,telemetry,weather}/*.qml
  sed -i -E 's/readonly property var adapter: Bluetooth\.defaultAdapter/property var adapter: null/; s/readonly property var devices: Bluetooth\.devices.*/property var devices: []/' \
    "$TEST_ROOT/plugins/quokecola.bluetooth/Panel.qml"
  sed -i -E 's/UPower\.displayDevice/root.fakeDevice/g; s/UPower\.onBattery/root.fakeOnBattery/g; 0,/^  id: root$/s//  id: root\n  property var fakeDevice: null\n  property bool fakeOnBattery: false/' \
    "$TEST_ROOT/plugins/quokecola.power/Panel.qml"
fi

plugin=$TEST_ROOT/plugins/quokecola.omardeck
{
  find -L "$plugin/overview/shell" "$plugin/look" "$plugin/dock" -maxdepth 1 -name '*.qml' 2>/dev/null
  printf '%s\n' "$plugin/Service.qml" "$plugin/BarWidget.qml"
} >"$TEST_ROOT/files.txt"

cp "$here/harness/$name"/*.qml "$TEST_ROOT/"
out=/tmp/qs.out
timeout -k 2 "${TEST_TIMEOUT:-60}" qs -p "$TEST_ROOT/shell.qml" --no-color >"$out" 2>&1
code=$?

if [[ -n ${TEST_VERBOSE:-} ]]; then
  grep -v 'quickshell.io.socket' "$out"
  echo "--- hypr log"
  cat "$FAKE_HYPR_LOG"
fi

grep -E 'PASS |FAIL |VERDICT ' "$out" | sed -E 's/^.*(PASS |FAIL |VERDICT )/\1/'

# A script error is a failure, whatever the verdict says, if it comes from the
# plugin's own code. The harness's own output is not included.
errors=$(grep -E '(quokecola\.(omardeck|hud|audio|bar-rule|bluetooth|clock|network|power|tailscale|telemetry|weather)|@/qs/).*(TypeError|ReferenceError|Unable to assign|Cannot assign|is not defined|is not a function)' "$out" \
         | grep -v 'qml: ' || true)
if [[ -n $errors ]]; then
  echo "FAIL script errors:"
  echo "$errors"
  exit 1
fi
if [[ $code -ne 0 ]]; then
  echo "FAIL qs exited $code"
  grep -v 'quickshell.io.socket' "$out" | tail -5
  exit 1
fi
if ! grep -q 'VERDICT ok' "$out"; then
  echo "FAIL no passing verdict"
  exit 1
fi

#!/bin/bash
# Render the real notification sheet from fixtures, and drive it, with no desktop.
#
#   tests/sheet-harness.sh <theme> <out dir>     theme: plain | death-stranding
#
# Runs inside overview/tests/sandbox.sh, which proves it cannot reach the live
# session: empty $HOME, no sockets, private Xvfb, and a throwaway NC_STORE that
# is seeded with the invented notifications below. Nothing is sent, and no real
# archive is read. Fails on the harness's verdict.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

if [[ ${1:-} != --inside ]]; then
  theme=${1:?theme}; out=${2:?out dir}
  mkdir -p "$out"
  TEST_OUT=$out exec "$here/../../overview/tests/sandbox.sh" "$theme" "$0" --inside
fi

Xvfb :78 -screen 0 1600x1000x24 -nolisten tcp >/dev/null 2>&1 &
for _ in {1..100}; do [[ -e /tmp/.X11-unix/X78 ]] && break; sleep 0.02; done
export DISPLAY=:78 QT_QPA_PLATFORM=xcb QSG_RENDER_LOOP=basic

# Layer-shell attached properties cannot be created on X: a copy without them.
rm "$TEST_ROOT/plugins"
mkdir "$TEST_ROOT/plugins"
cp -r "$TEST_PLUGINS/quokecola.omardeck" "$TEST_PLUGINS/quokecola.hud" "$TEST_ROOT/plugins/"
popup=$TEST_ROOT/plugins/quokecola.omardeck/notifications/NotificationPopup.qml
sed -i -E '/WlrLayershell\.(namespace|layer):/d; /WlrLayershell\.keyboardFocus: WlrKeyboardFocus\.None/d' "$popup"
sed -i -E '/WlrLayershell\.keyboardFocus:/,+2d' "$popup"
# X clips drawing to a window's mask, where Wayland only clips input. The sheet's
# soft edge is drawn outside its input region, so give the X window all of it.
sed -i -E '/x: root\.slideIn \? Math\.floor/d; /y: root\.slideIn \? Math\.floor/d;
  s/width: root\.slideIn \? Math\.ceil\(card\.width\) \+ 1 : root\.screenW/width: 100000/;
  s/height: root\.slideIn \? Math\.ceil\(card\.height\) \+ 1 : root\.screenH/height: 100000/' "$popup"
if grep -q 'WlrLayershell\.[a-z]*:' "$popup"; then
  echo "FAIL a layer-shell line this harness does not know about"; exit 1
fi

export NC_SRC_DIR=/tmp/nc-src NC_SRC_HISTORY=/tmp/nc-src/history NC_STORE=/tmp/nc-store NC_PREVIEWS=0
mkdir -p "$NC_SRC_HISTORY" /tmp/bin
printf '#!/bin/sh\necho off\n' >/tmp/bin/omarchy-shell
chmod +x /tmp/bin/omarchy-shell
export PATH=/tmp/bin:$PATH OMARCHY_PATH=/usr/share/omarchy

python3 - <<'PY'
import json, time
now = int(time.time() * 1000)
minute = 60000
rows = [
  # newer than the read mark (1 h back): unread
  (2,   "Backup",  1, "Snapshot finished", "412 files, 1.2 GB, no errors."),
  (5,   "Power",   2, "Battery critically low", "4% left. Plug in within a few minutes or the laptop will suspend."),
  (9,   "Build",   1, "Pipeline passed on main", "All 71 checks are green."),
  (14,  "Build",   2, "Deploy failed on staging", "The rollout stopped at step 3 of 5."),
  (21,  "Build",   1, "Pipeline started", "Triggered by a push to main."),
  # older than the read mark: read
  (130, "org.example.LongApplicationIdentifier", 1, "A summary long enough that it has to elide before it reaches the end of the card", "A body that runs on for a while so that it wraps onto a second line and then, because two lines is all a card gets, elides at the end of that second line."),
  (190, "Disk",    2, "Disk nearly full", "Seen earlier; this one should sit quietly."),
  (800, "Chat",    1, "Three new messages", "Sent to the design channel."),
  (900, "Chat",    1, "Two new messages", "Sent to the design channel."),
  (2900,"Calendar",1, "Review in ten minutes", ""),
]
for n, (age, app, urgency, summary, body) in enumerate(rows):
  stamp = now - age * minute
  with open(f"/tmp/nc-src/history/{stamp}-{n+1}.json", "w") as f:
    json.dump({"timestamp": stamp, "app": app, "urgency": urgency, "summary": summary, "body": body}, f)
print(now - 60 * minute, file=open("/tmp/seen", "w"))
PY
center=$TEST_ROOT/plugins/quokecola.omardeck/notifications/bin/notification-center
"$center" sync >/dev/null
"$center" seen "$(cat /tmp/seen)" >/dev/null

cp "$here/harness-sheet/"*.qml "$TEST_ROOT/"
log=/tmp/qs.out
timeout -k 2 "${TEST_TIMEOUT:-90}" dbus-run-session -- qs -p "$TEST_ROOT/shell.qml" --no-color >"$log" 2>&1
code=$?
cp "$log" "$TEST_OUT/qs-$TEST_THEME.log"
grep -E 'INFO |FAIL!|VERDICT |MEASURE |Totals|Loc:' "$log" | sed -E 's/^.*qml: //'
errors=$(grep -E '(quokecola\.(omardeck|hud)|@/qs/).*(TypeError|ReferenceError|Unable to assign|Cannot assign|is not defined|is not a function)' "$log" | grep -v 'qml: ' || true)
if [[ -n $errors ]]; then echo "FAIL script errors:"; echo "$errors"; exit 1; fi
[[ $code -eq 0 ]] || { echo "FAIL qs exited $code"; tail -5 "$log"; exit 1; }
grep -q 'VERDICT ok' "$log" || { echo "FAIL no passing verdict"; exit 1; }

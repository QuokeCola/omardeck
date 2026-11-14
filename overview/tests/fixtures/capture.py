#!/usr/bin/env python3
"""Keep the real answer to the query Screens.qml makes, with personal text taken out.

  tests/fixtures/capture.py <name>     writes tests/fixtures/<name>.batch.txt

Only ever asks (`hyprctl -j --batch "monitors; clients"`, read only), but it does ask
the live session, so run it by hand and never from the tests: the point is to have
what the real compositor says after a real unplug to test against.

Window titles and app-set descriptions become placeholders, and a monitor's serial
becomes a placeholder too, everywhere it appears: it is part of the description the
fold knows a screen by, so what matters is that it stays the same screen.
"""
import json
import os
import subprocess
import sys

SEPARATOR = "\n\n\n"

raw = subprocess.run(["/usr/bin/hyprctl", "-j", "--batch", "monitors; clients"],
                     check=True, capture_output=True, text=True).stdout
monitors, clients = (json.loads(part) for part in raw.split(SEPARATOR))

serials = 0
for m in monitors:
    if m.get("serial"):
        serials += 1
        placeholder = f"SERIAL-{serials}"
        m["description"] = m["description"].replace(m["serial"], placeholder)
        m["serial"] = placeholder

for i, c in enumerate(clients, 1):
    c["title"] = c["initialTitle"] = f"window-{i}"
    c["xdgDescription"] = c["xdgTag"] = ""

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, sys.argv[1] + ".batch.txt"), "w") as out:
    out.write(SEPARATOR.join(json.dumps(part, indent=2) for part in (monitors, clients)) + "\n")

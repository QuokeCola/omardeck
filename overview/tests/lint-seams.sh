#!/bin/bash
# The seams stay seams.
#
#  - The overview's own files say nothing of any theme: that is look/'s job, and
#    what keeps the plugin shareable with a tree that has no holographic theme.
#  - look/Look.qml and LookSlot.qml, shared with such a tree, say nothing either.
#  - Only look/Holo*.qml and ActiveLook.qml may name it. dock/ and notifications/
#    have their own probes for now, and are not checked.
#  - Nothing outside the hud imports its holo/ directory: a missing directory fails the
#    whole importing file, so another plugin takes a holo file through a Loader.
#  - No file reaches through overlay.service for what the overlay should offer.
#    Two known ones are allowed until the Surface is split.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/../.." && pwd)
bad=0

theme=$(grep -n -i -E 'holo|quokecola\.hud|death-stranding' \
          "$plugin"/overview/shell/*.qml "$plugin"/overview/app/* \
          "$plugin/look/Look.qml" "$plugin/look/LookSlot.qml" "$plugin/Service.qml")
if [[ -n $theme ]]; then
  echo "a theme named outside look/:"
  echo "$theme"
  bad=1
fi

imports=$(grep -rnE '^\s*import\s+".*(quokecola\.hud|holo)' "$plugin/.." --include='*.qml' --exclude-dir=quokecola.hud --exclude-dir=harness)
if [[ -n $imports ]]; then
  echo "holo imported from outside the hud:"
  echo "$imports"
  bad=1
fi

reach=$(grep -n 'overlay\.service' "$plugin"/overview/shell/*.qml \
          | grep -v -E 'overlay\.service\.(goal|dockCovers)\b|overlay\.service !== null')
if [[ -n $reach ]]; then
  echo "reaching through the overlay to the service:"
  echo "$reach"
  bad=1
fi

exit $bad

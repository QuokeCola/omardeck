#!/bin/bash
# Everything that can be checked without a desktop. Exits non-zero on any failure.
#
#   overview/tests/run.sh            all of it
#   overview/tests/run.sh node lua   just those suites
#
# Suites: node lua lint seams compile service pure overlay drive holo design dock panels
#
# compile, service and overlay instantiate the real plugin, so they only ever run
# inside sandbox.sh, which proves it cannot reach the live session first.
# TEST_OUT=<dir> has the overlay suite save what it draws there, for comparing
# frames across a refactor.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/../.." && pwd)
overview=$plugin/overview
qmllint=/usr/lib/qt6/bin/qmllint
holo_theme=death-stranding

failed=()
suite() {
  local name=$1
  shift
  echo "== $name"
  if "$@"; then
    echo "   ok"
  else
    failed+=("$name")
    echo "   FAILED"
  fi
}

run_node() {
  local f bad=0
  for f in "$here"/*-test.js; do
    node "$f" | tail -1 | sed "s|^|   $(basename "$f"): |"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || bad=1
  done
  return $bad
}

run_lua() {
  local f bad=0
  for f in "$overview"/app/*.lua; do
    luac -p "$f" || bad=1
  done
  lua "$here/gesture-test.lua" || bad=1
  return $bad
}

# qmllint is weak here (`var overlay` hides member errors and it cannot resolve
# qs.*), so what fails the run is what it cannot read at all. The rest is counted,
# to see a jump.
run_lint() {
  local out count
  shopt -s nullglob
  out=$("$qmllint" "$overview"/shell/*.qml "$plugin"/look/*.qml 2>&1)
  shopt -u nullglob
  count=$(grep -c 'Warning:' <<<"$out")
  echo "   qmllint: $count warnings"
  if grep -E 'Failed to open|\[syntax\]|Could not parse|Expected token' <<<"$out"; then
    return 1
  fi
}

run_qs() {
  "$here/sandbox.sh" "$1" "$here/run-qs.sh" "$2" ${3:+"$3"}
}

want() {
  [[ ${#selected[@]} -eq 0 ]] && return 0
  local s
  for s in "${selected[@]}"; do [[ $s == "$1" ]] && return 0; done
  return 1
}
selected=("$@")

want node && suite "node" run_node
want lua && suite "lua" run_lua
want lint && suite "qmllint" run_lint
if want seams && [[ -x $here/lint-seams.sh ]]; then suite "seams" "$here/lint-seams.sh"; fi
want compile && suite "compile" run_qs plain compile xcb
want service && suite "service replay" run_qs plain service
want pure && suite "pure modules agree with the QML" run_qs plain pure
if want overlay; then
  suite "overlay, plain theme" run_qs plain overlay xcb-strip
  suite "overlay, holo theme" run_qs "$holo_theme" overlay xcb-strip
  suite "shadow, plain theme" run_qs plain shadow xcb-strip
  suite "shadow, holo theme" run_qs "$holo_theme" shadow xcb-strip
fi
want drive && suite "overlay driven" run_qs plain drive xcb-strip
if want design; then
  suite "design states, plain theme" run_qs plain design xcb-strip
  suite "design states, holo theme" run_qs "$holo_theme" design xcb-strip
  suite "settings keyboard, plain theme" run_qs plain settings xcb-strip
  suite "settings keyboard, holo theme" run_qs "$holo_theme" settings xcb-strip
fi
if want holo; then
  suite "holo foundation, plain theme" run_qs plain holo xcb
  suite "holo foundation, holo theme" run_qs "$holo_theme" holo xcb
fi
if want dock; then
  suite "dock, plain theme" run_qs plain dock xcb-strip
  suite "dock, holo theme" run_qs "$holo_theme" dock xcb-strip
fi
if want panels; then
  suite "bar panels, plain theme" run_qs plain panels xcb-panels
  suite "bar panels, holo theme" run_qs "$holo_theme" panels xcb-panels
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all passing"

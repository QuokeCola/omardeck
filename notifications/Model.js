var CRITICAL_URGENCY = 2

// Recheck persisted paths at the click boundary, including unmigrated entries.
// Archived sender commands are never executable actions.
function isPreviewFile(value) {
  return typeof value === "string"
    && /^\/[^"'\x00-\x1f\x7f]*\.(jpe?g|png|webp|gif)$/i.test(value)
}

// Persist only a fixed image-editor intent; never execute an archived argv vector.
function fileCommand(row) {
  if (!row || !isPreviewFile(row.file)) return null
  return [row.fileAction === "edit-screenshot" ? "tensaku-edit" : "xdg-open", row.file]
}

function unreadState(entries, lastSeen) {
  var rows = Array.isArray(entries) ? entries : []
  var boundary = Number(lastSeen)
  if (!isFinite(boundary)) boundary = 0

  var unread = 0
  var hasCriticalUnread = false

  // Entries are newest first. Stop at the read boundary so an older critical
  // notification cannot keep the current badge red.
  for (var i = 0; i < rows.length; i++) {
    var entry = rows[i] || {}
    var timestamp = Number(entry.timestamp)
    if (!isFinite(timestamp)) continue
    if (timestamp <= boundary) break

    unread++
    if (Number(entry.urgency) === CRITICAL_URGENCY)
      hasCriticalUnread = true
  }

  return {
    unread: unread,
    hasCriticalUnread: hasCriticalUnread
  }
}

function relativeTime(timestamp, now) {
  var minutes = Math.floor(Math.max(0, now - timestamp) / 60000)
  if (minutes < 1) return "now"
  if (minutes < 60) return minutes + "m ago"
  if (minutes < 1440) return Math.floor(minutes / 60) + "h ago"
  return Math.floor(minutes / 1440) + "d ago"
}

function groupsFor(entries, filter, browserGrouping, identity) {
  identity = identity || (typeof require === "function" ? require("./BrowserIdentity.js") : null)
  browserGrouping = ["browser", "hostname", "none"].indexOf(browserGrouping) >= 0 ? browserGrouping : "browser"
  var needle = String(filter || "").toLowerCase()
  var byApp = Object.create(null)
  var seen = Object.create(null)
  var groups = []
  var sorted = (Array.isArray(entries) ? entries : []).filter(function(entry) {
    return entry && entry.key
  }).sort(function(a, b) {
    return Number(b.timestamp || 0) - Number(a.timestamp || 0)
  })
  for (var i = 0; i < sorted.length; i++) {
    var entry = sorted[i]
    if (!entry || !entry.key || seen[entry.key]) continue
    seen[entry.key] = true
    var app = String(entry.app || "Unknown app")
    if (needle && [app, entry.summary || "", entry.body || ""].join(" ").toLowerCase().indexOf(needle) < 0) continue
    var browser = identity && identity.browser(entry)
    var host = identity ? identity.hostname(entry) : ""
    var key = app
    if (browserGrouping !== "browser") {
      key = JSON.stringify(browser ? ["browser", app, browserGrouping, browserGrouping === "none" ? entry.key : host] : ["app", app])
    }
    var group = byApp[key]
    if (!group) {
      group = { key: key, app: app, label: browserGrouping === "hostname" && host ? host : app, hostname: host, iconEntry: entry, appIcon: "", glyph: "", timestamp: Number(entry.timestamp || 0), critical: false, entries: [] }
      byApp[key] = group
      groups.push(group)
    }
    // A browser-wide stack with several websites has no single website favicon.
    if (group.hostname !== host) { group.hostname = ""; group.iconEntry = null }
    // Archived image fields can be avatars; only appIcon identifies the app.
    if (!group.appIcon && entry.appIcon) group.appIcon = String(entry.appIcon)
    if (!group.glyph && entry.glyph) group.glyph = String(entry.glyph)
    group.critical = group.critical || Number(entry.urgency) === CRITICAL_URGENCY
    group.entries.push(entry)
  }
  return groups
}

function stackRows(entries, expanded, filter, browserGrouping, identity) {
  var groups = groupsFor(entries, filter, browserGrouping, identity)
  var rows = []
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i]
    var multiple = group.entries.length > 1
    var open = multiple && (Boolean(filter) || expanded[group.key] === true)
    rows.push({ id: "group:" + group.key, kind: "header", group: group, expanded: open })
    var visible = open ? group.entries : group.entries.slice(0, 1)
    // Flatten stacks so ListView virtualizes individual messages even in large groups.
    for (var j = 0; j < visible.length; j++) {
      rows.push({ id: "entry:" + visible[j].key, kind: "message", group: group,
        entry: visible[j], expanded: open, first: j === 0, last: j === visible.length - 1,
        layered: multiple && !open, depth: j })
    }
  }
  return rows
}

// The colour an app's icon is known by: the hue that most of its vivid pixels
// share, averaged within that hue. Greys, near-blacks and transparent pixels
// do not vote, so a monochrome icon yields null and the caller keeps its own
// colour. `data` is RGBA bytes, as Canvas getImageData returns them.
function dominantColor(data) {
  var bins = []
  for (var b = 0; b < 12; b++) bins.push({ w: 0, r: 0, g: 0, b: 0 })
  var opaque = 0, total = 0
  for (var i = 0; i + 3 < data.length; i += 4) {
    var r = data[i], g = data[i + 1], bl = data[i + 2], a = data[i + 3]
    if (a < 128) continue
    opaque++
    var max = Math.max(r, g, bl), min = Math.min(r, g, bl)
    if (max < 48) continue
    var sat = (max - min) / max
    if (sat < 0.3) continue
    var d = max - min, hue
    if (max === r) hue = ((g - bl) / d + 6) % 6
    else if (max === g) hue = (bl - r) / d + 2
    else hue = (r - g) / d + 4
    var bin = bins[Math.floor(hue * 2) % 12]
    var w = sat * a / 255
    bin.w += w; bin.r += r * w; bin.g += g * w; bin.b += bl * w
    total += w
  }
  // A few coloured pixels on a grey icon are an accent, not its colour.
  if (!opaque || total < opaque * 0.08) return null
  var best = bins[0]
  for (var k = 1; k < 12; k++) if (bins[k].w > best.w) best = bins[k]
  return { r: best.r / best.w / 255, g: best.g / best.w / 255, b: best.b / best.w / 255 }
}

if (typeof module !== "undefined") {
  module.exports = {
    isPreviewFile: isPreviewFile,
    fileCommand: fileCommand,
    CRITICAL_URGENCY: CRITICAL_URGENCY,
    unreadState: unreadState,
    relativeTime: relativeTime,
    groupsFor: groupsFor,
    stackRows: stackRows,
    dominantColor: dominantColor
  }
}

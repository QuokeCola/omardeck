import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons

// The bar's panels load and open under a theme, with the status lines saying what the
// theme asks for, no text below the theme's floor, and none outside its card. There is
// no D-Bus, Pipewire or network here, so the state comes from the fixtures below, set
// where a panel keeps it or through the doubles run-qs.sh swaps in. It is not a run
// against real services.
ShellRoot {
  id: root
  readonly property string plugins: Quickshell.env("TEST_ROOT") + "/plugins/"
  readonly property string out: Quickshell.env("TEST_OUT") || ""
  readonly property string theme: Quickshell.env("TEST_THEME") || ""
  readonly property bool holo: Commons.Color.pick("holo.line", "") !== ""
  property int failures: 0
  property int passes: 0

  function check(ok, what) {
    if (ok) passes++
    else failures++
    console.log((ok ? "PASS " : "FAIL ") + what)
  }

  // Everything else a plugin might ask of the bar, none of which draws.
  QtObject {
    id: fakeBar
    property var activePopout: null
    property color foreground: Commons.Color.foreground
    property color barForeground: Commons.Color.foreground
    property color urgent: Commons.Color.urgent
    property string fontFamily: Style.font.family
    property string iconFont: Style.font.family
    property string position: "top"
    property int barSize: 28
    property int iconSize: 14
    property int iconSlot: 26
    property int iconCanvas: 18
    property var shell: null
    property bool vertical: false
    property bool foregroundAnimationEnabled: true
    property color background: Commons.Color.background
    property var moduleWidgets: ({})
    property var clickTargets: []
    property bool centerHoverRevealSuppressed: false
    function barSizeFor(name) { return barSize }
    function requestPopout(key) { activePopout = key }
    function releasePopout(key) { if (activePopout === key) activePopout = null }
    function popoutCardFor(key) { return null }
    function notePopoutCard(key, card) {}
    function targetBelongsToWindow(target, window) { return false }
    function switchPanelFrom(panel, direction) { return false }
    function setCenterHoverRevealSuppressed(value) {}
    function run(command) {}
    function showTooltip() {}
    function hideTooltip() {}
  }

  FloatingWindow {
    id: barWindow
    visible: true
    implicitWidth: 400
    implicitHeight: 40
    color: "transparent"
    Item { id: slot; width: 26; height: 28; anchors.right: parent.right }
  }

  QtObject {
    id: fakeAdapter
    property bool enabled: true
    property bool discovering: true
    property string address: "AA"
    property string name: "hci0"
  }

  // Bluetooth's, read through Model.js.
  function device(name, connected, paired) {
    return { name: name, deviceName: name, address: name, connected: connected, paired: paired,
             bonded: paired, trusted: paired, batteryAvailable: false, state: 0, pairing: false }
  }

  // wttr.in's j1, as much of it as the panel reads.
  readonly property var report: ({
    current_condition: [{ temp_C: "13", temp_F: "55", FeelsLikeC: "11", FeelsLikeF: "52", windspeedKmph: "17",
                          windspeedMiles: "11", humidity: "71", weatherCode: "116", observation_time: "10:00 AM" }],
    nearest_area: [{ areaName: [{ value: "Ann Arbor" }], country: [{ value: "United States" }], latitude: "42.28", longitude: "-83.74" }],
    weather: []
  })

  function child(object, wanted) {
    for (const c of object.data) if (c && wanted in c) return c
    return null
  }

  // name, file, state before it opens, ms to wait, and what its status line should say
  // under the theme.
  readonly property var scenarios: [
    { name: "telemetry", wait: 2600, status: "FREQUENCY OF MAX", check: p => {
        check(p.updateMs === (holo ? 200 : 450), "telemetry: a value changes in " + p.updateMs + " ms")
        Style.reduceMotion = true
        check(p.updateMs === 0, "telemetry: and at once under reduced motion")
        Style.reduceMotion = false
    } },
    // More threads than fit side by side at the floor. Sampling is held off, to keep these.
    { name: "telemetry-32", plugin: "telemetry", wait: 1200, props: { settings: { refreshMs: 600000 } }, status: "FREQUENCY OF MAX",
      late: p => {
        p.coreLoad = Array(32).fill(0.4)
        p.coreMhz = Array(32).fill(3400)
      },
      check: (p, texts) => {
        if (!holo) return
        const row = texts.filter(t => t.text === "3.4").map(t => t.mapToItem(null, 0, 0).x).sort((a, b) => a - b)
        const width = texts.filter(t => t.text === "3.4")[0].paintedWidth
        let clear = row.length > 1
        for (let i = 1; i < row.length; i++) if (row[i] - row[i - 1] < width) clear = false
        check(clear, "telemetry: " + row.length + " of 32 clocks labelled, none touching")
      } },
    { name: "clock", wait: 700 },
    { name: "audio", wait: 700, status: "NO OUTPUT DEVICE" },
    { name: "bluetooth", wait: 700, status: "2 CONNECTED", setup: p => {
        p.adapter = fakeAdapter
        p.devices = [device("Sony WH-1000XM4", true, true), device("Keychron K3", true, true), device("Old mouse", false, true)]
    } },
    { name: "bluetooth-idle", plugin: "bluetooth", wait: 700, status: "NO DEVICES CONNECTED", setup: p => {
        p.adapter = fakeAdapter
        p.devices = [device("Old mouse", false, true)]
    } },
    { name: "network", wait: 700, status: "CONNECTED", late: p => {
        p.info = { type: "ethernet", iface: "enp0s1", ip: "192.168.2.2", prefix: "24", gateway: "192.168.2.1", speed: "2500", duplex: "full",
                   rx_bytes: "1000", tx_bytes: "1000", router_ping_ms: "1", internet_ping_ms: "14" }
    } },
    { name: "power", wait: 700, status: "ON BATTERY", setup: p => {
        p.fakeDevice = { isPresent: true, state: UPowerDeviceState.Discharging, percentage: 0.73, changeRate: 9.5, timeToEmpty: 18000, timeToFull: 0 }
        p.fakeOnBattery = true
        p.batteryInfo = { time: "5h 2m", energy: "68Wh", capacity: "99.8Wh", health: "92%", cycles: "210", power: "9.5W", limit: "75-80%" }
    } },
    { name: "power-charging", plugin: "power", wait: 700, status: "CHARGING", setup: p => {
        p.fakeDevice = { isPresent: true, state: UPowerDeviceState.Charging, percentage: 0.4, changeRate: 40, timeToEmpty: 0, timeToFull: 3600 }
        p.fakeOnBattery = false
    } },
    { name: "tailscale", wait: 700, status: "CONNECTED · 2 OF 3 ONLINE", setup: p => {
        const s = child(p, "statusText")
        s.installed = true
        s.running = true
        s.statusText = "Connected"
        s.selfName = "xps"
        s.selfDnsName = "xps.tail1234.ts.net"
        s.selfIp = "100.64.0.1"
        s.peers = [
          { HostName: "jetson", DNSName: "jetson.tail1234.ts.net.", TailscaleIPs: ["100.114.231.40"], Online: true, OS: "linux" },
          { HostName: "voron0", DNSName: "voron0.tail1234.ts.net.", TailscaleIPs: ["100.104.213.96"], Online: true, OS: "linux" },
          { HostName: "msi-x790i-with-a-long-machine-name", DNSName: "msi-x790i-with-a-long-machine-name.tail1234.ts.net.", TailscaleIPs: ["100.64.0.9"], Online: false, OS: "linux" }
        ]
    } },
    { name: "weather", wait: 700, status: "ANN ARBOR", plain: "ANN ARBOR", setup: p => { p.report = root.report } },
    { name: "weather-stale", plugin: "weather", wait: 700, status: "Update failed. This is the last report.", plain: "ANN ARBOR", setup: p => {
        p.report = root.report
        p.wttrGaveUp = true
    } },
    { name: "weather-down", plugin: "weather", wait: 700, status: "Can't reach the weather service.", plain: "Fetching forecast…", setup: p => { p.wttrGaveUp = true } },
  ]

  function walk(item, visit) {
    if (!item || !item.visible || item.opacity === 0) return
    visit(item)
    for (const c of item.children) walk(c, visit)
  }

  function inspect(s, panel) {
    const window = child(panel, "loadedContent")
    if (!window) {
      check(false, s.name + ": no KeyboardPanel found")
      return null
    }
    // KeyboardPanel's contentItem is its card's children, so climb to the window's item.
    let content = window.contentItem[0]
    while (content.parent) content = content.parent
    const texts = []
    walk(content, item => { if ("elide" in item && "truncated" in item && String(item.text) !== "") texts.push(item) })
    check(texts.length > 0, s.name + ": drew text")
    const origin = window.cardOrigin
    const left = origin.x, right = origin.x + window.contentWidth
    let small = [], outside = []
    for (const t of texts) {
      const p = t.mapToItem(content, 0, 0)
      if (t.font.pixelSize < 9) small.push(t.text + " " + t.font.pixelSize)
      // Painted extent. A right-aligned or centred label starts past its item's x.
      const x0 = p.x + (t.width - t.paintedWidth) * (t.horizontalAlignment === Text.AlignRight ? 1 : t.horizontalAlignment === Text.AlignHCenter ? 0.5 : 0)
      if (x0 < left - 1 || x0 + Math.min(t.paintedWidth, t.width > 0 && t.elide !== Text.ElideNone ? t.width : t.paintedWidth) > right + 1)
        outside.push(t.text + " [" + Math.round(x0) + "+" + Math.round(t.paintedWidth) + " in " + left + ".." + right + "]")
      if (t.truncated) console.log("NOTE " + s.name + " truncated: " + t.text + " (" + Math.round(t.implicitWidth) + " in " + Math.round(t.width) + ")")
    }
    if (holo) check(small.length === 0, s.name + ": no text under 9: " + small.join(", "))
    check(outside.length === 0, s.name + ": no text outside the card: " + outside.join(", "))
    if (s.status && holo) {
      const shown = texts.map(t => t.text)
      check(shown.indexOf(s.status) >= 0, s.name + ": shows \"" + s.status + "\", among " + JSON.stringify(shown.slice(0, 6)))
    } else if (s.status) {
      const shown = texts.map(t => t.text)
      if (s.plain) check(shown.indexOf(s.plain) >= 0, s.name + ": plain shows \"" + s.plain + "\"")
      else check(shown.indexOf(s.status) < 0, s.name + ": plain keeps stock's line, not \"" + s.status + "\"")
    }
    if (s.check) s.check(panel, texts)
    return { window: window, content: content }
  }

  // The window's own items have no QML engine to grab with, and a panel's frame is one of
  // them, so this photographs the private X screen, with a backdrop put under the panel
  // in its own window: over white the worst case, and over the wallpaper's median blue.
  Process {
    id: photo
    property var then: null
    onExited: then()
  }
  function shoot(s, got, done) {
    const under = Qt.createQmlObject('import QtQuick; Rectangle { anchors.fill: parent; z: -1000 }', got.window.contentItem[0].parent.parent.parent)
    const backdrops = [["white", "#FFFFFF"], ["wall", "#3C6DA6"]]
    const one = i => {
      if (i >= backdrops.length) {
        under.destroy()
        return done()
      }
      under.color = backdrops[i][1]
      wait(150, () => {
        photo.then = () => one(i + 1)
        photo.command = ["import", "-window", "root", out + "/" + theme + "-" + s.name + "-" + backdrops[i][0] + ".png"]
        photo.running = true
      })
    }
    one(0)
  }

  property int index: -1
  property var panel: null
  Timer { id: stepper; onTriggered: root.step() }
  function wait(ms, then) { stepper.interval = ms; root.pending = then; stepper.start() }
  property var pending: null
  function step() { const f = pending; pending = null; f() }

  function nextScenario() {
    index++
    if (index >= scenarios.length) {
      console.log("VERDICT " + (failures === 0 && passes > 0 ? "ok " + passes + " checks" : failures + " failing"))
      Qt.quit()
      return
    }
    const s = scenarios[index]
    const name = s.plugin || s.name
    const c = Qt.createComponent("file://" + plugins + "quokecola." + name + "/Panel.qml", Component.PreferSynchronous)
    if (c.status !== Component.Ready) {
      check(false, s.name + ": " + c.errorString())
      return nextScenario()
    }
    panel = c.createObject(slot, Object.assign({ bar: fakeBar, width: 26, height: 28 }, s.props || {}))
    if (!panel) {
      check(false, s.name + ": not created")
      return nextScenario()
    }
    if (s.setup) s.setup(panel)
    panel.open()
    wait(s.wait, () => {
      // State the panel's own failing poll would have wiped.
      if (s.late) s.late(panel)
      wait(s.late ? 100 : 0, () => {
      const got = inspect(s, panel)
      const done = () => {
        panel.close()
        wait(350, () => {
          panel.destroy()
          panel = null
          wait(50, nextScenario)
        })
      }
      if (!got || out === "") return done()
      shoot(s, got, done)
      })
    })
  }

  // Files nothing below opens, and the panels again by name, for a plain load error.
  readonly property var alsoCompile: ["quokecola.bar-rule/Service.qml", "quokecola.telemetry/Dial.qml", "quokecola.telemetry/Gpu.qml",
                                      "quokecola.tailscale/Service.qml", "quokecola.tailscale/TailscaleIcon.qml", "quokecola.weather/BarWidget.qml"]
  Timer {
    interval: 500
    running: true
    onTriggered: {
      for (const f of root.alsoCompile) {
        const c = Qt.createComponent("file://" + root.plugins + f, Component.PreferSynchronous)
        root.check(c.status === Component.Ready, f + " loads " + (c.status === Component.Ready ? "" : c.errorString()))
      }
      root.nextScenario()
    }
  }
}

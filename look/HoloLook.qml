import QtQuick
import Quickshell.Hyprland
import qs.Commons as Commons

// The holographic look (see quokecola.hud), while the theme it goes with is on.
// Under any other theme, `active` is false and every answer is the plain look's,
// and the theme can change while this is loaded.
Look {
  id: look

  // Zero-size: only asks whether the theme is on. Through a Loader, so without the
  // hud plugin it reads as off.
  Loader {
    id: theme
    source: Qt.resolvedUrl("../../quokecola.hud/holo/HoloFrame.qml")
  }
  active: theme.item ? theme.item.active : false

  function ink(fallback) { return look.active ? Commons.Color.foreground : fallback }
  function dim(fallback) { return look.active ? Commons.Color.pick("holo.text-dim", Qt.alpha(Commons.Color.foreground, 0.65)) : fallback }
  function base(fallback) { return look.active ? Commons.Color.background : fallback }
  function alert(fallback) { return look.active ? Commons.Color.urgent : fallback }
  function alertText(fallback) { return look.active ? Commons.Color.pick("holo.text-alert", Commons.Color.urgent) : fallback }
  // holo.text-dim is already as quiet as it can be and still read.
  function quiet(opacity) { return look.active ? 1 : opacity }

  function legible(px) { return look.active ? Math.max(px, Commons.Style.font.caption) : px }
  // Window titles and desktop numbers are what you find things by: a step above the
  // floor. Two terminals differ only by their titles.
  function primaryText(px) { return look.active ? Math.max(px, Commons.Style.font.body) : px }

  // Square: this theme has no circles but radial ones.
  function corner(fallback) { return look.active ? 0 : fallback }
  function captionEdge(picked) { return look.active && picked ? 1 : 0 }
  // Empty desktops were the brightest things on the page, as a tile is the one place
  // the page's overlay doesn't reach. Near the page now, the current one a step up.
  function tileWall(fallback, fresh) {
    if (!look.active) return fallback
    return fresh ? 0 : (fallback > 0.5 ? 0.35 : 0.2)
  }

  function panelAlpha(fallback) { return look.active ? Commons.Color.pickAlpha("holo.panel-alpha", fallback) : fallback }
  sectionGap: look.active ? 4 : 0
  headerTracking: look.active ? 2 : 0

  // A card is just its window over the page's overlay, the same picture as on the
  // desktop.
  plainCards: look.active
  hidesPlainDim: look.active
  // The desktop underneath needs a moment to catch up and draw, or its overlay
  // blinks as the overview leaves. The overview's page looks the same, so this
  // doesn't show.
  handbackDelay: look.active ? 48 : 0

  function ringWidth(flying, landing, picked) {
    return flying ? 0 : (look.active ? (landing ? 1 : 0) : (landing ? 3 : (picked ? 3 : 1)))
  }

  // The marks carry the title here, and the theme's titlebars are clear.
  cardTitlebars: !look.active

  // Only floating cards: tiled ones have the page's overlay behind them, and a
  // floating one has its own panel, below.
  function frostsCard(floating) { return !look.active || floating }

  pageLayer: look.active ? Qt.resolvedUrl("HoloPageLayer.qml") : ""
  cardOverlay: look.active ? Qt.resolvedUrl("HoloCardOverlay.qml") : ""
  function cardUnderlay(floating) {
    return look.active && floating ? Qt.resolvedUrl("HoloCardUnderlay.qml") : ""
  }

  // Tells quokecola.hud the overview or a desktop swipe has the screen: its window
  // marks go, and its overlay changes state unseen. Said under any theme, as the
  // hud decides what to do with it. By an event, because a plugin can't reach
  // another plugin's service.
  readonly property bool overviewUp: !!look.service && (look.service.goal > 0.001 || look.service.deskSlide)
  onOverviewUpChanged: Hyprland.dispatch('hl.dsp.event("holo,overview:' + (look.overviewUp ? 1 : 0) + '")')
}

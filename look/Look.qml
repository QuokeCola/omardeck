import Quickshell

// How the overview looks, as opposed to what it does. One seam, so a theme that
// wants a different look says so here and the overview's own files stay free of it.
//
// This is the plain look: every answer is what the overview does on its own, and
// the slots are empty. ActiveLook.qml says which look this tree uses. The overlay
// owns one instance, as `overlay.look`.
//
// A subclass overrides the properties by binding them and the functions by
// redeclaring them. Whatever it does has to turn back into exactly this when it is
// not active: the theme can change while the overview is loaded.
Scope {
  id: look

  // The overview's service, given by the overlay. May be null for a moment.
  property var service: null

  // Whether this look is doing anything right now.
  property bool active: false

  // ------------------------------------------------------------------ colours

  // Each takes the colour the plain look uses at that spot. Passed in rather than
  // named as roles: the off-whites differ slightly from one spot to another
  // (#F2EFE7, #F4F1E9, #F7F4EC), and collapsing them would change the plain look.
  function ink(fallback) { return fallback }      // text and bright outlines
  function dim(fallback) { return fallback }      // quieter text
  function base(fallback) { return fallback }     // what a shape is filled with
  function alert(fallback) { return fallback }    // what warns: fills, and text at body size
  function alertText(fallback) { return fallback } // what warns in small text
  // The opacity of text that `dim` has already quietened. Takes the plain look's.
  function quiet(opacity) { return opacity }

  // ------------------------------------------------------------------ type

  // Each takes the size the plain look uses at that spot.
  function legible(px) { return px }      // any text: how small it may go
  function primaryText(px) { return px }  // text that tells one desktop or window from another

  // ----------------------------------------------------------------- shapes

  // The radius of a shape that doesn't follow Hyprland's rounding: a pill or a round
  // button. Takes the plain look's.
  function corner(fallback) { return fallback }
  // The edge of a card's caption, so which one is picked doesn't rest on its colour.
  function captionEdge(picked) { return 0 }
  // How much wallpaper shows in a tile, which the plain look's opacity is passed in
  // for. `fresh` is the tile past the end, not a desktop yet.
  function tileWall(fallback, fresh) { return fallback }

  // ---------------------------------------------------------------- settings

  // The settings popout's fill over frosted glass. Takes the plain look's.
  function panelAlpha(fallback) { return fallback }
  // Added above a section of the settings popout, on top of its spacing.
  property int sectionGap: 0
  // Between the letters of a section's header.
  property real headerTracking: 0

  // ------------------------------------------------------------------- policy

  // Cards have no fill of their own: a card is just its window.
  property bool plainCards: false
  // No dim over the wallpaper when there is no wallpaper to show.
  property bool hidesPlainDim: false
  // How long the desktop gets to draw, in ms, between a desktop slide landing and
  // the overview going away. 0 hands back at once.
  property int handbackDelay: 0

  // The outline of a card: as a miniature in a tile, with a window about to be
  // dropped on it, under the pointer or selected, and otherwise.
  function ringWidth(flying, landing, picked) {
    return flying ? 0 : (landing ? 3 : (picked ? 3 : 1))
  }

  // Whether a card wears its window's titlebar, where Hyprland gives it one.
  property bool cardTitlebars: true

  // Whether a card is backed by the blur of what is behind it.
  function frostsCard(floating) { return true }

  // -------------------------------------------------------------------- slots

  // Files to draw at a few places in the overview, hosted by a LookSlot, which
  // hands the file its one required property. "" draws nothing.
  //
  // pageLayer       over the wallpaper, under the strip and cards, once per screen.
  //                 `required property var surface`
  // cardUnderlay    under a card's frame. `required property var card`
  // cardOverlay     over a card's frame. `required property var card`
  property url pageLayer: ""
  function cardUnderlay(floating) { return "" }
  property url cardOverlay: ""
}

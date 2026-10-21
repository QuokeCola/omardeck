> **In Omardeck:** this was the standalone `quokecola.dock` plugin. Configuration is described in the [main README](../README.md#the-dock).

# Dock

Omarchy shell service plugin (`quokecola.dock`): a bottom dock with pinned and
running apps.

- Pinned apps, then running apps that aren't pinned (after a divider)
- Up to three dots per app for open windows; the focused app's dots use the accent color
- Smart auto-hide: hides only while a window on that monitor's visible workspace
  covers the dock (or one is fullscreen); touch the bottom edge to reveal
- Name tooltips, launch bounce, optional hover magnification
- Left click: launch / focus (a window on another desktop: Aerial slides there,
  `slideToWindow: false` switches at once); with several windows, opens Aerial's overview on
  just that app's windows to pick one (`windowPicker: "cycle"` cycles instead). Middle click: new window.
  Right click: menu with the app's windows (and their workspaces), New Window,
  Keep in Dock / Unpin, Close

Enable by adding `{ "id": "quokecola.dock" }` to `plugins` in
`~/.config/omarchy/shell.json`, then `omarchy restart shell`.

## Config

`~/.config/omarchy/dock.json` (watched; Pin/Unpin rewrites `pinned`):

```json
{
  "pinned": ["org.gnome.Nautilus", "google-chrome", "foot"],
  "iconSize": 38,
  "height": 63,
  "magnify": 1,
  "autohide": "smart"
}
```

`autohide`: `smart`, `always` or `never`. `magnify`: hovered-icon scale, `1` turns it off. `height` sets the panel height
independently of `iconSize`.

The dock announces how much of each screen's bottom edge it covers on
Hyprland's event socket as `custom>>dock-state,<monitor>,<px>` (0 when hidden);
the Aerial fork lifts its desktop-swipe dots above it.

Blur: a Hyprland `layer_rule` for `omarchy-dock` with `blur = true` and
`blur_popups = true` (the right-click menu is an xdg popup).

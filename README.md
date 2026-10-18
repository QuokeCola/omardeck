# Dock

Omarchy shell service plugin (`quokecola.dock`): a bottom dock with pinned and
running apps.

- Pinned apps, then running apps that aren't pinned (after a divider)
- Up to three dots per app for open windows; the focused app's dots use the accent color
- Smart auto-hide: hides only while a window on that monitor's visible workspace
  covers the dock (or one is fullscreen); touch the bottom edge to reveal
- Hover magnification and name tooltips; launch bounce
- Left click: launch / focus / cycle windows. Middle click: new window.
  Right click: window list, New Window, Pin/Unpin, Close

Enable by adding `{ "id": "quokecola.dock" }` to `plugins` in
`~/.config/omarchy/shell.json`, then `omarchy restart shell`.

## Config

`~/.config/omarchy/dock.json` (watched; Pin/Unpin rewrites `pinned`):

```json
{
  "pinned": ["org.gnome.Nautilus", "google-chrome", "foot"],
  "iconSize": 44,
  "magnify": 1.45,
  "autohide": "smart"
}
```

`autohide`: `smart`, `always` or `never`.

Blur: add `omarchy-dock` to a Hyprland `layer_rule` with `blur = true`.

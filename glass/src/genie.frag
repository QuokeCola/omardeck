#version 300 es
// A window poured into its dock icon, and back out of it: the window as Hyprland
// has just drawn it, on a buffer the size of the monitor, drawn again bent.
//
// Each row between the window's top and the icon is as wide as the funnel is at
// that height: the window's own width up at the window, the icon's width down at
// the icon, an S-curve between. `bend` brings the funnel in from straight sides;
// `slide` carries the window down it, and what passes the icon is gone. With
// both at 0 every pixel reads itself, so the window is exactly as it was drawn.
precision highp float;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
uniform sampler2D tex;
uniform vec4 win;      // the window with its shadow: left, top, right, bottom, 0..1 of the monitor, y down
uniform vec2 sink;     // the icon's left and right
uniform float sinkY;   // where the icon is, down the monitor
uniform float bend;    // 0 straight sides .. 1 the full funnel
uniform float slide;   // 0 in place .. 1 the window's top has reached the icon
uniform float flipY;   // the buffer's rows run the other way

void main() {
    vec2 c = v_texcoord;
    if (flipY > 0.5)
        c.y = 1.0 - c.y;
    float span = max(sinkY - win.y, 0.0001);
    float t = clamp((c.y - win.y) / span, 0.0, 1.0);
    float s = t * t * (3.0 - 2.0 * t) * bend;
    float left = mix(win.x, sink.x, s);
    float right = mix(win.z, sink.y, s);
    float u = (c.x - left) / max(right - left, 0.0001);
    float v = (c.y - win.y - slide * span) / max(win.w - win.y, 0.0001);
    float inside = step(0.0, u) * step(u, 1.0) * step(0.0, v) * step(v, 1.0) * step(c.y, max(sinkY, win.w * (1.0 - step(0.0001, slide + bend))));
    vec2 src = vec2(mix(win.x, win.z, u), mix(win.y, win.w, v));
    // A maximized window's shadow runs off the monitor, and so off the buffer:
    // nothing was drawn there, and the edge is not to be smeared out to fill it.
    inside *= step(0.0, src.x) * step(src.x, 1.0) * step(0.0, src.y) * step(src.y, 1.0);
    if (flipY > 0.5)
        src.y = 1.0 - src.y;
    fragColor = texture(tex, src) * inside;
}

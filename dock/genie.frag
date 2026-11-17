#version 440
// A window poured into its dock icon, and back out of it.
//
// Drawn over the box that holds both the window and the icon below it. Each row
// of that box is as wide as the funnel is at that height: the window's own width
// up at the window, the icon's width down at the icon, an S-curve between. `bend`
// brings the funnel in from straight sides; `slide` carries the window down it,
// and what passes the bottom edge is gone into the icon.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 win;      // the window in this box: left, top, right, bottom, each 0..1
    vec2 sink;     // the icon's left and right, 0..1; it sits at the bottom edge
    float bend;    // 0 straight sides .. 1 the full funnel
    float slide;   // 0 in place .. 1 the window's top has reached the icon
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 c = qt_TexCoord0;
    float span = max(1.0 - win.y, 0.0001);
    float t = clamp((c.y - win.y) / span, 0.0, 1.0);
    float s = t * t * (3.0 - 2.0 * t) * bend;
    float left = mix(win.x, sink.x, s);
    float right = mix(win.z, sink.y, s);
    float u = (c.x - left) / max(right - left, 0.0001);
    float v = (c.y - win.y - slide * span) / max(win.w - win.y, 0.0001);
    // A pixel of soft edge at the sides, which otherwise stair-step along the curve.
    float soft = max(fwidth(u), 0.0001);
    float inside = smoothstep(0.0, soft, u) * smoothstep(0.0, soft, 1.0 - u)
                 * step(0.0, v) * step(v, 1.0);
    fragColor = texture(source, vec2(clamp(u, 0.0, 1.0), clamp(v, 0.0, 1.0))) * inside * qt_Opacity;
}

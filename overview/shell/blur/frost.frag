#version 440
// One card's share of the blurred screen: the part of it the card is over,
// cut to the card's rounded shape.
//
// With the liquidglass Hyprland plugin on, the compositor warps that blur into
// a lens at the window's rim, so the card does too: the same box-SDF warp,
// dispersion and rim light as the plugin's glass.frag, fed its settings, so
// the glass does not change as the window hands over to its card.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 area;       // where the card is, in the blurred texture's 0..1
    vec2 size;       // the card's size, in pixels
    float radius;    // its corner radius, in pixels

    float glass;      // 1 = liquid glass, 0 = plain frost
    float bezel;      // width of the refracting rim, px
    float refraction; // max displacement at the very edge, px (negative = outward)
    float dispersion; // 0..1, chromatic split of the displacement
    float specular;   // rim highlight strength
    vec2 lightDir;    // direction the highlight faces
    float glassBrightness;
    float saturation;
};
layout(binding = 1) uniform sampler2D source;

float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 uv = area.xy + qt_TexCoord0 * area.zw;
    vec2 p = (qt_TexCoord0 - 0.5) * size;
    vec2 half_ = size * 0.5;
    float d = sdRoundBox(p, half_, radius);
    float inside = clamp(0.5 - d, 0.0, 1.0);

    if (glass < 0.5) {
        fragColor = texture(source, uv) * inside * qt_Opacity;
        return;
    }

    // Normals from a box with at least `bezel` rounding, so square corners
    // still get a smooth, crease-free rim.
    float rn = min(max(radius, bezel), min(half_.x, half_.y));
    vec2 e = vec2(0.5, 0.0);
    vec2 grad = vec2(sdRoundBox(p + e.xy, half_, rn) - sdRoundBox(p - e.xy, half_, rn),
                     sdRoundBox(p + e.yx, half_, rn) - sdRoundBox(p - e.yx, half_, rn));
    vec2 n = length(grad) > 1e-5 ? normalize(grad) : vec2(0.0);

    // 0 at the rim, 1 once we're `bezel` px inside: steep at the edge, flat inside.
    float lip = 1.0 - clamp(-sdRoundBox(p, half_, rn) / max(bezel, 1.0), 0.0, 1.0);
    float mag = refraction * lip * lip * lip;

    // Sample toward the centre (magnifying lip), px to the texture's 0..1.
    vec2 off = -n * mag * area.zw / max(size, vec2(1.0));

    vec3 col;
    if (dispersion > 0.001) {
        col.r = texture(source, uv + off * (1.0 - dispersion)).r;
        col.g = texture(source, uv + off).g;
        col.b = texture(source, uv + off * (1.0 + dispersion)).b;
    } else {
        col = texture(source, uv + off).rgb;
    }

    float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(vec3(luma), col, saturation) * glassBrightness;

    // Rim light: strongest on edges facing the light, a softer bounce opposite,
    // and a thin bright line hugging the very edge.
    vec2 L = normalize(lightDir);
    float face = dot(n, L);
    col += specular * pow(lip, 4.0) * (max(face, 0.0) + 0.35 * max(-face, 0.0));
    col += specular * 0.5 * smoothstep(1.5, 0.0, -d) * (0.5 + 0.5 * abs(face));

    float a = inside * qt_Opacity;
    fragColor = vec4(clamp(col, 0.0, 1.0) * a, a);
}

#version 300 es
// Liquid glass: a 2D UV warp of Hyprland's already-blurred background.
// No ray tracing — the "lens" is a displacement along the edge normal with a
// cheap 1D falloff, plus optional dispersion and a rim highlight.

precision highp float;

in vec2 v_texcoord;          // monitor-space UV into the blurred background
uniform sampler2D tex;       // blurred background (whole monitor)

uniform vec2  uvTL;          // UV of the surface box corners
uniform vec2  uvBR;
uniform vec2  boxSize;       // surface box size, px
uniform float radius;        // corner radius, px
uniform float alpha;

uniform float bezel;         // width of the refracting rim, px
uniform float refraction;    // max displacement at the very edge, px (negative = outward)
uniform float dispersion;    // 0..1, chromatic split of the displacement
uniform float specular;      // rim highlight strength
uniform vec2  lightDir;      // direction the highlight faces
uniform float brightness;    // multiplier on the glass body
uniform float saturation;    // 1 = untouched

// Shape mode: for full-screen layers (menus, panels) the visible card is not the
// surface rect, so edges come from the surface's own alpha instead of a box SDF.
uniform int       shapeMode;
uniform sampler2D surf;      // the layer's own texture (RGBA)
uniform float     alphaCut;  // alpha that counts as "inside" (the layer's ignore_alpha)

layout(location = 0) out vec4 fragColor;

float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 uvSpan = uvBR - uvTL;
    vec2 local  = (v_texcoord - uvTL) / uvSpan * boxSize;  // px within box
    vec2 p      = local - boxSize * 0.5;
    vec2 half_  = boxSize * 0.5;

    float r    = min(radius, min(half_.x, half_.y));
    float d    = sdRoundBox(p, half_, r);                  // < 0 inside

    // Normals come from a box with at least `bezel` rounding so square
    // corners still get a smooth, crease-free rim.
    float rn   = min(max(r, bezel), min(half_.x, half_.y));
    float dn   = sdRoundBox(p, half_, rn);
    vec2  e    = vec2(0.5, 0.0);
    vec2  grad = vec2(sdRoundBox(p + e.xy, half_, rn) - sdRoundBox(p - e.xy, half_, rn),
                      sdRoundBox(p + e.yx, half_, rn) - sdRoundBox(p - e.yx, half_, rn));
    vec2  n    = length(grad) > 1e-5 ? normalize(grad) : vec2(0.0);

    // 0 at the rim, 1 once we're `bezel` px inside.
    float t    = clamp(-dn / max(bezel, 1.0), 0.0, 1.0);
    float lip  = 1.0 - t;

    if (shapeMode == 1) {
        // Coverage of a ring of taps ~ how deep inside the shape we are; the
        // alpha-weighted tap direction points inward, so -dir is the edge normal.
        vec2  suv  = local / boxSize;
        float cov  = 0.0;
        vec2  dir  = vec2(0.0);
        for (int i = 0; i < 12; i++) {
            float ang = float(i) * 0.5235988;            // 30 degrees
            vec2  u   = vec2(cos(ang), sin(ang));
            for (int k = 1; k <= 2; k++) {
                vec2  o = u * (bezel * 0.5 * float(k)) / boxSize;
                float a = smoothstep(alphaCut * 0.5, alphaCut + 0.05, texture(surf, suv + o).a);
                cov += a;
                dir += u * a;
            }
        }
        cov /= 24.0;
        n    = length(dir) > 1e-3 ? -normalize(dir) : vec2(0.0);
        lip  = clamp((1.0 - cov) * 2.0, 0.0, 1.0);       // cov 0.5 at the edge, 1 deep inside
        d    = -0.5 - (1.0 - lip) * bezel;               // feed the edge line / mask below
    }
    float mag  = refraction * lip * lip * lip;             // steep at the edge, flat inside

    // Sample toward the centre (magnifying lip). uvSpan/boxSize = UV per px.
    vec2 pxToUv = uvSpan / boxSize;
    vec2 off    = -n * mag * pxToUv;

    vec3 col;
    if (dispersion > 0.001) {
        col.r = texture(tex, v_texcoord + off * (1.0 - dispersion)).r;
        col.g = texture(tex, v_texcoord + off).g;
        col.b = texture(tex, v_texcoord + off * (1.0 + dispersion)).b;
    } else {
        col = texture(tex, v_texcoord + off).rgb;
    }

    float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(vec3(luma), col, saturation) * brightness;

    // Rim light: strongest on edges facing the light, a softer bounce opposite.
    vec2  L    = normalize(lightDir);
    float face = dot(n, L);
    float rim  = pow(lip, 4.0);
    col += specular * rim * (max(face, 0.0) + 0.35 * max(-face, 0.0));
    // thin bright line hugging the very edge
    col += specular * 0.5 * smoothstep(1.5, 0.0, -d) * (0.5 + 0.5 * abs(face));

    float a = alpha * clamp(0.5 - d, 0.0, 1.0);            // 1px AA on the outline
    fragColor = vec4(clamp(col, 0.0, 1.0) * a, a);
}

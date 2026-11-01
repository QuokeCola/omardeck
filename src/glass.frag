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

bool inShape(vec2 px) {
    if (any(lessThan(px, vec2(0.0))) || any(greaterThan(px, boxSize)))
        return false;
    return texture(surf, px / boxSize).a > alphaCut;
}

vec2 axis(int i) {
    return i == 0 ? vec2(1.0, 0.0) : i == 1 ? vec2(-1.0, 0.0) : i == 2 ? vec2(0.0, 1.0) : vec2(0.0, -1.0);
}

// Distance from p along u to the shape's edge, up to `reach`: coarse steps to
// find the crossing, then bisection to well under a pixel.
float edgeDist(vec2 p, vec2 u, float reach) {
    float step_ = reach / 8.0;
    float a = 0.0, b = reach;
    bool  found = false;
    for (int k = 1; k <= 8; k++) {
        if (!found && !inShape(p + u * (step_ * float(k)))) {
            a     = step_ * float(k - 1);
            b     = step_ * float(k);
            found = true;
        }
    }
    if (!found)
        return reach;
    for (int k = 0; k < 6; k++) {
        float m = 0.5 * (a + b);
        if (inShape(p + u * m))
            a = m;
        else
            b = m;
    }
    return 0.5 * (a + b);
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
        // The card is somewhere inside the surface: find its edges along the
        // four axes, rebuild its box, and give it the same lens as a window.
        // Edge distances vary continuously with position, so the warp does too
        // (fixed taps made it jump in steps, which showed as blocks).
        float reach = 2.0 * max(bezel, 1.0);
        bool  edgeNear = false;
        for (int i = 0; i < 4; i++)
            edgeNear = edgeNear || !inShape(local + axis(i) * bezel);
        if (!edgeNear) {
            // deep inside: flat glass, nothing to bend
            n   = vec2(0.0);
            lip = 0.0;
            d   = -bezel;
        } else {
            float ed[4];  // +x, -x, +y, -y
            for (int i = 0; i < 4; i++)
                ed[i] = edgeDist(local, axis(i), reach);
            vec2 lo    = local - vec2(ed[1], ed[3]);
            vec2 hi    = local + vec2(ed[0], ed[2]);
            vec2 cHalf = max((hi - lo) * 0.5, vec2(0.5));
            vec2 cp    = local - (lo + hi) * 0.5;
            float cr   = min(radius, min(cHalf.x, cHalf.y));
            float crn  = min(max(cr, bezel), min(cHalf.x, cHalf.y));
            vec2  g    = vec2(sdRoundBox(cp + e.xy, cHalf, crn) - sdRoundBox(cp - e.xy, cHalf, crn),
                              sdRoundBox(cp + e.yx, cHalf, crn) - sdRoundBox(cp - e.yx, cHalf, crn));
            n   = length(g) > 1e-5 ? normalize(g) : vec2(0.0);
            lip = 1.0 - clamp(-sdRoundBox(cp, cHalf, crn) / max(bezel, 1.0), 0.0, 1.0);
            d   = sdRoundBox(cp, cHalf, cr);
        }
    }
    float mag  = refraction * lip * lip * lip;             // steep at the edge, flat inside

    // Sample toward the centre (magnifying lip). uvSpan/boxSize = UV per px.
    vec2 pxToUv = uvSpan / boxSize;
    vec2 off    = -n * mag * pxToUv;

    // Hyprland blurs only under this surface (plus a few px); past its box the
    // blur buffer holds leftovers from other surfaces, which flicker. A thin
    // surface like the bar would otherwise sample right through itself.
    vec2 halfTexel = 0.5 / vec2(textureSize(tex, 0));
    vec2 uvLo = min(uvTL, uvBR) + halfTexel;
    vec2 uvHi = max(uvTL, uvBR) - halfTexel;

    vec3 col;
    if (dispersion > 0.001) {
        col.r = texture(tex, clamp(v_texcoord + off * (1.0 - dispersion), uvLo, uvHi)).r;
        col.g = texture(tex, clamp(v_texcoord + off, uvLo, uvHi)).g;
        col.b = texture(tex, clamp(v_texcoord + off * (1.0 + dispersion), uvLo, uvHi)).b;
    } else {
        col = texture(tex, clamp(v_texcoord + off, uvLo, uvHi)).rgb;
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

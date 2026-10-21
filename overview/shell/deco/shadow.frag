#version 440
// Hyprland 0.56 window shadow (shadow.glsl), for one card: the same falloff,
// in the same physical pixels, so a card wears exactly the shadow its window
// did. Sizes are in physical pixels of the shadow's box.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 color;          // straight, not premultiplied
    vec2 fullSize;
    vec2 topLeft;
    vec2 bottomRight;
    float radius;        // the window's outer rounding
    float range;
    float shadowPower;
    float roundingPower;
};

float pixAlphaRoundedDistance(float distanceToCorner, float r, float rng, float power) {
    if (distanceToCorner > r)
        return 0.0;
    if (distanceToCorner > r - rng)
        return pow((rng - (distanceToCorner - r + rng)) / rng, power);
    return 1.0;
}

float modifiedLength(vec2 a, float p) {
    return pow(pow(abs(a.x), p) + pow(abs(a.y), p), 1.0 / p);
}

// Hyprland colour-manages its shadow: the colour is premultiplied in linear
// light and brought back, not premultiplied as it stands. For a dark shadow
// that is markedly lighter, so done here the plain way the card wore a
// shadow about half as strong again as its window's, and it visibly lifted
// as the window took back over.
vec3 toLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
vec3 fromLinear(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
    float r = range + radius;
    vec2 pixCoord = fullSize * qt_TexCoord0;
    float a = color.a;
    bool done = false;

    if (pixCoord.x < topLeft.x) {
        if (pixCoord.y < topLeft.y) {
            a *= pixAlphaRoundedDistance(modifiedLength(pixCoord - topLeft, roundingPower), r, range, shadowPower);
            done = true;
        } else if (pixCoord.y > bottomRight.y) {
            a *= pixAlphaRoundedDistance(modifiedLength(pixCoord - vec2(topLeft.x, bottomRight.y), roundingPower), r, range, shadowPower);
            done = true;
        }
    } else if (pixCoord.x > bottomRight.x) {
        if (pixCoord.y < topLeft.y) {
            a *= pixAlphaRoundedDistance(modifiedLength(pixCoord - vec2(bottomRight.x, topLeft.y), roundingPower), r, range, shadowPower);
            done = true;
        } else if (pixCoord.y > bottomRight.y) {
            a *= pixAlphaRoundedDistance(modifiedLength(pixCoord - bottomRight, roundingPower), r, range, shadowPower);
            done = true;
        }
    }

    if (!done) {
        float smallest = min(min(pixCoord.y, fullSize.y - pixCoord.y), min(pixCoord.x, fullSize.x - pixCoord.x));
        if (smallest < range)
            a *= pow(smallest / range, shadowPower);
    }

    fragColor = vec4(fromLinear(toLinear(color.rgb) * a), a) * qt_Opacity;
}

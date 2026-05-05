// ============================================================
//  tonemapping.glsl — HDR to LDR tone mapping + colour grade
//  RealismShader for VulkanMod
//
//  Multiple tone mapping operators are provided so the shader
//  author can select the aesthetic that fits their look.
//  Colour grading is applied after tone mapping for the final
//  look of the image.
// ============================================================

#ifndef TONEMAPPING_GLSL
#define TONEMAPPING_GLSL

// ── sRGB / linear conversions ─────────────────────────────────────────────────

vec3 linearToSRGB(vec3 c) {
    // IEC 61966-2-1 piecewise function
    vec3 a = 12.92 * c;
    vec3 b = 1.055 * pow(clamp(c, 0.0, 1.0), vec3(1.0 / 2.4)) - 0.055;
    return mix(a, b, vec3(greaterThan(c, vec3(0.0031308))));
}

vec3 sRGBtoLinear(vec3 c) {
    vec3 a = c / 12.92;
    vec3 b = pow((c + 0.055) / 1.055, vec3(2.4));
    return mix(a, b, vec3(greaterThan(c, vec3(0.04045))));
}

// ── Exposure ─────────────────────────────────────────────────────────────────

// Apply exposure in EV stops (0 = unchanged, +1 = one stop brighter)
vec3 applyExposure(vec3 color, float ev) {
    return color * pow(2.0, ev);
}

// ── ACES Filmic Tone Mapping (S-curve) ───────────────────────────────────────
//
//  Stephen Hill's fit of the Academy Color Encoding System (ACES) RRT + ODT.
//  This is the gold standard used in AAA games.
//  Slightly compressed highlights, natural shadow rolloff.

vec3 RRTAndODTFit(vec3 v) {
    vec3 a = v * (v + 0.0245786) - 0.000090537;
    vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

// Full ACES path: linear → AP1 colourspace → RRT → ODT → sRGB
vec3 tonemapACES(vec3 color) {
    // Input transform: sRGB → AP1 (D65 adapted)
    const mat3 ACESInputMat = mat3(
        0.59719, 0.07600, 0.02840,
        0.35458, 0.90834, 0.13383,
        0.04823, 0.01566, 0.83777
    );
    // Output transform: AP1 → sRGB
    const mat3 ACESOutputMat = mat3(
         1.60475, -0.10208, -0.00327,
        -0.53108,  1.10813, -0.07276,
        -0.07367, -0.00605,  1.07602
    );
    color = ACESInputMat  * color;
    color = RRTAndODTFit(color);
    color = ACESOutputMat * color;
    return clamp(color, 0.0, 1.0);
}

// ── Reinhard Extended (Luminance) ─────────────────────────────────────────────
//
//  Maps white point explicitly. Good for scenes with a known maximum luminance.

float luminance(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 tonemapReinhardExtended(vec3 color, float whitePoint) {
    float lum    = luminance(color);
    float numL   = lum * (1.0 + lum / (whitePoint * whitePoint));
    float newLum = numL / (1.0 + lum);
    return color * (newLum / (lum + 1e-6));
}

// ── Lottes (soft rolloff, vivid) ─────────────────────────────────────────────

vec3 tonemapLottes(vec3 color) {
    const vec3 a     = vec3(1.6);
    const vec3 d     = vec3(0.977);
    const vec3 hdrMax= vec3(8.0);
    const vec3 midIn = vec3(0.18);
    const vec3 midOut= vec3(0.267);
    const vec3 b     = (-pow(midIn, a) + pow(hdrMax, a) * midOut)
                       / ((pow(hdrMax, a * d) - pow(midIn, a * d)) * midOut);
    const vec3 c2    = (pow(hdrMax, a * d) * pow(midIn, a) - pow(hdrMax, a) * pow(midIn, a * d) * midOut)
                       / ((pow(hdrMax, a * d) - pow(midIn, a * d)) * midOut);
    return pow(color, a) / (pow(color, a * d) * b + c2);
}

// ── Colour Grading ────────────────────────────────────────────────────────────
//
//  Three-way colour wheel: lift (shadows), gamma (midtones), gain (highlights).
//  This is the same model used in DaVinci Resolve's primaries.

vec3 colorGrade(vec3 c,
                vec3 lift,     // shadow colour offset  (default vec3(0.0))
                vec3 gamma,    // midtone power          (default vec3(1.0))
                vec3 gain) {   // highlight scale        (default vec3(1.0))
    c = c * gain + lift;
    c = pow(max(c, vec3(0.0)), 1.0 / gamma);
    return c;
}

// ── Saturation ────────────────────────────────────────────────────────────────
vec3 applySaturation(vec3 color, float saturation) {
    float lum = luminance(color);
    return mix(vec3(lum), color, saturation);
}

// ── Vignette ──────────────────────────────────────────────────────────────────
//
//  Darkens the image edges.  uv should be in [0,1] screen space.

float vignette(vec2 uv, float strength, float radius) {
    vec2 d = uv - 0.5;
    float dist = length(d) * 2.0;
    return 1.0 - smoothstep(radius, 1.0, dist) * strength;
}

// ── Chromatic Aberration ──────────────────────────────────────────────────────
//
//  Lateral chromatic aberration — pushes R and B channels slightly outward.
//  amount: 0.002–0.01 for subtle effect.

// (Applied in the post-processing fragment shader, not here.
//  Kept for documentation / template completeness.)

// ── Combined final output ─────────────────────────────────────────────────────
//
//  Applies the full pipeline:
//    exposure → tone map → colour grade → saturation → linearToSRGB
//
//  Tone operator:
//    0 = ACES   (recommended)
//    1 = Reinhard Extended
//    2 = Lottes

vec3 finalOutput(
    vec3  hdrColor,
    float exposure,
    int   toneOperator,
    vec3  lift,
    vec3  gamma,
    vec3  gain,
    float saturation
) {
    vec3 c = applyExposure(hdrColor, exposure);

    if      (toneOperator == 0) c = tonemapACES(c);
    else if (toneOperator == 1) c = tonemapReinhardExtended(c, 4.0);
    else                        c = tonemapLottes(c);

    c = colorGrade(c, lift, gamma, gain);
    c = applySaturation(c, saturation);
    c = linearToSRGB(c);
    return clamp(c, 0.0, 1.0);
}

#endif // TONEMAPPING_GLSL

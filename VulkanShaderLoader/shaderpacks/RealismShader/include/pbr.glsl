// ============================================================
//  pbr.glsl — Physically-Based Rendering functions
//  RealismShader for VulkanMod
//
//  Implements the Cook-Torrance microfacet specular BRDF and a
//  Lambert diffuse term, tuned for Minecraft's block surfaces.
//
//  References:
//    [1] Burley 2012 — "Physically Based Shading at Disney"
//    [2] Walter et al. 2007 — "Microfacet Models for Refraction"
//    [3] Karis 2013 — "Real Shading in Unreal Engine 4"
// ============================================================

#ifndef PBR_GLSL
#define PBR_GLSL

const float PI       = 3.14159265358979323846;
const float TWO_PI   = 6.28318530717958647692;
const float HALF_PI  = 1.57079632679489661923;
const float INV_PI   = 0.31830988618379067154;

// ── Fresnel (Schlick approximation) ───────────────────────────────────────────
//
//  F0  = reflectance at normal incidence.
//  For dielectrics (stone, wood, dirt) F0 ≈ vec3(0.04).
//  For metals F0 is the tinted albedo.

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    float t = 1.0 - clamp(cosTheta, 0.0, 1.0);
    float t2 = t * t;
    float t5 = t2 * t2 * t;
    return F0 + (1.0 - F0) * t5;
}

// Roughness-dependent Fresnel (Lagarde & de Rousiers 2014)
vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    vec3 oneMinusR = vec3(max(1.0 - roughness, F0.r),
                          max(1.0 - roughness, F0.g),
                          max(1.0 - roughness, F0.b));
    float t = 1.0 - clamp(cosTheta, 0.0, 1.0);
    float t2 = t * t;
    float t5 = t2 * t2 * t;
    return F0 + (oneMinusR - F0) * t5;
}

// ── GGX Normal Distribution Function ─────────────────────────────────────────
//
//  Trowbridge-Reitz NDF.  Returns the statistical distribution of microfacet
//  normals aligned with the half-vector H.

float distributionGGX(float NdotH, float roughness) {
    float a  = roughness * roughness;
    float a2 = a * a;
    float d  = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d + 1e-6);
}

// ── Smith GGX Geometry / Visibility ───────────────────────────────────────────
//
//  G_Schlick-GGX single term (one bounce direction).

float geometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) * 0.125;  // k = r²/8 for direct lighting
    return NdotV / (NdotV * (1.0 - k) + k + 1e-6);
}

// Smith combined geometry for both view and light directions.
float geometrySmith(float NdotV, float NdotL, float roughness) {
    return geometrySchlickGGX(NdotV, roughness)
         * geometrySchlickGGX(NdotL, roughness);
}

// ── Disney Diffuse ─────────────────────────────────────────────────────────────
//
//  Burley's retro-reflective correction to Lambertian diffuse.
//  Adds a subtle brightening at grazing angles that real surfaces show.

float disneyDiffuse(float NdotL, float NdotV, float LdotH, float roughness) {
    float FL  = pow(1.0 - NdotL, 5.0);
    float FV  = pow(1.0 - NdotV, 5.0);
    float RR  = 2.0 * roughness * LdotH * LdotH;
    float FD90 = 0.5 + RR;
    return INV_PI * (1.0 + (FD90 - 1.0) * FL) * (1.0 + (FD90 - 1.0) * FV);
}

// ── Subsurface Scattering Approximation ───────────────────────────────────────
//
//  A cheap wrap-lighting model that mimics forward-scattered light through
//  thin translucent geometry (leaves, grass, flower petals).
//
//  sssAmount — 0.0 = opaque, 1.0 = fully translucent

float subsurfaceScatter(float NdotL, float sssAmount) {
    // Wrap the lighting so back-lit surfaces still receive some light
    float wrappedNdotL = (NdotL + sssAmount) / (1.0 + sssAmount);
    return max(0.0, wrappedNdotL);
}

// ── Full PBR Evaluation ───────────────────────────────────────────────────────
//
//  Evaluates the Cook-Torrance BRDF for a single directional light.
//
//  albedo    — base colour (linear, sRGB decoded)
//  N         — surface normal (world space, normalised)
//  V         — direction to camera (normalised)
//  L         — direction to light (normalised)
//  lightCol  — light colour × irradiance
//  roughness — perceptual roughness [0,1]; stone ≈ 0.9, polished ≈ 0.3
//  metallic  — 0 = dielectric, 1 = metal
//  sssAmount — subsurface thickness [0,1]
//
//  Returns the lit output colour (NOT tone-mapped yet).

vec3 evaluatePBR(
    vec3  albedo,
    vec3  N,
    vec3  V,
    vec3  L,
    vec3  lightCol,
    float roughness,
    float metallic,
    float sssAmount
) {
    vec3  H      = normalize(V + L);
    float NdotL  = clamp(dot(N, L), 0.0, 1.0);
    float NdotV  = clamp(abs(dot(N, V)), 0.001, 1.0);
    float NdotH  = clamp(dot(N, H), 0.0, 1.0);
    float HdotV  = clamp(dot(H, V), 0.0, 1.0);
    float LdotH  = clamp(dot(L, H), 0.0, 1.0);

    // Subsurface-wrapped diffuse factor (overrides hard NdotL for translucent)
    float diffNdotL = mix(NdotL, subsurfaceScatter(NdotL, sssAmount), sssAmount);

    // F0: dielectrics → 0.04; metals → albedo
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 F  = fresnelSchlick(HdotV, F0);

    // Specular lobe (Cook-Torrance)
    float D  = distributionGGX(NdotH, roughness);
    float Gv = geometrySmith(NdotV, NdotL, roughness);
    vec3  specular = (D * Gv * F) / (4.0 * NdotV * max(NdotL, 0.001));

    // Diffuse lobe: energy conservation — only what Fresnel doesn't reflect
    vec3  kD = (1.0 - F) * (1.0 - metallic);
    float diff = disneyDiffuse(diffNdotL, NdotV, LdotH, roughness);
    vec3  diffuse = kD * albedo * diff;

    // Final: (diffuse + specular) × light colour × NdotL
    return (diffuse + specular) * lightCol * diffNdotL;
}

// ── Ambient (image-based lighting approximation) ───────────────────────────────
//
//  A simple spherical-harmonics-style ambient that separates sky, horizon,
//  and ground contributions based on the normal direction.

vec3 evaluateAmbient(
    vec3  albedo,
    vec3  N,
    vec3  skyZenith,    // colour of the zenith sky
    vec3  skyHorizon,   // colour of the horizon
    vec3  groundColor,  // approximate ground bounce
    float ambientOcclusion,   // 0 = fully occluded, 1 = fully exposed
    float metallic,
    float roughness
) {
    // Blend sky → horizon → ground based on normal Y component
    float upFactor   = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
    vec3  skyAmbient = mix(mix(groundColor, skyHorizon, upFactor * upFactor),
                           skyZenith,
                           smoothstep(0.4, 0.9, upFactor));

    // Rough approximation of specular ambient (reflectance × sky tint)
    vec3 F0         = mix(vec3(0.04), albedo, metallic);
    vec3 envSpecular = fresnelSchlickRoughness(max(N.y, 0.0), F0, roughness)
                     * skyAmbient * 0.25;

    vec3 kD      = (1.0 - F0) * (1.0 - metallic);
    vec3 diffuse = kD * albedo * skyAmbient * INV_PI;

    return (diffuse + envSpecular) * ambientOcclusion;
}

#endif // PBR_GLSL

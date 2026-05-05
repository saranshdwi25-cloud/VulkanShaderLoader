#version 450
// ============================================================
//  terrain.fsh — RealismShader fragment shader for VulkanMod
//
//  Full PBR lighting pipeline:
//    1. Reconstruct flat face normal via screen-space derivatives
//    2. Infer PBR parameters (roughness, metallic, SSS) from vertex
//       colour and texture brightness
//    3. Sun/moon direct lighting (GGX specular + Disney diffuse)
//    4. Ambient term from analytic sky model (Rayleigh/Mie)
//    5. Subsurface scattering for foliage
//    6. Volumetric-style depth cueing / fog
//    7. ACES filmic tone mapping
//    8. Colour grade + vignette
//
//  No shadow map is required — lighting uses the existing MC
//  lightmap for occlusion, plus the reconstructed normals for
//  directional highlights.
// ============================================================

#include "pbr.glsl"
#include "atmosphere.glsl"
#include "tonemapping.glsl"
#include "fog.glsl"
#include "light.glsl"

// ── VulkanMod standard UBOs ───────────────────────────────────────────────────

layout(binding = 0) uniform FrameUBO {
    mat4 MVP;
    int  CurrentTime;
};

layout(binding = 1) uniform FogUBO {
    vec4  FogColor;
    float FogEnvironmentalStart;
    float FogEnvironmentalEnd;
    float FogRenderDistanceStart;
    float FogRenderDistanceEnd;
    float FogSkyEnd;
    float FogCloudsEnd;
    float AlphaCutout;
    ivec2 TextureSize;
    vec2  TexelSize;
    int   UseRgss;
};

layout(binding = 3) uniform sampler2D Sampler0;  // Block atlas

// ── Varyings from vertex shader ───────────────────────────────────────────────

layout(location = 0)  in vec4  v_VertexColor;
layout(location = 1)  in vec2  v_TexCoord;
layout(location = 2)  in float v_SphericalDist;
layout(location = 3)  in float v_CylindricalDist;
layout(location = 4)  in flat float v_FadeFactor;
layout(location = 5)  in vec3  v_WorldPos;
layout(location = 6)  in float v_TimeNorm;
layout(location = 7)  in float v_Waving;

layout(location = 0) out vec4 fragColor;

// ── Texture sampling helpers (from VulkanMod's terrain.fsh) ──────────────────

vec4 sampleNearest(sampler2D src, vec2 uv, vec2 pixelSize, vec2 du, vec2 dv, vec2 tss) {
    vec2 uvTexelCoords = uv / pixelSize;
    vec2 texelCenter   = round(uvTexelCoords) - 0.5;
    vec2 texelOffset   = uvTexelCoords - texelCenter;
    texelOffset = (texelOffset - 0.5) * pixelSize / tss + 0.5;
    texelOffset = clamp(texelOffset, 0.0, 1.0);
    uv = (texelCenter + texelOffset) * pixelSize;
    return textureGrad(src, uv, du, dv);
}

vec4 sampleBlock(sampler2D src, vec2 uv) {
    vec2 du  = dFdx(uv);
    vec2 dv  = dFdy(uv);
    vec2 tss = sqrt(du * du + dv * dv);
    return sampleNearest(src, uv, TexelSize, du, dv, tss);
}

// ── Normal reconstruction ─────────────────────────────────────────────────────
//
//  Uses screen-space derivatives of the world position to reconstruct the flat
//  geometric normal of the current polygon face.
//  This is accurate for flat block surfaces (the vast majority of geometry) and
//  gives correct specular highlights without any per-vertex normal data.

vec3 reconstructNormal() {
    vec3 dX = dFdx(v_WorldPos);
    vec3 dY = dFdy(v_WorldPos);
    return normalize(cross(dX, dY));
}

// ── PBR parameter estimation ─────────────────────────────────────────────────
//
//  Minecraft's block textures don't have roughness/metallic maps.  We derive
//  plausible values from the texture brightness and vertex color hints.
//
//  Conventions used:
//    • Bright (snow, sand, quartz) → low roughness for slight specular
//    • Dark (netherrack, obsidian) → moderate roughness, slight metallic hint
//    • Vegetation (green vertex tint) → high roughness, SSS enabled

struct PBRParams {
    float roughness;
    float metallic;
    float sssAmount;
    float ao;          // ambient-occlusion hint from lightmap (0 = dark, 1 = bright)
};

PBRParams estimatePBR(vec4 albedo, vec4 vertexColor) {
    PBRParams p;

    // Luminance of the surface texture
    float texLum   = dot(albedo.rgb, vec3(0.2126, 0.7152, 0.0722));
    float vertLum  = dot(vertexColor.rgb, vec3(0.2126, 0.7152, 0.0722));

    // Vegetation detection: green channel dominance
    bool isVegetation = (vertexColor.g > 0.5 && vertexColor.g > vertexColor.r * 1.1);

    // Base roughness: bright surfaces more specular, dark rough
    p.roughness = mix(0.92, 0.45, smoothstep(0.15, 0.85, texLum));

    // Stone/ore metallic hint from low-saturation dark textures
    float texSat = length(albedo.rgb - vec3(texLum));
    p.metallic = 0.0;  // Minecraft blocks: nearly always dielectric

    // SSS: only for vegetation
    p.sssAmount = isVegetation ? 0.55 : 0.0;

    // Make vegetation quite rough (leaves scatter light broadly)
    if (isVegetation) p.roughness = mix(p.roughness, 0.95, 0.7);

    // Ambient occlusion from lightmap brightness
    // (dark areas from block AO will have lower vertex light)
    p.ao = clamp(vertLum * 1.3, 0.05, 1.0);

    return p;
}

// ── Sky sampling ─────────────────────────────────────────────────────────────
//
//  Computes the hemisphere-averaged sky colour for ambient lighting.

vec3 getSkyAmbient(vec3 N, vec3 sunDir, vec3 sunColor, float timeNorm) {
    // Sample sky in the normal direction and two perpendicular directions
    // to approximate the cosine-weighted irradiance from the sky hemisphere.
    vec3 skyN = computeSkyColor(N,                  sunDir, sunColor, 0.0);
    vec3 skyU = computeSkyColor(vec3(0.0, 1.0, 0.0), sunDir, sunColor, 0.0);
    vec3 skyH = computeSkyColor(normalize(N * vec3(1,0,1) + vec3(0,0.01,0)), sunDir, sunColor, 0.0);

    // Weight: upward normals see more sky, downward see ground bounce
    float upFactor = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
    vec3  ambient  = mix(skyH * 0.3, skyN, upFactor * upFactor);

    // Scale down — sky radiance is HDR and needs to match our exposure
    return ambient * 0.012;
}

// ── Depth cueing ──────────────────────────────────────────────────────────────
//
//  Adds a subtle atmospheric depth effect that's physically separate from
//  the standard Minecraft fog (which we keep for correct distance fade).

vec3 applyDepthCueing(vec3 color, float dist, vec3 horizonColor, float timeNorm) {
    float sunHeight = -cos((timeNorm - 0.25) * TWO_PI);
    float dayFactor = smoothstep(-0.1, 0.2, sunHeight);

    // Near-horizon atmospheric depth, starts much closer than Minecraft fog
    float depthStart = FogRenderDistanceStart * 0.6;
    float depthEnd   = FogRenderDistanceStart * 0.9;
    float depthFactor = smoothstep(depthStart, depthEnd, dist);

    return mix(color, horizonColor * dayFactor + color * (1.0 - dayFactor), depthFactor * 0.35);
}

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
    // --- 1. Sample albedo ---
    vec4 texColor = sampleBlock(Sampler0, v_TexCoord);

    // Alpha test
    vec4 rawColor = texColor * v_VertexColor;
    if (rawColor.a < AlphaCutout) discard;

    // Decode to linear (VulkanMod textures are in sRGB)
    vec3 albedoLinear = sRGBtoLinear(rawColor.rgb);

    // --- 2. Reconstruct geometric normal ---
    vec3 N = reconstructNormal();

    // Face-flip: ensure normal points toward the camera
    vec3 viewDir = normalize(-v_WorldPos);
    if (dot(N, viewDir) < 0.0) N = -N;

    // --- 3. Time & sun/moon setup ---
    float timeNorm = v_TimeNorm;
    float sunHeight = -cos((timeNorm - 0.25) * TWO_PI);
    bool  isDay     = sunHeight > -0.1;

    vec3 sunDir     = sunDirectionFromTime(timeNorm);
    vec3 moonDir    = moonDirectionFromTime(timeNorm);
    vec3 sunColor   = sunColorFromTime(timeNorm);
    vec3 moonColor  = vec3(0.18, 0.22, 0.32) * 0.15;  // Cool, dim moon

    // --- 4. PBR parameters ---
    PBRParams pbr = estimatePBR(texColor, v_VertexColor);

    // Dampen roughness for waving foliage (wet tips look shinier)
    pbr.roughness = mix(pbr.roughness, pbr.roughness * 0.7, v_Waving * 0.3);

    // --- 5. Sun direct lighting ---
    float sunVisibility = smoothstep(-0.05, 0.1, sunHeight);
    vec3  directSun     = vec3(0.0);
    if (sunVisibility > 0.001) {
        // Sun irradiance scale (physically ~120 klux at noon → scaled to HDR range)
        float irradiance = sunVisibility * 3.2;
        directSun = evaluatePBR(
            albedoLinear, N, viewDir, sunDir,
            sunColor * irradiance,
            pbr.roughness, pbr.metallic, pbr.sssAmount
        );
    }

    // --- 6. Moon direct lighting (night) ---
    float moonVisibility = smoothstep(0.05, -0.1, sunHeight);
    vec3  directMoon     = vec3(0.0);
    if (moonVisibility > 0.001) {
        directMoon = evaluatePBR(
            albedoLinear, N, viewDir, moonDir,
            moonColor * moonVisibility,
            pbr.roughness * 1.1, 0.0, 0.0
        );
    }

    // --- 7. Ambient (sky irradiance) ---
    vec3 skyZenith  = computeSkyColor(vec3(0,1,0), sunDir, sunColor, 0.0) * 0.015;
    vec3 skyHorizon = horizonSkyColor(timeNorm) * 0.008;
    vec3 groundBounce = skyHorizon * 0.3 + sunColor * sunVisibility * 0.04;

    vec3 ambient = evaluateAmbient(
        albedoLinear, N,
        skyZenith, skyHorizon, groundBounce,
        pbr.ao,
        pbr.metallic, pbr.roughness
    );

    // --- 8. Night ambient (starlight fill) ---
    float nightAmbientStrength = smoothstep(0.05, -0.15, sunHeight);
    vec3  nightAmbient = albedoLinear * vec3(0.04, 0.05, 0.09) * nightAmbientStrength;

    // --- 9. Combined HDR colour ---
    vec3 hdrColor = directSun + directMoon + ambient + nightAmbient;

    // --- 10. Fog fade (original VulkanMod fade factor from section distance) ---
    // Apply face-level fog blend — start blending to FogColor at horizon
    hdrColor = mix(
        sRGBtoLinear(FogColor.rgb) * 0.5,
        hdrColor,
        v_FadeFactor
    );

    // --- 11. Atmospheric fog (replaces vanilla linear fog for HDR version) ---
    // Blend to HDR horizon sky colour so fog looks physically correct
    vec3  horizonFogColor = horizonSkyColor(timeNorm) * sunColor * 0.8;
    float fogValue = total_fog_value(
        v_SphericalDist, v_CylindricalDist,
        FogEnvironmentalStart, FogEnvironmentalEnd,
        FogRenderDistanceStart, FogRenderDistanceEnd
    );
    hdrColor = mix(hdrColor, horizonFogColor, clamp(fogValue, 0.0, 1.0) * FogColor.a);

    // --- 12. Depth cueing (subtle pre-fog atmospheric haze) ---
    hdrColor = applyDepthCueing(hdrColor, v_SphericalDist, horizonFogColor, timeNorm);

    // --- 13. ACES Tone mapping + colour grade ---
    //  Exposure: compensate for the HDR scale we're working at
    //  Shadows: very slight warm lift for Minecraft's golden feel
    //  Saturation: 1.15 for punchy, vibrant look (classic SEUS aesthetic)
    vec3 ldrColor = finalOutput(
        hdrColor,
        0.45,                       // EV exposure
        0,                          // ACES filmic
        vec3(0.005, 0.003, 0.002),  // Shadow lift (warm)
        vec3(1.02, 1.0, 0.98),      // Midtone gamma (very slight warm)
        vec3(1.0),                  // Highlight gain
        1.18                        // Saturation
    );

    fragColor = vec4(ldrColor, rawColor.a);
}

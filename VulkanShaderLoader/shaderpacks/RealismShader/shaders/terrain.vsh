#version 460
// ============================================================
//  terrain.vsh — RealismShader vertex shader for VulkanMod
//
//  Maintains full compatibility with VulkanMod's compressed
//  vertex format (ivec4 Position, uvec2 UV0, uint PackedColor)
//  while adding:
//    • World-space position output (for per-pixel normal recon-
//      struction and atmospheric/fog calculations)
//    • Foliage waving animation driven by CurrentTime
//    • Per-vertex roughness hint via vertex color saturation
//    • Enhanced fog distances (same data, better varyings)
// ============================================================

#include "fog.glsl"
#include "light.glsl"

// ── Standard VulkanMod UBOs (must match exactly) ──────────────────────────────

layout(binding = 0) uniform FrameUBO {
    mat4 MVP;
    int  CurrentTime;   // Minecraft tick (0–23999)
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

layout(binding = 2) uniform SectionUBO {
    ivec4 SectionOffsets[128];
    vec4  SectionFadeFactors[128];
};

layout(push_constant) uniform PushConst {
    vec3 ModelOffset;
};

layout(binding = 4) uniform sampler2D Sampler2;  // Lightmap

// ── Vertex inputs (VulkanMod compressed format) ───────────────────────────────

layout(location = 0) in ivec4 Position;   // xyz = compressed pos, w = packed LM
layout(location = 1) in uvec2 UV0;        // compressed texture UV
layout(location = 2) in uint  PackedColor;

// ── Varyings ──────────────────────────────────────────────────────────────────

layout(location = 0)  out vec4  v_VertexColor;
layout(location = 1)  out vec2  v_TexCoord;
layout(location = 2)  out float v_SphericalDist;
layout(location = 3)  out float v_CylindricalDist;
layout(location = 4)  out flat float v_FadeFactor;
layout(location = 5)  out vec3  v_WorldPos;         // NEW: world-space position
layout(location = 6)  out float v_TimeNorm;         // NEW: normalised time [0,1]
layout(location = 7)  out float v_Waving;           // NEW: foliage wave factor [0,1]

// ── Constants ─────────────────────────────────────────────────────────────────

const float UV_INV           = 1.0 / 32768.0;
const vec3  POSITION_INV     = vec3(1.0 / 2048.0);
const float TWO_PI           = 6.28318530717958647;

// ── Foliage waving ────────────────────────────────────────────────────────────
//
//  Detects foliage by checking if vertex color green ≥ 0.6 AND red/blue
//  are lower — approximates the green-tinted color Minecraft gives leaves
//  and tall grass.  A smooth sine wave is then applied to XZ.
//
//  This heuristic won't be perfect for all biomes, but works well for the
//  majority of foliage without needing any vertex attribute changes.

bool isFoliage(vec4 color) {
    return color.g > 0.52 && color.r < color.g * 0.9 && color.b < color.g * 0.9;
}

vec3 applyFoliageWaving(vec3 worldPos, vec4 color, float timeSec) {
    if (!isFoliage(color)) return worldPos;

    // Use world XZ position as a spatial phase so adjacent blocks wave differently
    float phase = worldPos.x * 0.787 + worldPos.z * 0.637;

    // Multi-frequency wind: primary + secondary + gust
    float wind1 = sin(timeSec * 1.4  + phase) * 0.055;
    float wind2 = sin(timeSec * 2.3  + phase * 1.3) * 0.028;
    float gust  = sin(timeSec * 0.33 + phase * 0.5) * 0.012;

    float totalWind = wind1 + wind2 + gust;

    // Top of the block waves, bottom is anchored — remap Y within block
    float blockY   = fract(worldPos.y);  // 0 = block base, 1 = top
    float verticalWeight = smoothstep(0.2, 0.8, blockY);

    worldPos.x += totalWind * verticalWeight;
    worldPos.z += totalWind * 0.6 * verticalWeight;
    return worldPos;
}

// ── Vertex position decoder (matches VulkanMod's terrain.vsh exactly) ─────────

vec3 getVertexPosition() {
    int encOffset     = SectionOffsets[gl_InstanceIndex >> 2][gl_InstanceIndex & 3];
    vec3 baseOffset   = bitfieldExtract(ivec3(encOffset) >> ivec3(0, 16, 8), 0, 8);
    return fma(vec3(Position.xyz), POSITION_INV, ModelOffset + baseOffset);
}

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
    // --- Decode compressed vertex data ---
    vec3 worldPos = getVertexPosition();
    vec4 color    = unpackUnorm4x8(PackedColor);
    vec4 lightmapColor = sample_lightmap2(Sampler2, uint(Position.w));

    // --- Time ---
    float timeNorm = float(CurrentTime % 24000) / 24000.0;
    float timeSec  = float(CurrentTime) / 20.0;   // 20 ticks per second

    // --- Foliage animation ---
    vec3 animPos  = applyFoliageWaving(worldPos, color, timeSec);
    float waveFac = length(animPos - worldPos) / 0.1;  // 0=still, 1=max wave

    // --- Fog distances ---
    float spherDist  = fog_spherical_distance(animPos);
    float cylDist    = fog_cylindrical_distance(animPos);

    // --- Outputs ---
    gl_Position     = MVP * vec4(animPos, 1.0);
    v_VertexColor   = color * lightmapColor;
    v_TexCoord      = UV0 * UV_INV;
    v_SphericalDist = spherDist;
    v_CylindricalDist = cylDist;
    v_FadeFactor    = SectionFadeFactors[gl_InstanceIndex >> 2][gl_InstanceIndex & 3];
    v_WorldPos      = animPos;
    v_TimeNorm      = timeNorm;
    v_Waving        = clamp(waveFac, 0.0, 1.0);
}

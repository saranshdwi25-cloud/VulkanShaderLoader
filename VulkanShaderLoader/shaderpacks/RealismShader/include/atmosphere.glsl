// ============================================================
//  atmosphere.glsl — Analytic atmospheric scattering
//  RealismShader for VulkanMod
//
//  A single-scattering sky model based on Rayleigh and Mie theory.
//  Produces realistic blue sky, orange sunsets, and milky-way-style
//  night-time darkening — all computed procedurally from the sun angle
//  and the Minecraft CurrentTime tick counter.
//
//  Primary reference: Nishita et al. 1993, adapted for real-time use.
//  Simplified single-scattering formulation (no raymarching needed).
// ============================================================

#ifndef ATMOSPHERE_GLSL
#define ATMOSPHERE_GLSL

// ── Physical constants ─────────────────────────────────────────────────────────
const vec3 RAYLEIGH_COEFF = vec3(5.8e-3, 1.35e-2, 3.31e-2); // λ^-4 scatter (RGB)
const float MIE_COEFF     = 2.1e-3;                          // aerosol scatter
const float MIE_G         = 0.758;                            // Henyey-Greenstein g

const float EARTH_RADIUS  = 6371000.0;
const float ATMO_RADIUS   = 6471000.0;
const float H_RAYLEIGH    = 8000.0;    // Rayleigh scale height (m)
const float H_MIE         = 1200.0;   // Mie scale height (m)

// ── Sun disk ───────────────────────────────────────────────────────────────────

// Sharp sun disk, returns 1.0 at the centre fading to 0 at the edge.
// angularSize ≈ 0.0093 rad (0.53°) for the real sun; increase for softer glow.
float sunDisk(vec3 rayDir, vec3 sunDir, float angularSize) {
    float cosAngle = dot(rayDir, sunDir);
    return smoothstep(cos(angularSize), cos(angularSize * 0.5), cosAngle);
}

// Bloom halo around the sun — larger angular spread, lower intensity.
float sunHalo(vec3 rayDir, vec3 sunDir) {
    float cosAngle = dot(rayDir, sunDir);
    return pow(max(0.0, cosAngle), 8.0) * 0.18;
}

// ── Henyey-Greenstein Mie phase ───────────────────────────────────────────────
float phaseHG(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5) + 1e-6);
}

// Rayleigh phase function
float phaseRayleigh(float cosTheta) {
    return (3.0 / (16.0 * PI)) * (1.0 + cosTheta * cosTheta);
}

// ── Atmosphere optical depth ───────────────────────────────────────────────────
//
//  Approximates the integral of density along a ray from ground to sky.
//  Uses the closed-form Chapman function for efficiency.
//
//  height — altitude above sea level in metres
//  cosZenith — cosine of the angle from zenith (clamped to > 0)

float opticalDepthRayleigh(float height, float cosZenith) {
    return H_RAYLEIGH * exp(-height / H_RAYLEIGH) / max(cosZenith, 0.035);
}

float opticalDepthMie(float height, float cosZenith) {
    return H_MIE * exp(-height / H_MIE) / max(cosZenith, 0.035);
}

// ── Transmittance ─────────────────────────────────────────────────────────────
//
//  How much light survives along a path of given optical depth.

vec3 transmittanceRayleigh(float optDepth) {
    return exp(-RAYLEIGH_COEFF * optDepth);
}

float transmittanceMie(float optDepth) {
    return exp(-MIE_COEFF * optDepth * 1.1);  // ×1.1 for absorption correction
}

// ── Main sky colour ────────────────────────────────────────────────────────────
//
//  Evaluates in-scattered sky colour along direction rayDir, given a sun
//  direction sunDir.
//
//  rayDir   — normalised view direction (looking up = +Y)
//  sunDir   — normalised direction toward the sun
//  sunColor — sun irradiance (use vec3(1.0) for neutral white or warm yellow)
//  altitude — viewer altitude above terrain in metres (0 for ground level)
//
//  Returns a HDR sky radiance value (needs tone mapping before display).

vec3 computeSkyColor(vec3 rayDir, vec3 sunDir, vec3 sunColor, float altitude) {
    float cosZenith = max(rayDir.y, 0.01);
    float cosSun    = max(sunDir.y, -0.2);
    float cosTheta  = dot(rayDir, sunDir);

    // Optical depths along view and sun paths
    float odRayView = opticalDepthRayleigh(altitude, cosZenith);
    float odMieView = opticalDepthMie    (altitude, cosZenith);
    float odRaySun  = opticalDepthRayleigh(altitude, max(cosSun, 0.05));
    float odMieSun  = opticalDepthMie    (altitude, max(cosSun, 0.05));

    // Phase functions
    float phaseR = phaseRayleigh(cosTheta);
    float phaseM = phaseHG(cosTheta, MIE_G);

    // Combined transmittance along view + sun paths
    vec3  transR = transmittanceRayleigh(odRayView + odRaySun);
    float transM = transmittanceMie(odMieView + odMieSun);

    vec3  inscatterR = RAYLEIGH_COEFF * phaseR * transR * odRayView;
    float inscatterM = MIE_COEFF      * phaseM * transM * odMieView;

    vec3 sky = (inscatterR + vec3(inscatterM)) * sunColor;

    // Horizon darkening during sunset/sunrise
    float horizonFactor = 1.0 - smoothstep(-0.05, 0.15, rayDir.y);
    sky *= mix(1.0, 0.55, horizonFactor * (1.0 - max(cosSun, 0.0)));

    return sky;
}

// ── Convenience: sky + sun disk ───────────────────────────────────────────────
vec3 computeFullSky(vec3 rayDir, vec3 sunDir, vec3 sunColor, float altitude) {
    vec3 sky  = computeSkyColor(rayDir, sunDir, sunColor, altitude);
    float sun = sunDisk(rayDir, sunDir, 0.0093);       // actual sun angular size
    float halo = sunHalo(rayDir, sunDir);
    return sky + sunColor * (sun * 80.0 + halo);       // HDR sun contribution
}

// ── Time-of-day utilities ─────────────────────────────────────────────────────
//
//  Maps Minecraft's CurrentTime tick to physically-motivated sun/moon angles.
//
//  Minecraft time:
//    0    = dawn  (6:00 AM)
//    6000 = noon  (12:00 PM)
//    12000= dusk  (6:00 PM)
//    18000= midnight (12:00 AM)
//    24000= dawn again

// Returns normalised time 0-1 where 0 = dawn, 0.25 = noon, 0.5 = dusk, 0.75 = midnight
float minecraftTimeNorm(int ticks) {
    return float(ticks % 24000) / 24000.0;
}

// Sun direction in world space (+Y = up).
// At dawn the sun is on the horizon; at noon it's overhead.
vec3 sunDirectionFromTime(float timeNorm) {
    float angle = (timeNorm - 0.25) * TWO_PI;  // 0.25 offset = noon at top
    return normalize(vec3(sin(angle), -cos(angle), 0.15));
}

vec3 moonDirectionFromTime(float timeNorm) {
    // Moon is opposite the sun
    return -sunDirectionFromTime(timeNorm);
}

// Per-channel sun colour — warm at sunrise/sunset, white at noon, dark at night.
vec3 sunColorFromTime(float timeNorm) {
    float sunHeight = -cos((timeNorm - 0.25) * TWO_PI);  // -1 = below, +1 = above
    float dayFactor = smoothstep(-0.1, 0.15, sunHeight);

    // Sunrise/sunset orange tint
    float horizonFactor = 1.0 - abs(sunHeight) * 2.0;
    horizonFactor = clamp(horizonFactor, 0.0, 1.0);
    horizonFactor = pow(horizonFactor, 3.0);

    vec3 noonColor    = vec3(1.0, 0.97, 0.92);              // Slightly warm white
    vec3 sunsetColor  = vec3(1.0, 0.45, 0.12);              // Deep orange
    vec3 nightColor   = vec3(0.06, 0.08, 0.18) * 0.12;     // Moonlit blue-black

    vec3 dayColor = mix(noonColor, sunsetColor, horizonFactor * 2.0);
    return mix(nightColor, dayColor, dayFactor);
}

// Ambient sky colour at the horizon — blends into fog.
vec3 horizonSkyColor(float timeNorm) {
    float sunHeight = -cos((timeNorm - 0.25) * TWO_PI);
    float dayFactor = smoothstep(-0.15, 0.2, sunHeight);

    vec3 dayHorizon   = vec3(0.68, 0.85, 1.0);
    vec3 sunsetHorizon = vec3(0.95, 0.52, 0.22);
    vec3 nightHorizon = vec3(0.03, 0.04, 0.12);

    float t = smoothstep(-0.05, 0.15, sunHeight) - smoothstep(0.15, 0.35, sunHeight);
    vec3  sunsetBlend = mix(dayHorizon, sunsetHorizon, t * 1.5);
    return mix(nightHorizon, sunsetBlend, dayFactor);
}

#endif // ATMOSPHERE_GLSL

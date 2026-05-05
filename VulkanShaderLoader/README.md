# VulkanShaderLoader

**Iris-style shader pack loader for [VulkanMod](https://github.com/xCollateral/VulkanMod).**  
Drop shader packs into `shaderpacks/`, select them from the new **Shader Packs** tab
inside VulkanMod's options screen, click **Apply** — done.

---

## Features

| Feature | Status |
|---|---|
| Shader pack discovery (folder-based) | ✅ |
| "Shader Packs" tab in VulkanMod options | ✅ |
| Iris-style selection screen | ✅ |
| Shader pack hot-override (terrain, clouds, water) | ✅ |
| `#include` resolution from pack's `include/` folder | ✅ |
| Active pack persisted across launches | ✅ |
| **RealismShader** — PBR template pack | ✅ |

---

## Installation

1. Install Fabric Loader + VulkanMod `≥ 0.6.5`
2. Drop `VulkanShaderLoader-1.0.0.jar` into `mods/`
3. Drop any shader packs into `.minecraft/shaderpacks/`
4. Launch → **Options → Shader Packs** → select → **Apply**

---

## Writing a Shader Pack

### Minimum structure

```
shaderpacks/
  MyPack/
    pack.json
    shaders/
      terrain.vsh    ← required
      terrain.fsh    ← required
```

### Full structure (all override slots)

```
shaderpacks/
  MyPack/
    pack.json
    shaders/
      terrain.vsh / terrain.fsh      ← opaque + translucent blocks
      clouds.vsh  / clouds.fsh       ← clouds (optional)
      water.vsh   / water.fsh        ← water surface (optional)
    include/
      mybiglib.glsl                  ← resolved by #include "mybiglib.glsl"
```

### pack.json schema

```jsonc
{
  "name":            "My Shader Pack",
  "author":          "Your Name",
  "version":         "1.0.0",
  "description":     "Beautiful lighting for VulkanMod",
  "preview_image":   "preview.png",
  "min_vulkanmod":   "0.6.5",
  "has_water_shader": false,
  "has_cloud_shader": false,
  "uses_pack_ubo":    false
}
```

---

## Shader Template — RealismShader

The included `shaderpacks/RealismShader/` is a full, production-quality
starting point.  Copy the folder and rename it.

### Lighting pipeline (terrain.fsh)

```
Albedo texture (sRGB) ──decode──▶ Linear albedo
                                      │
                      ┌───────────────┼──────────────────┐
                      │               │                  │
             GGX specular     Disney diffuse       Ambient (sky)
           (sun direction)   (wrap for SSS)    (Rayleigh/Mie sphere)
                      │               │                  │
                      └───────────────┼──────────────────┘
                                   HDR sum
                                      │
                              Atmospheric fog
                              (horizon-sky blend)
                                      │
                              ACES tone mapping
                                      │
                           Colour grade + saturation
                                      │
                               LDR sRGB output
```

### Changing the look

**More cinematic (film grain feel):**
```glsl
// terrain.fsh finalOutput() call:
0.35,                       // EV exposure (lower = darker)
0,                          // ACES
vec3(0.01, 0.008, 0.005),   // warmer shadow lift
vec3(1.05, 1.0, 0.95),      // warm midtones
vec3(0.95),                 // slightly desaturated highlights
1.05                        // less saturation
```

**Vivid, punchy (BSL-style):**
```glsl
0.55,                       // EV higher
0,                          // ACES
vec3(0.003, 0.003, 0.006),  // cool shadow lift
vec3(1.0, 1.0, 1.0),
vec3(1.0),
1.35                        // high saturation
```

**Cool/cinematic night (Bliss-style):**
- Increase `moonColor` multiplier from `0.15` → `0.35`
- Reduce `nightAmbientStrength` threshold
- Add blue tint: `moonColor = vec3(0.15, 0.20, 0.40) * 0.35`

### Adding normal maps / PBR textures (Phase 2)

When LabPBR-style textures become available for blocks, replace the
`estimatePBR()` function with real texture lookups:

```glsl
layout(binding = 5) uniform sampler2D NormalMap;   // LabPBR normal
layout(binding = 6) uniform sampler2D SpecularMap; // r=roughness g=metallic b=emissive

PBRParams estimatePBR(vec4 albedo, vec4 vertexColor) {
    PBRParams p;
    vec4 spec    = texture(SpecularMap, v_TexCoord);
    p.roughness  = 1.0 - spec.r;   // LabPBR: r channel = smoothness
    p.metallic   = spec.g;
    p.sssAmount  = 0.0;
    p.ao         = 1.0;
    return p;
}
```

### Adding shadow maps (Phase 3)

A full shadow pass requires registering a depth attachment in VulkanMod's
Vulkan render pass builder.  The hooks for this will be provided in a
future version of VulkanShaderLoader:

```java
// Future API:
ShaderPackAPI.registerShadowPass(shadowResolution, cascades);
```

Until then, an approximation using **SSAO from world-position** can substitute
for contact shadows in the fragment shader.

---

## Mixin architecture

```
VOptionScreen.initPages()
  └── VOptionScreenMixin
        └─ adds "Shader Packs" button → ShaderPackScreen

ShaderLoadUtil.getShaderSource(path, name, ext, kind)
  └── ShaderLoadUtilMixin
        └─ ShaderPackManager.getShaderSource(name, ext)
              └─ reads  shaderpacks/<active>/shaders/<name>.<ext>
              └─ resolves #include from shaderpacks/<active>/include/
              └─ returns null if pack doesn't override → vanilla fallback
```

---

## License

LGPL-3.0-only.  You are free to use this loader in your own shader packs
and mods.  Shader pack content you write is fully yours.

package net.shadervulkan.loader;

import com.google.gson.Gson;
import net.fabricmc.loader.api.FabricLoader;
import net.shadervulkan.VulkanShaderLoaderMod;
import net.shadervulkan.config.ShaderConfig;
import org.jetbrains.annotations.Nullable;

import java.io.IOException;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/**
 * Central manager for shader pack discovery, activation, and source resolution.
 *
 * <p>The mixin {@code ShaderLoadUtilMixin} calls {@link #getShaderSource(String, String)}
 * on every shader load request. If the active pack provides that shader, its GLSL
 * source (with #include directives resolved against the pack's include/ folder) is
 * returned. Otherwise {@code null} tells the mixin to fall through to VulkanMod's
 * default loader.
 *
 * <p>Include resolution notes:
 *   VulkanMod's {@code SPIRVUtils$ShaderIncluder} normally resolves #includes from
 *   {@code assets/vulkanmod/shaders/include/}. When a custom pack is active the
 *   {@code ShaderIncluderMixin} overrides the resolver so that:
 *     1. Pack's own include/ folder is searched first.
 *     2. VulkanMod's built-in include/ is used as fallback.
 */
public final class ShaderPackManager {

    private static final Gson GSON = new Gson();

    /** All packs found on disk, keyed by folder name. */
    private static final Map<String, ShaderPack> discoveredPacks = new LinkedHashMap<>();

    /** Currently active pack, or {@code null} for vanilla. */
    @Nullable
    private static ShaderPack activePack = null;

    // ── Directory helpers ─────────────────────────────────────────────────────

    public static Path getShaderPacksDir() {
        return FabricLoader.getInstance().getGameDir().resolve("shaderpacks");
    }

    // ── Discovery ─────────────────────────────────────────────────────────────

    /**
     * Scans the shaderpacks/ directory for valid packs.
     * A valid pack must contain at least {@code shaders/terrain.vsh} and
     * {@code shaders/terrain.fsh}.
     */
    public static void discoverPacks() {
        discoveredPacks.clear();
        Path dir = getShaderPacksDir();

        if (!Files.isDirectory(dir)) return;

        try (DirectoryStream<Path> stream = Files.newDirectoryStream(dir)) {
            for (Path entry : stream) {
                if (Files.isDirectory(entry)) {
                    tryLoadPack(entry);
                }
                // TODO: .zip support in a future version
            }
        } catch (IOException e) {
            VulkanShaderLoaderMod.LOGGER.error("[ShaderPackManager] Error scanning shaderpacks/", e);
        }

        VulkanShaderLoaderMod.LOGGER.info("[ShaderPackManager] Found {} pack(s): {}",
                discoveredPacks.size(), discoveredPacks.keySet());
    }

    private static void tryLoadPack(Path packRoot) {
        String folderName = packRoot.getFileName().toString();
        Path metaFile = packRoot.resolve("pack.json");
        Path terrainVsh = packRoot.resolve("shaders/terrain.vsh");
        Path terrainFsh = packRoot.resolve("shaders/terrain.fsh");

        ShaderPack pack = new ShaderPack();
        pack.rootPath = packRoot;

        // Load metadata if present (not required)
        if (Files.exists(metaFile)) {
            try (Reader r = Files.newBufferedReader(metaFile, StandardCharsets.UTF_8)) {
                ShaderPack meta = GSON.fromJson(r, ShaderPack.class);
                if (meta != null) {
                    pack.name         = meta.name;
                    pack.author       = meta.author;
                    pack.version      = meta.version;
                    pack.description  = meta.description;
                    pack.previewImage = meta.previewImage;
                    pack.hasWaterShader  = meta.hasWaterShader;
                    pack.hasCloudShader  = meta.hasCloudShader;
                    pack.usesPackUbo     = meta.usesPackUbo;
                    pack.minVulkanMod    = meta.minVulkanMod;
                }
            } catch (Exception e) {
                VulkanShaderLoaderMod.LOGGER.warn("[ShaderPackManager] Bad pack.json in {}: {}", folderName, e.getMessage());
            }
        }

        // Minimum requirement: terrain shaders must exist
        pack.valid = Files.exists(terrainVsh) && Files.exists(terrainFsh);

        if (!pack.valid) {
            VulkanShaderLoaderMod.LOGGER.warn("[ShaderPackManager] Pack '{}' is missing terrain.vsh/fsh — skipped.", folderName);
            return;
        }

        discoveredPacks.put(folderName, pack);
        VulkanShaderLoaderMod.LOGGER.info("[ShaderPackManager] Loaded pack: {}", pack);
    }

    // ── Activation ────────────────────────────────────────────────────────────

    public static void setActivePack(@Nullable String folderName) {
        if (folderName == null || folderName.isBlank()) {
            activePack = null;
            ShaderConfig.setActivePack(null);
            VulkanShaderLoaderMod.LOGGER.info("[ShaderPackManager] Shader pack disabled (vanilla)");
        } else {
            ShaderPack pack = discoveredPacks.get(folderName);
            if (pack != null && pack.valid) {
                activePack = pack;
                ShaderConfig.setActivePack(folderName);
                VulkanShaderLoaderMod.LOGGER.info("[ShaderPackManager] Activated pack: {}", pack.getDisplayName());
            } else {
                VulkanShaderLoaderMod.LOGGER.warn("[ShaderPackManager] Pack '{}' not found or invalid.", folderName);
            }
        }
    }

    @Nullable
    public static ShaderPack getActivePack() {
        return activePack;
    }

    @Nullable
    public static String getActivePackFolderName() {
        return activePack != null ? activePack.rootPath.getFileName().toString() : null;
    }

    public static boolean hasActivePack() {
        return activePack != null;
    }

    public static boolean packExists(String folderName) {
        return discoveredPacks.containsKey(folderName);
    }

    public static Collection<ShaderPack> getDiscoveredPacks() {
        return Collections.unmodifiableCollection(discoveredPacks.values());
    }

    // ── Source resolution ─────────────────────────────────────────────────────

    /**
     * Attempts to resolve a GLSL shader source from the active pack.
     *
     * <p>Called by {@code ShaderLoadUtilMixin} before VulkanMod's own loading.
     *
     * @param shaderName  bare name without extension, e.g. {@code "terrain"},
     *                    {@code "clouds"}, {@code "blit"}
     * @param extension   file extension: {@code "vsh"} or {@code "fsh"}
     * @return            the GLSL source string, or {@code null} if not provided
     *                    by the active pack (fall through to vanilla).
     */
    @Nullable
    public static String getShaderSource(String shaderName, String extension) {
        if (activePack == null) return null;

        Path shaderFile = activePack.getShadersDir().resolve(shaderName + "." + extension);
        if (!Files.exists(shaderFile)) return null;

        try {
            String source = Files.readString(shaderFile, StandardCharsets.UTF_8);
            // Resolve #include directives against the pack's include/ folder
            source = resolveIncludes(source, activePack);
            return source;
        } catch (IOException e) {
            VulkanShaderLoaderMod.LOGGER.error("[ShaderPackManager] Failed to read {}.{} from pack '{}'",
                    shaderName, extension, activePack.getDisplayName(), e);
            return null;
        }
    }

    /**
     * Resolves {@code #include "file.glsl"} directives in the given GLSL source.
     * Searches the pack's include/ folder first, then returns the original
     * directive intact so VulkanMod's own includer handles it (for built-in
     * includes like fog.glsl, light.glsl, etc.).
     */
    private static String resolveIncludes(String source, ShaderPack pack) {
        StringBuilder result = new StringBuilder();
        for (String line : source.split("\n", -1)) {
            String trimmed = line.stripLeading();
            if (trimmed.startsWith("#include")) {
                // Extract the filename: #include "filename.glsl"
                int start = trimmed.indexOf('"');
                int end   = trimmed.lastIndexOf('"');
                if (start != -1 && end > start) {
                    String included = trimmed.substring(start + 1, end);
                    Path incPath = pack.getIncludeDir().resolve(included);
                    if (Files.exists(incPath)) {
                        try {
                            String incSource = Files.readString(incPath, StandardCharsets.UTF_8);
                            // Recursive: resolve nested includes
                            result.append("// #include \"").append(included).append("\" (resolved from pack)\n");
                            result.append(resolveIncludes(incSource, pack)).append("\n");
                            continue;
                        } catch (IOException ignored) {}
                    }
                }
            }
            result.append(line).append("\n");
        }
        return result.toString();
    }

    /**
     * Resolves a single include file for VulkanMod's ShaderIncluder callback.
     * Used by {@code SPIRVUtilsMixin}.
     */
    @Nullable
    public static String resolveInclude(String includeName) {
        if (activePack == null) return null;
        Path incPath = activePack.getIncludeDir().resolve(includeName);
        if (!Files.exists(incPath)) return null;
        try {
            return Files.readString(incPath, StandardCharsets.UTF_8);
        } catch (IOException e) {
            return null;
        }
    }
}

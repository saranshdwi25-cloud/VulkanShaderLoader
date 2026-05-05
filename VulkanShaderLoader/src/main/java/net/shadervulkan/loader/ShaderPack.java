package net.shadervulkan.loader;

import com.google.gson.annotations.SerializedName;
import java.nio.file.Path;

/**
 * Represents a discovered shader pack on disk.
 * Maps to the pack's {@code pack.json} metadata file.
 */
public class ShaderPack {

    // ── Metadata ──────────────────────────────────────────────────────────────

    /** Human-readable name shown in the selection screen. */
    public String name;

    /** Author(s) of the pack. */
    public String author;

    /** Semantic version string, e.g. "1.0.0". */
    public String version;

    /** One-line tagline displayed under the pack name. */
    public String description;

    /** Optional path to a 256×144 PNG preview image inside the pack folder. */
    @SerializedName("preview_image")
    public String previewImage;

    // ── Requirements ─────────────────────────────────────────────────────────

    /** Minimum VulkanMod version required, e.g. "0.6.5". */
    @SerializedName("min_vulkanmod")
    public String minVulkanMod = "0.6.5";

    // ── Feature flags ─────────────────────────────────────────────────────────

    /** Whether this pack provides a water.vsh / water.fsh override. */
    @SerializedName("has_water_shader")
    public boolean hasWaterShader = false;

    /** Whether this pack provides a clouds.vsh / clouds.fsh override. */
    @SerializedName("has_cloud_shader")
    public boolean hasCloudShader = false;

    /**
     * Whether this pack uses a custom ShaderPackUBO (binding = 6) that the
     * loader must populate each frame with sun/moon direction, rain, etc.
     */
    @SerializedName("uses_pack_ubo")
    public boolean usesPackUbo = true;

    // ── Runtime fields (not from JSON) ────────────────────────────────────────

    /** Absolute path to the pack's root folder (e.g. .minecraft/shaderpacks/RealismShader/). */
    public transient Path rootPath;

    /** Whether this pack was successfully validated at load time. */
    public transient boolean valid = false;

    // ── Helpers ───────────────────────────────────────────────────────────────

    public Path getShadersDir() {
        return rootPath.resolve("shaders");
    }

    public Path getIncludeDir() {
        return rootPath.resolve("include");
    }

    /**
     * Returns the display name falling back to the folder name when the
     * {@code name} field in pack.json is empty or absent.
     */
    public String getDisplayName() {
        return (name != null && !name.isBlank()) ? name : rootPath.getFileName().toString();
    }

    @Override
    public String toString() {
        return String.format("ShaderPack{name='%s', author='%s', version='%s', valid=%s}",
                getDisplayName(), author, version, valid);
    }
}

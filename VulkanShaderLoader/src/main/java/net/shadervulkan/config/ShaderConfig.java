package net.shadervulkan.config;

import com.google.gson.*;
import net.fabricmc.loader.api.FabricLoader;
import net.shadervulkan.VulkanShaderLoaderMod;
import org.jetbrains.annotations.Nullable;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;

/**
 * Tiny JSON config that persists the user's active shader pack selection
 * across game launches. Saved to {@code <gamedir>/config/vulkan_shader_loader.json}.
 */
public final class ShaderConfig {

    private static final Path CONFIG_FILE =
            FabricLoader.getInstance().getConfigDir().resolve("vulkan_shader_loader.json");

    private static final Gson GSON = new GsonBuilder().setPrettyPrinting().create();

    @Nullable
    private static String activePack = null;

    // ── Public API ────────────────────────────────────────────────────────────

    public static void load() {
        if (!Files.exists(CONFIG_FILE)) {
            save();
            return;
        }
        try (Reader r = Files.newBufferedReader(CONFIG_FILE, StandardCharsets.UTF_8)) {
            JsonObject obj = GSON.fromJson(r, JsonObject.class);
            if (obj == null) return;
            JsonElement ap = obj.get("active_pack");
            activePack = (ap != null && !ap.isJsonNull()) ? ap.getAsString() : null;
        } catch (Exception e) {
            VulkanShaderLoaderMod.LOGGER.warn("[ShaderConfig] Failed to load config: {}", e.getMessage());
        }
    }

    public static void save() {
        try {
            JsonObject obj = new JsonObject();
            if (activePack != null) obj.addProperty("active_pack", activePack);
            else obj.add("active_pack", JsonNull.INSTANCE);
            Files.writeString(CONFIG_FILE, GSON.toJson(obj), StandardCharsets.UTF_8);
        } catch (Exception e) {
            VulkanShaderLoaderMod.LOGGER.warn("[ShaderConfig] Failed to save config: {}", e.getMessage());
        }
    }

    @Nullable
    public static String getActivePack() { return activePack; }

    public static void setActivePack(@Nullable String pack) {
        activePack = pack;
        save();
    }
}

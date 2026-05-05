package net.shadervulkan;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.shadervulkan.config.ShaderConfig;
import net.shadervulkan.loader.ShaderPackManager;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.file.Files;
import java.nio.file.Path;

/**
 * VulkanShaderLoader — Iris-style shader pack loader for VulkanMod.
 *
 * Architecture overview:
 *   1. On client start, scan <game_dir>/shaderpacks/ for packs.
 *   2. ShaderPackManager keeps the active pack in memory.
 *   3. ShaderLoadUtilMixin intercepts VulkanMod's getShaderSource() calls
 *      and redirects them to the active pack's shaders/ folder.
 *   4. VOptionScreenMixin injects a "Shader Packs" button into VulkanMod's
 *      options screen, opening ShaderPackScreen.
 *
 * Shader pack format:
 *   shaderpacks/
 *     MyPack/
 *       pack.json        – metadata + feature flags
 *       shaders/
 *         terrain.vsh    – replaces assets/vulkanmod/shaders/basic/terrain/terrain.vsh
 *         terrain.fsh
 *         clouds.vsh
 *         clouds.fsh
 *         water.vsh      (optional)
 *         water.fsh      (optional)
 *       include/
 *         <any .glsl>    – resolved automatically by #include
 */
public class VulkanShaderLoaderMod implements ClientModInitializer {

    public static final String MOD_ID    = "vulkan_shader_loader";
    public static final String MOD_NAME  = "VulkanShaderLoader";
    public static final Logger LOGGER    = LoggerFactory.getLogger(MOD_NAME);

    @Override
    public void onInitializeClient() {
        LOGGER.info("[{}] Initializing — scanning shader packs…", MOD_NAME);

        // Ensure shaderpacks/ directory exists next to the game jar
        Path shaderPacksDir = ShaderPackManager.getShaderPacksDir();
        if (!Files.exists(shaderPacksDir)) {
            try {
                Files.createDirectories(shaderPacksDir);
                LOGGER.info("[{}] Created shaderpacks/ directory at {}", MOD_NAME, shaderPacksDir);
            } catch (Exception e) {
                LOGGER.error("[{}] Could not create shaderpacks/ directory", MOD_NAME, e);
            }
        }

        // Load config (remembers which pack was last active)
        ShaderConfig.load();

        // Discover packs
        ClientLifecycleEvents.CLIENT_STARTED.register(client -> {
            ShaderPackManager.discoverPacks();
            String lastActive = ShaderConfig.getActivePack();
            if (lastActive != null && ShaderPackManager.packExists(lastActive)) {
                ShaderPackManager.setActivePack(lastActive);
                LOGGER.info("[{}] Restored active pack: {}", MOD_NAME, lastActive);
            } else {
                LOGGER.info("[{}] No active pack — vanilla rendering", MOD_NAME);
            }
        });

        LOGGER.info("[{}] Ready.", MOD_NAME);
    }
}

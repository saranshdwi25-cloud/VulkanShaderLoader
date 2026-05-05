package net.shadervulkan.mixin;

import net.shadervulkan.loader.ShaderPackManager;
import net.vulkanmod.vulkan.shader.SPIRVUtils;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * Intercepts {@code ShaderLoadUtil.getShaderSource()} so that when an active
 * shader pack is loaded, the pack's own GLSL files are returned instead of
 * VulkanMod's built-in assets.
 *
 * <p><b>How VulkanMod loads a shader:</b>
 * <ol>
 *   <li>{@code ShaderLoadUtil.loadShaders()} reads the pipeline JSON descriptor
 *       and finds the vertex/fragment shader names.
 *   <li>For each shader it calls {@code getShaderSource(shaderPath, shaderName,
 *       fileExt, kind)}, which reads
 *       {@code assets/vulkanmod/shaders/<category>/<name>/<name>.<ext>} via the
 *       Minecraft resource manager.
 *   <li>The returned GLSL string is then compiled to SPIR-V by
 *       {@code SPIRVUtils.compileShader()} using the bundled shaderc library.
 * </ol>
 *
 * <p>We inject at {@code HEAD} with {@code cancellable = true}. If the active
 * pack provides a matching shader, we set the return value immediately and
 * cancel the rest of the method. Otherwise we do nothing and VulkanMod's
 * built-in shader loads as normal — this means packs only need to provide
 * the shaders they actually want to override.
 */
@Mixin(targets = "net.vulkanmod.render.shader.ShaderLoadUtil",
       remap = false)
public abstract class ShaderLoadUtilMixin {

    /**
     * Intercepts {@code getShaderSource(String shaderPath, String shaderName,
     * String fileExt, SPIRVUtils$ShaderKind kind) -> String}.
     *
     * <p>The method signature (extracted via {@code strings} on the class file):
     * {@code (Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;
     * Lnet/vulkanmod/vulkan/shader/SPIRVUtils$ShaderKind;)Ljava/lang/String;}
     *
     * @param shaderPath  internal path prefix, e.g. {@code "vulkanmod/shaders/basic/terrain"}
     * @param shaderName  bare name, e.g. {@code "terrain"}
     * @param fileExt     extension: {@code "vsh"} or {@code "fsh"}
     * @param kind        VERTEX or FRAGMENT
     * @param cir         mixin callback — set return value to cancel vanilla load
     */
    @Inject(
        method = "getShaderSource",
        at = @At("HEAD"),
        cancellable = true,
        remap = false
    )
    private static void vsl_interceptShaderSource(
            String shaderPath,
            String shaderName,
            String fileExt,
            SPIRVUtils.ShaderKind kind,
            CallbackInfoReturnable<String> cir
    ) {
        if (!ShaderPackManager.hasActivePack()) return;

        String override = ShaderPackManager.getShaderSource(shaderName, fileExt);
        if (override != null) {
            cir.setReturnValue(override);
        }
        // null → fall through to VulkanMod's default loader
    }
}

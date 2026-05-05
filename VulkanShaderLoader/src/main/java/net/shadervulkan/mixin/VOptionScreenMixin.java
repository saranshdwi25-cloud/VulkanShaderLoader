package net.shadervulkan.mixin;

import net.minecraft.client.gui.screen.Screen;
import net.shadervulkan.gui.ShaderPackScreen;
import net.vulkanmod.config.gui.widget.VButtonWidget;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import java.util.List;

/**
 * Injects a "Shader Packs" button into VulkanMod's options screen.
 *
 * <p>VOptionScreen keeps a {@code pageButtons} list of navigation buttons
 * along the top. We shadow that list and append our button at the end of
 * {@code initPages()}.  The button opens {@link ShaderPackScreen}.
 *
 * <p>The layout engine in VOptionScreen automatically distributes page
 * buttons horizontally, so simply adding to the list is sufficient.
 */
@Mixin(targets = "net.vulkanmod.config.gui.VOptionScreen",
       remap = false)
public abstract class VOptionScreenMixin extends Screen {

    protected VOptionScreenMixin() {
        super(null);
    }

    /** VulkanMod's navigation page button list — shadowed so we can append. */
    @Shadow(remap = false)
    private List<VButtonWidget> pageButtons;

    /**
     * Inject at the end of {@code initPages()} (the method that populates
     * {@code pageButtons}) to add our shader pack navigation button.
     */
    @Inject(method = "initPages", at = @At("TAIL"), remap = false)
    private void vsl_addShaderPackButton(CallbackInfo ci) {
        if (pageButtons == null) return;

        // Build a VButtonWidget that opens ShaderPackScreen
        VButtonWidget shaderButton = VButtonWidget.builder()
                .pos(0, 0)              // Position managed by the layout engine
                .size(90, 20)
                .label("Shader Packs")
                .onPress(btn -> {
                    // 'this' is the VOptionScreen (via the mixin)
                    if (this.client != null) {
                        this.client.setScreen(new ShaderPackScreen(this));
                    }
                })
                .build();

        pageButtons.add(shaderButton);
    }
}

package net.shadervulkan.gui;

import net.minecraft.client.gui.DrawContext;
import net.minecraft.client.gui.screen.Screen;
import net.minecraft.client.gui.widget.ButtonWidget;
import net.minecraft.text.Text;
import net.shadervulkan.VulkanShaderLoaderMod;
import net.shadervulkan.loader.ShaderPack;
import net.shadervulkan.loader.ShaderPackManager;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.List;

/**
 * Iris-style shader pack selection screen.
 *
 * Layout:
 * ┌──────────────────────────────────────────────────────────┐
 * │              VulkanShaderLoader — Shader Packs           │
 * ├──────────────────────────────────────────────────────────┤
 * │  [Off]  RealismShader v1.0  ← scrollable list            │
 * │         BlissVK   v2.1                                   │
 * │         SEUSVulkan v3.0                                  │
 * │                                                          │
 * ├──────────────────────────────────────────────────────────┤
 * │ Description: "Physically-based lighting for VulkanMod"  │
 * │ Author: Saransh   Requires VulkanMod ≥ 0.6.5            │
 * ├──────────────────────────────────────────────────────────┤
 * │         [Reload Packs]  [Apply]  [Done]                  │
 * └──────────────────────────────────────────────────────────┘
 */
public class ShaderPackScreen extends Screen {

    private static final int TITLE_COLOR       = 0xFFFFFFFF;
    private static final int HEADER_BG         = 0xC0101010;
    private static final int LIST_BG           = 0x80000000;
    private static final int ENTRY_SELECTED_BG = 0x80206080;
    private static final int ENTRY_HOVER_BG    = 0x40FFFFFF;
    private static final int ENTRY_H           = 22;
    private static final int INFO_H            = 44;
    private static final int BTN_H             = 20;
    private static final int MARGIN            = 8;

    private final Screen parent;

    // ── State ─────────────────────────────────────────────────────────────────

    /** Flat list: index 0 = "Off (Vanilla)", then one entry per discovered pack. */
    private final List<@Nullable ShaderPack> entries = new ArrayList<>();

    /** Index into {@link #entries} that is currently highlighted. */
    private int hoverIndex  = -1;

    /** Index into {@link #entries} that the user has clicked but not yet applied. */
    private int selectedIndex = 0;

    /** Index that was active when the screen opened (for cancel/undo). */
    private int appliedIndex  = 0;

    /** Scroll offset in pixels. */
    private int scrollOffset = 0;

    private int listTop, listBottom, listWidth, listLeft;

    // ── Constructor ───────────────────────────────────────────────────────────

    public ShaderPackScreen(Screen parent) {
        super(Text.literal("Shader Packs — VulkanShaderLoader"));
        this.parent = parent;
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    @Override
    protected void init() {
        buildEntryList();

        // Layout constants
        int centerX   = this.width / 2;
        int titleH    = 26;
        int bottomH   = BTN_H + MARGIN * 2;

        listLeft   = MARGIN;
        listTop    = titleH + MARGIN;
        listWidth  = this.width - MARGIN * 2;
        listBottom = this.height - INFO_H - bottomH - MARGIN;

        // ── Bottom buttons ─────────────────────────────────────────────────

        int btnY   = this.height - BTN_H - MARGIN;
        int btnW   = 90;
        int gap    = 6;
        int totalW = btnW * 3 + gap * 2;
        int startX = centerX - totalW / 2;

        // Reload packs
        addDrawableChild(ButtonWidget.builder(
                Text.literal("Reload Packs"),
                btn -> {
                    ShaderPackManager.discoverPacks();
                    buildEntryList();
                })
                .dimensions(startX, btnY, btnW, BTN_H)
                .build());

        // Apply
        addDrawableChild(ButtonWidget.builder(
                Text.literal("Apply"),
                btn -> applySelected())
                .dimensions(startX + btnW + gap, btnY, btnW, BTN_H)
                .build());

        // Done
        addDrawableChild(ButtonWidget.builder(
                Text.literal("Done"),
                btn -> closeScreen())
                .dimensions(startX + (btnW + gap) * 2, btnY, btnW, BTN_H)
                .build());
    }

    private void buildEntryList() {
        entries.clear();
        entries.add(null); // "Off" entry

        String activeFolder = ShaderPackManager.getActivePackFolderName();
        int activeIdx = 0;

        for (ShaderPack pack : ShaderPackManager.getDiscoveredPacks()) {
            entries.add(pack);
            if (pack.rootPath.getFileName().toString().equals(activeFolder)) {
                activeIdx = entries.size() - 1;
            }
        }

        selectedIndex = activeIdx;
        appliedIndex  = activeIdx;
    }

    // ── Mouse input ───────────────────────────────────────────────────────────

    @Override
    public boolean mouseClicked(double mouseX, double mouseY, int button) {
        if (button == 0 && isInList(mouseX, mouseY)) {
            int idx = getEntryIndexAt((int) mouseY);
            if (idx >= 0 && idx < entries.size()) {
                selectedIndex = idx;
                return true;
            }
        }
        return super.mouseClicked(mouseX, mouseY, button);
    }

    @Override
    public boolean mouseMoved(double mouseX, double mouseY) {
        if (isInList(mouseX, mouseY)) {
            hoverIndex = getEntryIndexAt((int) mouseY);
        } else {
            hoverIndex = -1;
        }
        return super.mouseMoved(mouseX, mouseY);
    }

    @Override
    public boolean mouseScrolled(double mouseX, double mouseY, double hAmount, double vAmount) {
        if (isInList(mouseX, mouseY)) {
            scrollOffset = Math.max(0, scrollOffset - (int) (vAmount * ENTRY_H));
            return true;
        }
        return super.mouseScrolled(mouseX, mouseY, hAmount, vAmount);
    }

    // ── Rendering ─────────────────────────────────────────────────────────────

    @Override
    public void render(DrawContext ctx, int mouseX, int mouseY, float delta) {
        // Background
        this.renderBackground(ctx, mouseX, mouseY, delta);

        // Title bar
        ctx.fill(0, 0, this.width, 26, HEADER_BG);
        ctx.drawCenteredTextWithShadow(textRenderer, this.title, this.width / 2, 8, TITLE_COLOR);

        // List background
        ctx.fill(listLeft, listTop, listLeft + listWidth, listBottom, LIST_BG);

        // Clip list rendering
        ctx.enableScissor(listLeft, listTop, listLeft + listWidth, listBottom);
        renderEntries(ctx, mouseX, mouseY);
        ctx.disableScissor();

        // Info panel
        renderInfoPanel(ctx);

        // Widget buttons
        super.render(ctx, mouseX, mouseY, delta);
    }

    private void renderEntries(DrawContext ctx, int mouseX, int mouseY) {
        int y = listTop - scrollOffset;
        for (int i = 0; i < entries.size(); i++) {
            ShaderPack pack = entries.get(i);
            boolean isSelected = (i == selectedIndex);
            boolean isApplied  = (i == appliedIndex);
            boolean isHovered  = (i == hoverIndex);

            int entryBg = isSelected ? ENTRY_SELECTED_BG
                        : isHovered  ? ENTRY_HOVER_BG
                        : 0x00000000;
            if (entryBg != 0) ctx.fill(listLeft, y, listLeft + listWidth, y + ENTRY_H, entryBg);

            // Left accent bar for applied pack
            if (isApplied) ctx.fill(listLeft, y + 2, listLeft + 3, y + ENTRY_H - 2, 0xFF40C080);

            String label = pack == null
                    ? "§7Off (Vanilla)"
                    : "§f" + pack.getDisplayName()
                      + (pack.version != null ? " §8v" + pack.version : "")
                      + (isApplied ? " §a[Active]" : "");

            ctx.drawTextWithShadow(textRenderer, label, listLeft + 8, y + (ENTRY_H - 8) / 2, 0xFFFFFFFF);
            y += ENTRY_H;
        }
    }

    private void renderInfoPanel(DrawContext ctx) {
        int panelTop = listBottom + MARGIN / 2;
        ctx.fill(MARGIN, panelTop, this.width - MARGIN, panelTop + INFO_H, 0x80101010);

        ShaderPack sel = selectedIndex < entries.size() ? entries.get(selectedIndex) : null;

        if (sel == null) {
            ctx.drawTextWithShadow(textRenderer, "§fVanilla rendering (no shader pack active)", MARGIN + 6, panelTop + 6, 0xFFFFFFFF);
            ctx.drawTextWithShadow(textRenderer, "§7Select a pack from the list above and press Apply.", MARGIN + 6, panelTop + 18, 0xAAAAAA);
        } else {
            String desc = sel.description != null ? sel.description : "No description provided.";
            String info = "§8Author: §7" + (sel.author != null ? sel.author : "Unknown")
                        + "   §8Requires VulkanMod §7≥ " + sel.minVulkanMod;
            ctx.drawTextWithShadow(textRenderer, "§f" + desc, MARGIN + 6, panelTop + 6, 0xFFFFFFFF);
            ctx.drawTextWithShadow(textRenderer, info, MARGIN + 6, panelTop + 18, 0xAAAAAA);
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private boolean isInList(double x, double y) {
        return x >= listLeft && x <= listLeft + listWidth && y >= listTop && y <= listBottom;
    }

    private int getEntryIndexAt(int y) {
        int relY = y - listTop + scrollOffset;
        return relY / ENTRY_H;
    }

    private void applySelected() {
        if (selectedIndex == 0) {
            ShaderPackManager.setActivePack(null);
        } else {
            ShaderPack pack = entries.get(selectedIndex);
            if (pack != null) {
                ShaderPackManager.setActivePack(pack.rootPath.getFileName().toString());
            }
        }
        appliedIndex = selectedIndex;
        VulkanShaderLoaderMod.LOGGER.info("[ShaderPackScreen] Applied selection index={}", selectedIndex);
    }

    private void closeScreen() {
        if (this.client != null) this.client.setScreen(parent);
    }

    @Override
    public boolean shouldPause() { return false; }
}

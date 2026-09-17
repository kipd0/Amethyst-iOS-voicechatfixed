package com.mojang.blaze3d.platform;

/**
 * iOS shim for Minecraft 26.3 macOS-only window behavior.
 *
 * Amethyst reports a macOS-like Java environment, but these desktop macOS
 * operations are not applicable on iOS. Keep them as no-ops.
 */
public final class MacosUtil {
    public static final boolean IS_MACOS = false;

    private MacosUtil() {
    }

    public static void disableCloseWindowMenuItem() {
    }

    public static void setFullscreenMenuVisibility(boolean value) {
    }

    public static void setCtrlClickEmulatesRightClick(boolean value) {
    }
}

package net.kdt.pojavlaunch;

import java.beans.Beans;
import java.io.*;
import java.lang.reflect.Field;
import java.util.*;
import java.util.concurrent.*;

import net.kdt.pojavlaunch.uikit.*;
import net.kdt.pojavlaunch.utils.*;
import net.kdt.pojavlaunch.value.*;

public class PojavLauncher {
    private static float currProgress, maxProgress;

    private static boolean isMinecraft263(JMinecraftVersionList.Version version, String requestedId) {
        if (version == null) {
            return false;
        }

        if ("26.3".equals(version.id) || "26.3".equals(version.inheritsFrom)) {
            return true;
        }

        if (version.id != null && version.id.endsWith("-26.3")) {
            return true;
        }

        return requestedId != null
                && ("26.3".equals(requestedId) || requestedId.endsWith("-26.3"));
    }

    private static void configureLWJGL(JMinecraftVersionList.Version version, String requestedId) throws Exception {
        boolean minecraft263 = isMinecraft263(version, requestedId);

        File bundleDir = new File(Tools.DIR_BUNDLE);
        File lwjglJar = new File(
                bundleDir,
                minecraft263
                        ? "libs/lwjgl41/lwjgl.jar"
                        : "libs/lwjgllegacy/lwjgl.jar"
        );

        File frameworkDir = new File(
                bundleDir,
                minecraft263
                        ? "Frameworks/MC263"
                        : "Frameworks"
        );

        if (!lwjglJar.isFile()) {
            throw new FileNotFoundException(
                    "Missing bundled LWJGL jar: " + lwjglJar.getAbsolutePath()
            );
        }

        if (!frameworkDir.isDirectory()) {
            throw new FileNotFoundException(
                    "Missing bundled LWJGL native directory: " + frameworkDir.getAbsolutePath()
            );
        }

        PojavClassLoader loader =
                (PojavClassLoader) ClassLoader.getSystemClassLoader();

        loader.addURL(lwjglJar.toURI().toURL());

        System.setProperty(
                "org.lwjgl.librarypath",
                frameworkDir.getAbsolutePath()
        );

        if (minecraft263) {
            System.setProperty(
                    "org.lwjgl.vulkan.libname",
                    new File(frameworkDir, "libMoltenVK.dylib").getAbsolutePath()
            );
        } else {
            System.setProperty(
                    "org.lwjgl.vulkan.libname",
                    "libMoltenVK.dylib"
            );
        }

        System.out.println(
                "[LWJGL] Runtime: "
                        + (minecraft263 ? "Minecraft 26.3" : "legacy")
                        + ", jar=" + lwjglJar.getAbsolutePath()
                        + ", natives=" + frameworkDir.getAbsolutePath()
        );
    }

    public static void main(String[] args) throws Throwable {
        // Skip calling to com.apple.eawt.Application.nativeInitializeApplicationDelegate()
        Beans.setDesignTime(true);
        try {
            // Some places use macOS-specific code, which is unavailable on iOS
            // In this case, try to get it to use Linux-specific code instead.
            com.apple.eawt.Application.getApplication();
            Class clazz = Class.forName("com.apple.eawt.Application");
            Field field = clazz.getDeclaredField("sApplication");
            field.setAccessible(true);
            field.set(null, null);
            sun.font.FontUtilities.isLinux = true;
            System.setProperty("java.util.prefs.PreferencesFactory", "java.util.prefs.FileSystemPreferencesFactory");
        } catch (Throwable th) {
            // Not on JRE8, ignore exception
            //Tools.showError(th);
        }

        Thread.currentThread().setUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {

            public void uncaughtException(Thread t, Throwable th) {
                th.printStackTrace();
                System.exit(1);
            }
        });

        try {
            // Try to initialize Caciocavallo17
            Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCPreloadClassLoader");
        } catch (ClassNotFoundException e) {}

        if (args[0].equals("-jar")) {
            UIKit.callback_JavaGUIViewController_launchJarFile(args[1], Arrays.copyOfRange(args, 2, args.length));
        } else {
            launchMinecraft(args);
        }
    }

    public static void launchMinecraft(String[] args) throws Throwable {
        // Args for Spiral Knights
        System.setProperty("appdir", "./spiral");
        System.setProperty("resource_dir", "./spiral/rsrc");

        String sizeStr = System.getProperty("cacio.managed.screensize");
        System.setProperty("glfw.windowSize", sizeStr);

        // Setup Forge splash.properties
        File forgeSplashFile = new File(Tools.DIR_GAME_NEW, "config/splash.properties");
        if (System.getProperty("pojav.internal.keepForgeSplash") == null) {
            forgeSplashFile.getParentFile().mkdir();
            if (forgeSplashFile.exists()) {
                Tools.write(forgeSplashFile.getAbsolutePath(), Tools.read(forgeSplashFile.getAbsolutePath().replace("enabled=true", "enabled=false")));
            } else {
                Tools.write(forgeSplashFile.getAbsolutePath(), "enabled=false");
            }
        }

        MinecraftAccount account = MinecraftAccount.load(args[0]);
        JMinecraftVersionList.Version version = Tools.getVersionInfo(args[1]);

        configureLWJGL(version, args[1]);

        System.out.println("Launching Minecraft " + version.id);
        String configPath;
        if (version.logging != null) {
            if (version.logging.client.file.id.equals("client-1.12.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.12.xml";
            } else if (version.logging.client.file.id.equals("client-1.7.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.7.xml";
            } else {
                configPath = Tools.DIR_GAME_NEW + "/" + version.logging.client.file.id;
            }
            System.setProperty("log4j.configurationFile", configPath);
        }

        Tools.launchMinecraft(account, version);
    }
}

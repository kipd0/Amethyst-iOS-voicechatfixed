package net.kdt.patchjna;

import java.io.*;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.IllegalClassFormatException;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.security.ProtectionDomain;

public class PatchJNAAgent implements ClassFileTransformer {
    private static byte[] readPatch(String resource, byte[] fallback) {
        try (InputStream inputStream =
                     PatchJNAAgent.class.getClassLoader().getResourceAsStream(resource)) {
            if (inputStream == null) {
                System.err.println("PatchJNAAgent: Missing patch resource " + resource);
                return fallback;
            }

            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int read;

            while ((read = inputStream.read(buffer)) != -1) {
                output.write(buffer, 0, read);
            }

            return output.toByteArray();
        } catch (Exception e) {
            e.printStackTrace();
            return fallback;
        }
    }

    private static boolean containsAscii(byte[] data, String value) {
        byte[] needle = value.getBytes(StandardCharsets.UTF_8);

        outer:
        for (int i = 0; i <= data.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) {
                if (data[i + j] != needle[j]) {
                    continue outer;
                }
            }
            return true;
        }

        return false;
    }

    private static boolean isMinecraft263MacosUtil(byte[] classfileBuffer) {
        return containsAscii(classfileBuffer, "disableCloseWindowMenuItem")
                && containsAscii(classfileBuffer, "setFullscreenMenuVisibility")
                && containsAscii(classfileBuffer, "setCtrlClickEmulatesRightClick");
    }

    @Override
    public byte[] transform(
            ClassLoader loader,
            String className,
            Class<?> classBeingRedefined,
            ProtectionDomain protectionDomain,
            byte[] classfileBuffer
    ) throws IllegalClassFormatException {
        if ("com/sun/jna/Platform".equals(className)) {
            System.out.println("PatchJNAAgent: Replacing class");
            return readPatch(
                    "com/sun/jna/Platform.class.patch",
                    classfileBuffer
            );
        }

        /*
         * Fabric's Knot class loader loads Minecraft's own MacosUtil instead
         * of the iOS shim from the parent LWJGL jar. Minecraft 26.3 then tries
         * to load jcocoa/Cocoa.framework, which does not exist on iOS.
         *
         * Match the 26.3 MacosUtil API before replacing it so older Minecraft
         * Fabric versions keep their original class.
         */
        if ("com/mojang/blaze3d/platform/MacosUtil".equals(className)
                && isMinecraft263MacosUtil(classfileBuffer)) {
            System.out.println(
                    "PatchJNAAgent: Replacing Minecraft 26.3 MacosUtil for Fabric"
            );

            return readPatch(
                    "com/mojang/blaze3d/platform/MacosUtil.class.patch",
                    classfileBuffer
            );
        }

        return classfileBuffer;
    }

    public static void premain(String args, Instrumentation instrumentation) {
        System.out.println("PatchJNAAgent: premain called");
        instrumentation.addTransformer(new PatchJNAAgent());
    }
}

/*
 * V3 input bridge implementation.
 *
 * Status:
 * - Active development
 * - Works with some bugs:
 *  + Modded versions gives broken stuff..
 */

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "SurfaceViewController.h"
#import "MinecraftOptionUtils.h"

#include <assert.h>
#include <dlfcn.h>
#include <libgen.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

#include "jni.h"
#include "glfw_keycodes.h"
#include "ios_uikit_bridge.h"
#include "utils.h"

#include "JavaLauncher.h"

jint (*orig_ProcessImpl_forkAndExec)(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream);
jlong (*orig_ProcessHandleImpl_isAlive0)(JNIEnv *env, jclass clazz, jlong jpid);

NSString* processPath(NSString* path) {
    if ([path hasPrefix:@"file:"]) {
        path = [path substringFromIndex:5].stringByRemovingPercentEncoding;
    }
    path = path.stringByResolvingSymlinksInPath;

    NSString *prefix = @"file";
    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"shareddocuments://"]] &&
      ![path hasPrefix:@"/var/mobile/Documents"]) {
        prefix = @"shareddocuments";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"filza://"]]) {
        prefix = @"filza";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"santander://"]]) {
        prefix = @"santander";
    }

    return [NSString stringWithFormat:@"%@://%@", prefix, path];
}

void openURLGlobal(NSString *path) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([path hasPrefix:@"http"]) {
            openLink(UIWindow.mainWindow.rootViewController, [NSURL URLWithString:path]);
            dispatch_group_leave(group);
            return;
        }
        NSString *realPath = processPath(path);
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:realPath] options:@{} completionHandler:^(BOOL success) {
            if (success) {
                NSLog(@"Opened \"%@\"", realPath);
            } else {
                NSLog(@"Failed to open \"%@\"", realPath);
            }
            dispatch_group_leave(group);
        }];
    });

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

jint
hooked_ProcessImpl_forkAndExec(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream) {
    char *pProg = (char *)((*env)->GetByteArrayElements(env, prog, NULL));

    if (strcmp(basename(pProg), "open")) {
        (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
        return orig_ProcessImpl_forkAndExec(env, process, mode, helperpath, prog, argBlock, argc, envBlock, envc, dir, std_fds, redirectErrorStream);
    }

    char *path = (char *)((*env)->GetByteArrayElements(env, argBlock, NULL));
    openURLGlobal(@(path));

    (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
    (*env)->ReleaseByteArrayElements(env, argBlock, (jbyte *)path, 0);
    return 0;
}

jlong hooked_ProcessHandleImpl_isAlive0(JNIEnv *env, jclass clazz, jlong jpid) {
    jlong result = orig_ProcessHandleImpl_isAlive0(env, clazz, jpid);
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionClear(env);
    }
    return result;
}

void CTCClipboard_nQuerySystemClipboard(JNIEnv *env, jclass clazz) {
    if(method_SystemClipboardDataReceived == NULL) {
        class_CTCClipboard = (*env)->NewGlobalRef(env, clazz);
        method_SystemClipboardDataReceived = (*env)->GetStaticMethodID(env, clazz, "systemClipboardDataReceived", "(Ljava/lang/String;Ljava/lang/String;)V");
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        JNIEnv *env;
        (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &env, NULL);
        const char* mimeChars = "text/plain";
        (*env)->CallStaticVoidMethod(env, class_CTCClipboard, method_SystemClipboardDataReceived,
            UIKit_accessClipboard(env, CLIPBOARD_PASTE, NULL),
            (*env)->NewStringUTF(env, mimeChars));
        (*runtimeJavaVMPtr)->DetachCurrentThread(runtimeJavaVMPtr);
    });
}

void CTCClipboard_nPutClipboardData(JNIEnv* env, jclass clazz, jstring clipboardData, jstring clipboardDataMime) {
    UIKit_accessClipboard(env, CLIPBOARD_COPY, clipboardData);
}

void CTCDesktopPeer_openGlobal(JNIEnv *env, jclass clazz, jstring path) {
    const char* stringChars = (*env)->GetStringUTFChars(env, path, NULL);
    openURLGlobal(@(stringChars));
    (*env)->ReleaseStringUTFChars(env, path, stringChars);
}

void hackFix18LWJGL(void *addr) {
    addr = (void *)((uintptr_t)addr & ~PAGE_MASK);
    if(DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED)) return;
    if(!mprotect(addr, PAGE_SIZE, PROT_READ | PROT_EXEC)) return;

    char tempPage[PAGE_SIZE];
    memcpy(tempPage, addr, PAGE_SIZE);
    void *result = mmap(addr, PAGE_SIZE, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(result != MAP_FAILED);
    memcpy(addr, tempPage, PAGE_SIZE);
    mprotect(addr, PAGE_SIZE, PROT_READ | PROT_EXEC);
}

void registerOpenHandler(JNIEnv *env) {
    jclass cls;

    orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_UNIXProcess_forkAndExec");
    if (!orig_ProcessImpl_forkAndExec) {
        orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessImpl_forkAndExec");
        cls = (*env)->FindClass(env, "java/lang/ProcessImpl");
    } else {
        cls = (*env)->FindClass(env, "java/lang/UNIXProcess");
    }

    JNINativeMethod forkAndExecMethod[] = {
        {"forkAndExec", "(I[B[B[BI[BI[B[IZ)I", (void *)&hooked_ProcessImpl_forkAndExec}
    };
    (*env)->RegisterNatives(env, cls, forkAndExecMethod, 1);

    cls = (*env)->FindClass(env, "java/lang/ProcessHandleImpl");
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionClear(env);
    } else {
        orig_ProcessHandleImpl_isAlive0 = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessHandleImpl_isAlive0");
        JNINativeMethod isAlive0Method[] = {
            {"isAlive0", "(J)J", (void *)&hooked_ProcessHandleImpl_isAlive0}
        };
        (*env)->RegisterNatives(env, cls, isAlive0Method, 1);
    }

    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCClipboard");
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionClear(env);
        cls = (*env)->FindClass(env, "com/github/caciocavallosilano/cacio/ctc/CTCClipboard");
    }

    JNINativeMethod clipboardMethods[] = {
        {"nQuerySystemClipboard", "()V", (void *)&CTCClipboard_nQuerySystemClipboard},
        {"nPutClipboardData", "(Ljava/lang/String;Ljava/lang/String;)V", (void *)&CTCClipboard_nPutClipboardData}
    };
    (*env)->RegisterNatives(env, cls, clipboardMethods, 2);

    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCDesktopPeer");
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionClear(env);
        return;
    }

    JNINativeMethod peerOpenMethods[] = {
        {"openFile", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal},
        {"openUri", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal}
    };
    (*env)->RegisterNatives(env, cls, peerOpenMethods, 2);
}

void JNI_OnLoadGLFW() {
    vmGlfwClass = (*runtimeJNIEnvPtr)->NewGlobalRef(runtimeJNIEnvPtr, (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW"));
    method_internalWindowSizeChanged = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, vmGlfwClass, "internalWindowSizeChanged", "(JII)V");

    jfieldID field_keyDownBuffer = (*runtimeJNIEnvPtr)->GetStaticFieldID(runtimeJNIEnvPtr, vmGlfwClass, "keyDownBuffer", "Ljava/nio/ByteBuffer;");
    jobject keyDownBufferJ = (*runtimeJNIEnvPtr)->GetStaticObjectField(runtimeJNIEnvPtr, vmGlfwClass, field_keyDownBuffer);
    keyDownBuffer = (*runtimeJNIEnvPtr)->GetDirectBufferAddress(runtimeJNIEnvPtr, keyDownBufferJ);
}

jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    runtimeJavaVMPtr = vm;

    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    registerOpenHandler(env);

    if (!getenv("POJAV_SKIP_JNI_GLFW")) {
        runtimeJNIEnvPtr = env;
        JNI_OnLoadGLFW();
    }

    return JNI_VERSION_1_4;
}

void JNI_OnUnload(JavaVM* vm, void* reserved) {
    runtimeJNIEnvPtr = NULL;
}

#define ADD_CALLBACK_WWIN(NAME) \
JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSet##NAME##Callback(JNIEnv * env, jclass cls, jlong window, jlong callbackptr) { \
    void** oldCallback = (void**) &GLFW_invoke_##NAME; \
    GLFW_invoke_##NAME = (GLFW_invoke_##NAME##_func*) (uintptr_t) callbackptr; \
    return (jlong) (uintptr_t) *oldCallback; \
}

ADD_CALLBACK_WWIN(Char)
ADD_CALLBACK_WWIN(CharMods)
ADD_CALLBACK_WWIN(CursorEnter)
ADD_CALLBACK_WWIN(CursorPos)
ADD_CALLBACK_WWIN(FramebufferSize)
ADD_CALLBACK_WWIN(Key)
ADD_CALLBACK_WWIN(MouseButton)
ADD_CALLBACK_WWIN(Scroll)
ADD_CALLBACK_WWIN(WindowPos)
ADD_CALLBACK_WWIN(WindowSize)

#undef ADD_CALLBACK_WWIN

void handleFramebufferSizeJava(void* window, int w, int h) {
    if(GLFW_invoke_CursorEnter) GLFW_invoke_CursorEnter(window, 1);
    if(GLFW_invoke_WindowPos) GLFW_invoke_WindowPos(window, 0, 0);

    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(
        runtimeJNIEnvPtr,
        vmGlfwClass,
        method_internalWindowSizeChanged,
        (long)window,
        w,
        h
    );
}

void pojavPumpEvents(void* window) {
    static BOOL setInputReady = NO;

    if(!setInputReady) {
        setInputReady = YES;
        CallbackBridge_nativeSetInputReady(YES);
    }

    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);

    if((cLastX != cursorX || cLastY != cursorY) && GLFW_invoke_CursorPos) {
        cLastX = cursorX;
        cLastY = cursorY;

        if (isUseStackQueueCall)
            GLFW_invoke_CursorPos(window, cursorX, cursorY);
    }

    for(size_t i = 0; i < counter; i++) {
        GLFWInputEvent event = events[i];

        switch(event.type) {
            case EVENT_TYPE_CHAR:
                if(GLFW_invoke_Char)
                    GLFW_invoke_Char(window, event.i1);
                break;

            case EVENT_TYPE_CHAR_MODS:
                if(GLFW_invoke_CharMods)
                    GLFW_invoke_CharMods(window, event.i1, event.i2);
                break;

            case EVENT_TYPE_KEY:
                if(GLFW_invoke_Key)
                    GLFW_invoke_Key(window, event.i1, event.i2, event.i3, event.i4);
                break;

            case EVENT_TYPE_MOUSE_BUTTON:
                if(GLFW_invoke_MouseButton)
                    GLFW_invoke_MouseButton(window, event.i1, event.i2, event.i3);
                break;

            case EVENT_TYPE_SCROLL:
                if(GLFW_invoke_Scroll)
                    GLFW_invoke_Scroll(window, event.f1, event.f2);
                break;

            case EVENT_TYPE_FRAMEBUFFER_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_FramebufferSize)
                    GLFW_invoke_FramebufferSize(window, event.i1, event.i2);
                break;

            case EVENT_TYPE_WINDOW_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_WindowSize)
                    GLFW_invoke_WindowSize(window, event.i1, event.i2);
                break;
        }
    }

    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void pojavRewindEvents() {
    atomic_store_explicit(&eventCounter, 0, memory_order_release);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos(
    JNIEnv *env,
    jclass clazz,
    jlong window,
    jobject xpos,
    jobject ypos
) {
    *(double*)(*env)->GetDirectBufferAddress(env, xpos) = cursorX;
    *(double*)(*env)->GetDirectBufferAddress(env, ypos) = cursorY;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA(
    JNIEnv *env,
    jclass clazz,
    jlong window,
    jdoubleArray xpos,
    jdoubleArray ypos
) {
    (*env)->SetDoubleArrayRegion(env, xpos, 0, 1, &cursorX);
    (*env)->SetDoubleArrayRegion(env, ypos, 0, 1, &cursorY);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos(
    JNIEnv *env,
    jclass clazz,
    jlong window,
    jdouble xpos,
    jdouble ypos
) {
    cLastX = cursorX = xpos;
    cLastY = cursorY = ypos;
}

void sendData(short type, int i1, int i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);

    if (counter < 7999) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->i1 = i1;
        event->i2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }

    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void sendDataFloat(short type, float i1, float i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);

    if (counter < 7999) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->f1 = i1;
        event->f2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }

    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void closeGLFWWindow() {
    NSLog(@"Closing GLFW window");
    exit(-1);
}

const int hotbarKeys[9] = {
    GLFW_KEY_1, GLFW_KEY_2, GLFW_KEY_3,
    GLFW_KEY_4, GLFW_KEY_5, GLFW_KEY_6,
    GLFW_KEY_7, GLFW_KEY_8, GLFW_KEY_9
};

int mcscale(CGFloat input) {
    return (int)((guiScale * input) / resolutionScale);
}

int callback_SurfaceViewController_touchHotbar(CGFloat x, CGFloat y) {
    if (isGrabbing == JNI_FALSE) {
        return -1;
    }

    int barHeight = mcscale(20);
    int barY = physicalHeight - barHeight;

    if (y < barY)
        return -1;

    int barWidth = mcscale(180);
    int barX = (physicalWidth / 2) - (barWidth / 2);

    if (x < barX || x >= barX + barWidth)
        return -1;

    return hotbarKeys[(int)MathUtils_map(x, barX, barX + barWidth, 0, 9)];
}

JNIEXPORT jstring JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(
    JNIEnv* env,
    jclass clazz,
    jint action,
    jstring copySrc
) {
    NSDebugLog(@"Debug: Clipboard access is going on\n");
    return UIKit_accessClipboard(env, action, copySrc);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(
    JNIEnv* env,
    jclass clazz,
    jboolean grabbing,
    jfloat xset,
    jfloat yset
) {
    isGrabbing = grabbing;

    if(grabbing) {
        [MinecraftOptionUtils.sharedInstance updateMCGuiScale];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        SurfaceViewController *vc =
            ((SurfaceViewController *)UIWindow.mainWindow.rootViewController);

        [vc updateGrabState];
    });
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeIsGrabbing(
    JNIEnv* env,
    jclass clazz
) {
    return isGrabbing;
}

void CallbackBridge_nativeSetInputReady(BOOL inputReady) {
    isInputReady = inputReady;

    if (inputReady) {
        if (GLFW_invoke_FramebufferSize) {
            hackFix18LWJGL(GLFW_invoke_FramebufferSize);
            GLFW_invoke_FramebufferSize(
                (void*)showingWindow,
                windowWidth,
                windowHeight
            );
        }

        if (GLFW_invoke_WindowSize) {
            GLFW_invoke_FramebufferSize(
                (void*)showingWindow,
                windowWidth,
                windowHeight
            );
        }
    }
}

#pragma mark - SDL3 event injection (Minecraft 26.x / RenderPearl backend)

typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    uint32_t which;
    uint32_t state;
    float x;
    float y;
    float xrel;
    float yrel;
} AASDL_MouseMotionEvent;

typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    uint32_t which;
    uint8_t button;
    uint8_t down;
    uint8_t clicks;
    uint8_t padding;
    float x;
    float y;
} AASDL_MouseButtonEvent;

typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    uint32_t which;
    float x;
    float y;
    int32_t direction;
    float mouse_x;
    float mouse_y;
    int32_t integer_x;
    int32_t integer_y;
} AASDL_MouseWheelEvent;

typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    uint32_t which;
    uint32_t scancode;
    uint32_t key;
    uint32_t mod;
    uint16_t raw;
    uint8_t down;
    uint8_t repeat;
} AASDL_KeyboardEvent;

typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    const char *text;
} AASDL_TextInputEvent;

typedef union {
    uint8_t raw[128];
} AASDL_Event;

static int (*aasdl_PushEvent)(void *event);

static uint32_t aasdl_buttons;
static uint32_t aasdl_winID;

static int aasdl_winW;
static int aasdl_winH;

static BOOL aasdl_available(void) {
    if (!aasdl_PushEvent) {
        aasdl_PushEvent =
            (int (*)(void *))dlsym(RTLD_DEFAULT, "SDL_PushEvent");

        if (!aasdl_PushEvent) {
            static int logged;

            if (!logged) {
                logged = 1;
                NSLog(@"[SDLInject] SDL_PushEvent not found yet, will retry");
            }

            return NO;
        }

        NSLog(@"[SDLInject] SDL event injection ready");
    }

    return YES;
}

void MC263Input_NoteWindow(uint32_t windowID, int w, int h) {
    aasdl_winID = windowID;

    if (w > 0)
        aasdl_winW = w;

    if (h > 0)
        aasdl_winH = h;
}

void MC263Input_NoteGrab(bool grabbed) {
    isGrabbing = grabbed ? JNI_TRUE : JNI_FALSE;

    if (grabbed) {
        [MinecraftOptionUtils.sharedInstance updateMCGuiScale];
    }
}

static int aasdl_width(void) {
    return windowWidth > 0 ? windowWidth : aasdl_winW;
}

static int aasdl_height(void) {
    return windowHeight > 0 ? windowHeight : aasdl_winH;
}

static BOOL aasdl_coords(
    CGFloat x,
    CGFloat y,
    float *outX,
    float *outY
) {
    int w = aasdl_width();
    int h = aasdl_height();

    if (w <= 0 || h <= 0 || aasdl_winID == 0)
        return NO;

    *outX = (float)x;
    *outY = (float)y;

    return YES;
}

static void aasdl_pushMouseMotion(
    float x,
    float y,
    float xrel,
    float yrel,
    uint32_t state
) {
    int w = aasdl_width();
    int h = aasdl_height();

    if (w <= 0 || h <= 0 || aasdl_winID == 0)
        return;

    AASDL_Event ev;
    memset(&ev, 0, sizeof(ev));

    AASDL_MouseMotionEvent *m =
        (AASDL_MouseMotionEvent *)ev.raw;

    m->type = 0x400;
    m->windowID = aasdl_winID;
    m->state = state;

    m->x = fmaxf(
        0.0f,
        fminf(x, (float)w - 1.0f)
    );

    m->y = fmaxf(
        0.0f,
        fminf(y, (float)h - 1.0f)
    );

    m->xrel = xrel;
    m->yrel = yrel;

    aasdl_PushEvent(&ev);
}

static void aasdl_pushMouseButton(
    int button,
    bool down,
    float x,
    float y
) {
    if (aasdl_winID == 0)
        return;

    AASDL_Event ev;
    memset(&ev, 0, sizeof(ev));

    AASDL_MouseButtonEvent *b =
        (AASDL_MouseButtonEvent *)ev.raw;

    b->type = down ? 0x401 : 0x402;
    b->windowID = aasdl_winID;
    b->button = (uint8_t)button;
    b->down = down;
    b->clicks = 1;
    b->x = x;
    b->y = y;

    aasdl_PushEvent(&ev);

    if (down) {
        aasdl_buttons |= (1u << (button - 1));
    } else {
        aasdl_buttons &= ~(1u << (button - 1));
    }
}

static void aasdl_pushMouseWheel(
    float xoffset,
    float yoffset
) {
    if (aasdl_winID == 0)
        return;

    AASDL_Event ev;
    memset(&ev, 0, sizeof(ev));

    AASDL_MouseWheelEvent *w =
        (AASDL_MouseWheelEvent *)ev.raw;

    w->type = 0x403;
    w->windowID = aasdl_winID;
    w->x = xoffset;
    w->y = yoffset;
    w->direction = 1;
    w->integer_x = (int32_t)xoffset;
    w->integer_y = (int32_t)yoffset;

    float mx;
    float my;

    if (aasdl_coords(cursorX, cursorY, &mx, &my)) {
        w->mouse_x = mx;
        w->mouse_y = my;
    }

    aasdl_PushEvent(&ev);
}

static void aasdl_pushKey(
    uint32_t scancode,
    uint32_t keycode,
    bool down,
    uint32_t mods
) {
    if (aasdl_winID == 0)
        return;

    AASDL_Event ev;
    memset(&ev, 0, sizeof(ev));

    AASDL_KeyboardEvent *k =
        (AASDL_KeyboardEvent *)ev.raw;

    k->type = down ? 0x300 : 0x301;
    k->windowID = aasdl_winID;
    k->scancode = scancode;
    k->key = keycode;
    k->mod = mods;
    k->down = down;

    aasdl_PushEvent(&ev);
}

/*
 * SDL_PushEvent copies the event structure, but the text field inside
 * SDL_TextInputEvent is still a pointer. A stack buffer here becomes invalid
 * as soon as this function returns and causes random/gibberish characters.
 *
 * Keep one permanent UTF-8 buffer for each UTF-16 code unit Amethyst can send.
 * That makes every queued event's text pointer valid for the lifetime of the
 * process without leaking memory per key press.
 */
static char aasdl_textCache[65536][4];
static uint8_t aasdl_textCacheReady[65536];

static void aasdl_pushTextInput(uint32_t codepoint) {
    if (aasdl_winID == 0)
        return;

    /*
     * TrackedTextField sends jchar values, so the normal input path is a
     * UTF-16 code unit in the 0..65535 range.
     */
    if (codepoint > 0xFFFF)
        return;

    char *utf8 = aasdl_textCache[codepoint];

    if (!aasdl_textCacheReady[codepoint]) {
        if (codepoint < 0x80) {
            utf8[0] = (char)codepoint;
            utf8[1] = ' ';
        } else if (codepoint < 0x800) {
            utf8[0] =
                (char)(0xC0 | (codepoint >> 6));
            utf8[1] =
                (char)(0x80 | (codepoint & 0x3F));
            utf8[2] = ' ';
        } else {
            utf8[0] =
                (char)(0xE0 | (codepoint >> 12));
            utf8[1] =
                (char)(0x80 | ((codepoint >> 6) & 0x3F));
            utf8[2] =
                (char)(0x80 | (codepoint & 0x3F));
            utf8[3] = ' ';
        }

        aasdl_textCacheReady[codepoint] = 1;
    }

    AASDL_Event ev;
    memset(&ev, 0, sizeof(ev));

    AASDL_TextInputEvent *t =
        (AASDL_TextInputEvent *)ev.raw;

    t->type = 0x303; /* SDL_EVENT_TEXT_INPUT */
    t->windowID = aasdl_winID;
    t->text = utf8;

    aasdl_PushEvent(&ev);
}

typedef struct {
    int glfw;
    uint32_t scancode;
    uint32_t keycode;
} AASDL_KeyMap;

static const AASDL_KeyMap aasdl_keyMap[] = {
    { GLFW_KEY_SPACE, 44, 0x20 },
    { GLFW_KEY_APOSTROPHE, 52, 0x27 },
    { GLFW_KEY_COMMA, 54, 0x2C },
    { GLFW_KEY_MINUS, 45, 0x2D },
    { GLFW_KEY_PERIOD, 55, 0x2E },
    { GLFW_KEY_SLASH, 56, 0x2F },
    { GLFW_KEY_SEMICOLON, 51, 0x3B },
    { GLFW_KEY_EQUAL, 46, 0x3D },
    { GLFW_KEY_LEFT_BRACKET, 47, 0x5B },
    { GLFW_KEY_BACKSLASH, 49, 0x5C },
    { GLFW_KEY_RIGHT_BRACKET, 48, 0x5D },
    { GLFW_KEY_GRAVE_ACCENT, 53, 0x60 },

    { GLFW_KEY_ENTER, 40, 0x0D },
    { GLFW_KEY_TAB, 43, 0x09 },
    { GLFW_KEY_BACKSPACE, 42, 0x08 },

    { GLFW_KEY_INSERT, 73, 0x40000049u },
    { GLFW_KEY_DELETE, 76, 0x7F },

    { 262, 79, 0x4000004Fu },
    { 263, 80, 0x40000050u },
    { 264, 81, 0x40000051u },
    { 265, 82, 0x40000052u },

    { GLFW_KEY_PAGE_UP, 75, 0x4000004Bu },
    { GLFW_KEY_PAGE_DOWN, 78, 0x4000004Eu },
    { GLFW_KEY_HOME, 74, 0x4000004Au },
    { GLFW_KEY_END, 77, 0x4000004Du },

    { GLFW_KEY_CAPS_LOCK, 57, 0x40000039u },
    { GLFW_KEY_SCROLL_LOCK, 71, 0x40000047u },
    { GLFW_KEY_NUM_LOCK, 83, 0x40000053u },

    { GLFW_KEY_ESCAPE, 41, 0x1B },

    { GLFW_KEY_LEFT_SHIFT, 225, 0x400000E1u },
    { GLFW_KEY_LEFT_CONTROL, 224, 0x400000E0u },
    { GLFW_KEY_LEFT_ALT, 226, 0x400000E2u },
    { GLFW_KEY_LEFT_SUPER, 227, 0x400000E3u },

    { GLFW_KEY_RIGHT_SHIFT, 229, 0x400000E5u },
    { GLFW_KEY_RIGHT_CONTROL, 228, 0x400000E4u },
    { GLFW_KEY_RIGHT_ALT, 230, 0x400000E6u },
    { GLFW_KEY_RIGHT_SUPER, 231, 0x400000E7u },

    { GLFW_KEY_MENU, 232, 0x400000E8u }
};

static BOOL aasdl_mapKey(
    int key,
    uint32_t *scancode,
    uint32_t *keycode
) {
    if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
        *scancode =
            4 + (key - GLFW_KEY_A);

        *keycode =
            (uint32_t)key + 32;

        return YES;
    }

    if (key >= GLFW_KEY_1 && key <= GLFW_KEY_9) {
        *scancode =
            30 + (key - GLFW_KEY_1);

        *keycode =
            (uint32_t)key;

        return YES;
    }

    if (key == GLFW_KEY_0) {
        *scancode = 39;
        *keycode = (uint32_t)key;

        return YES;
    }

    if (key >= GLFW_KEY_F1 && key <= GLFW_KEY_F24) {
        uint32_t s =
            58 + (key - GLFW_KEY_F1);

        *scancode = s;
        *keycode = 0x40000000u | s;

        return YES;
    }

    for (
        size_t i = 0;
        i < sizeof(aasdl_keyMap) / sizeof(aasdl_keyMap[0]);
        i++
    ) {
        if (aasdl_keyMap[i].glfw == key) {
            *scancode = aasdl_keyMap[i].scancode;
            *keycode = aasdl_keyMap[i].keycode;

            return YES;
        }
    }

    return NO;
}

static uint32_t aasdl_mapMods(int mods) {
    uint32_t m = 0;

    if (mods & 0x01)
        m |= 0x0003;

    if (mods & 0x02)
        m |= 0x00C0;

    if (mods & 0x04)
        m |= 0x0300;

    if (mods & 0x08)
        m |= 0x0C00;

    if (mods & 0x10)
        m |= 0x2000;

    if (mods & 0x20)
        m |= 0x1000;

    return m;
}

BOOL CallbackBridge_nativeSendChar(jchar codepoint) {
    if (GLFW_invoke_Char && isInputReady) {
        if (isUseStackQueueCall) {
            sendData(
                EVENT_TYPE_CHAR,
                codepoint,
                0,
                0,
                0
            );
        } else {
            GLFW_invoke_Char(
                (void*)showingWindow,
                (unsigned int)codepoint
            );
        }

        return YES;
    } else if (aasdl_available()) {
        aasdl_pushTextInput(
            (uint32_t)codepoint
        );

        return YES;
    }

    return NO;
}

BOOL CallbackBridge_nativeSendCharMods(
    jchar codepoint,
    int mods
) {
    if (GLFW_invoke_CharMods && isInputReady) {
        if (isUseStackQueueCall) {
            sendData(
                EVENT_TYPE_CHAR_MODS,
                (unsigned int)codepoint,
                mods,
                0,
                0
            );
        } else {
            GLFW_invoke_CharMods(
                (void*)showingWindow,
                codepoint,
                mods
            );
        }

        return YES;
    } else if (aasdl_available()) {
        aasdl_pushTextInput(
            (uint32_t)codepoint
        );

        return YES;
    }

    return NO;
}

void CallbackBridge_nativeSendCursorPos(
    char event,
    CGFloat x,
    CGFloat y
) {
    if (!isInputReady && GLFW_invoke_CursorPos)
        return;

    switch (event) {
        case ACTION_DOWN:
        case ACTION_UP:
            if (!isGrabbing) {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE:
            if (isGrabbing) {
                cursorX += x - cLastX;
                cursorY += y - cLastY;
            } else {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE_MOTION:
            cursorX += x;
            cursorY += y;
            break;
    }

    if (GLFW_invoke_CursorPos) {
        if (
            isInputReady &&
            !isUseStackQueueCall
        ) {
            GLFW_invoke_CursorPos(
                (void*)showingWindow,
                (double)cursorX,
                (double)cursorY
            );
        }
    } else if (aasdl_available()) {
        float mx;
        float my;

        if (
            aasdl_coords(
                cursorX,
                cursorY,
                &mx,
                &my
            )
        ) {
            float xrel = 0.0f;
            float yrel = 0.0f;

            if (event == ACTION_MOVE_MOTION) {
                xrel = (float)x;
                yrel = (float)y;
            }

            aasdl_pushMouseMotion(
                mx,
                my,
                xrel,
                yrel,
                aasdl_buttons
            );
        }
    }
}

char getKeyModifiers(
    int key,
    int action
) {
    static char currMods;
    char mod;

    switch (key) {
        case GLFW_KEY_LEFT_SHIFT:
            mod = GLFW_MOD_SHIFT;
            break;

        case GLFW_KEY_LEFT_CONTROL:
            mod = GLFW_MOD_CONTROL;
            break;

        case GLFW_KEY_LEFT_ALT:
            mod = GLFW_MOD_ALT;
            break;

        case GLFW_KEY_CAPS_LOCK:
            mod = GLFW_MOD_CAPS_LOCK;
            break;

        case GLFW_KEY_NUM_LOCK:
            mod = GLFW_MOD_NUM_LOCK;
            break;

        default:
            return currMods;
    }

    if (action) {
        currMods |= mod;
    } else {
        currMods &= ~mod;
    }

    return currMods;
}

void CallbackBridge_nativeSendKey(
    int key,
    int scancode,
    int action,
    int mods
) {
    if (GLFW_invoke_Key) {
        if (isInputReady) {
            keyDownBuffer[
                MAX(0, key - 31)
            ] = (jbyte)action;

            if (mods == 0) {
                mods =
                    getKeyModifiers(
                        key,
                        action
                    );
            }

            if (isUseStackQueueCall) {
                sendData(
                    EVENT_TYPE_KEY,
                    key,
                    scancode,
                    action,
                    mods
                );
            } else {
                GLFW_invoke_Key(
                    (void*)showingWindow,
                    key,
                    scancode,
                    action,
                    mods
                );
            }
        }

        if (key == GLFW_KEY_LEFT_CONTROL) {
            CallbackBridge_nativeSendKey(
                GLFW_KEY_LEFT_SUPER,
                0,
                action,
                mods
            );
        } else if (key == GLFW_KEY_RIGHT_CONTROL) {
            CallbackBridge_nativeSendKey(
                GLFW_KEY_RIGHT_SUPER,
                0,
                action,
                mods
            );
        }
    } else if (aasdl_available()) {
        uint32_t sdlScan;
        uint32_t sdlKey;

        if (
            aasdl_mapKey(
                key,
                &sdlScan,
                &sdlKey
            )
        ) {
            if (mods == 0) {
                mods =
                    getKeyModifiers(
                        key,
                        action
                    );
            }

            aasdl_pushKey(
                sdlScan,
                sdlKey,
                action != 0,
                aasdl_mapMods(mods)
            );
        }
    }
}

void CallbackBridge_nativeSendMouseButton(
    int button,
    int action,
    int mods
) {
    if (GLFW_invoke_MouseButton) {
        if (isInputReady) {
            if (button == -1)
                return;

            if (mods == 0) {
                mods =
                    getKeyModifiers(
                        0,
                        action
                    );
            }

            if (isUseStackQueueCall) {
                sendData(
                    EVENT_TYPE_MOUSE_BUTTON,
                    button,
                    action,
                    mods,
                    0
                );
            } else {
                GLFW_invoke_MouseButton(
                    (void*)showingWindow,
                    button,
                    action,
                    mods
                );
            }
        }
    } else if (aasdl_available()) {
        if (button == -1)
            return;

        static const int glfwToSdl[3] = {
            1,
            3,
            2
        };

        int sdlButton =
            (button >= 0 && button < 3)
            ? glfwToSdl[button]
            : button + 1;

        if (
            sdlButton < 1 ||
            sdlButton > 8
        )
            return;

        float mx;
        float my;

        if (isGrabbing) {
            int w = aasdl_width();
            int h = aasdl_height();

            if (w <= 0 || h <= 0)
                return;

            mx = (float)w / 2.0f;
            my = (float)h / 2.0f;

            aasdl_pushMouseButton(
                sdlButton,
                action != 0,
                mx,
                my
            );
        } else if (
            aasdl_coords(
                cursorX,
                cursorY,
                &mx,
                &my
            )
        ) {
            aasdl_pushMouseButton(
                sdlButton,
                action != 0,
                mx,
                my
            );
        }
    }
}

void CallbackBridge_nativeSendScreenSize(
    int width,
    int height
) {
    windowWidth = width;
    windowHeight = height;

    if (isInputReady) {
        if (GLFW_invoke_FramebufferSize) {
            if (isUseStackQueueCall) {
                sendData(
                    EVENT_TYPE_FRAMEBUFFER_SIZE,
                    width,
                    height,
                    0,
                    0
                );
            } else {
                GLFW_invoke_FramebufferSize(
                    (void*)showingWindow,
                    width,
                    height
                );
            }
        }

        if (GLFW_invoke_WindowSize) {
            if (isUseStackQueueCall) {
                sendData(
                    EVENT_TYPE_WINDOW_SIZE,
                    width,
                    height,
                    0,
                    0
                );
            } else {
                GLFW_invoke_WindowSize(
                    (void*)showingWindow,
                    width,
                    height
                );
            }
        }
    }
}

void CallbackBridge_nativeSendScroll(
    CGFloat xoffset,
    CGFloat yoffset
) {
    if (
        GLFW_invoke_Scroll &&
        isInputReady
    ) {
        if (isUseStackQueueCall) {
            sendDataFloat(
                EVENT_TYPE_SCROLL,
                xoffset,
                yoffset,
                0,
                0
            );
        } else {
            GLFW_invoke_Scroll(
                (void*)showingWindow,
                (double)xoffset,
                (double)yoffset
            );
        }
    } else if (aasdl_available()) {
        aasdl_pushMouseWheel(
            (float)xoffset,
            (float)yoffset
        );
    }
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(
    JNIEnv* env,
    jclass clazz,
    jlong window
) {
    showingWindow = (long)window;
}

void CallbackBridge_pauseGameIfNeed() {
    if (isGrabbing) {
        CallbackBridge_nativeSendKey(
            GLFW_KEY_ESCAPE,
            0,
            1,
            0
        );

        CallbackBridge_nativeSendKey(
            GLFW_KEY_ESCAPE,
            0,
            0,
            0
        );
    }
}

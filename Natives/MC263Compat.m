#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

/*
 * Minecraft 26.3 / SDL3 compatibility bootstrap.
 *
 * The patched iOS SDL3 used by the bundled LWJGL requires SDL_SetMainReady()
 * before SDL_Init(SDL_INIT_VIDEO). Calling it from native code avoids loading
 * LWJGL from a second Java class loader just to reach SDLMain.
 */

static void *gMC263SDLHandle;
static uint32_t gMC263WindowID;
static int gMC263WindowWidth;
static int gMC263WindowHeight;
static double gMC263LastGrabTime;
static double gMC263LastKeyTime;

static void MC263_SetMainReady(void) {
    if (gMC263SDLHandle != NULL) return;

    NSString *path = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks/libSDL3.dylib"];

    gMC263SDLHandle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (gMC263SDLHandle == NULL) {
        NSLog(@"[MC263] Could not load libSDL3.dylib: %s", dlerror());
        return;
    }

    void (*setMainReady)(void) =
        (void (*)(void))dlsym(gMC263SDLHandle, "SDL_SetMainReady");
    if (setMainReady != NULL) {
        setMainReady();
        NSLog(@"[MC263] SDL_SetMainReady called");
    } else {
        NSLog(@"[MC263] SDL_SetMainReady symbol not found");
    }
}

__attribute__((constructor))
static void MC263_Initialize(void) {
    @autoreleasepool {
        MC263_SetMainReady();
    }
}

/*
 * Optional launcher hooks resolved by the patched SDL3 backend with dlsym().
 * These keep the SDL window attached to Amethyst's existing game surface.
 */

__attribute__((used, visibility("default")))
UIView *AASDL_GetHostView(void) {
    return [SurfaceViewController surface];
}

__attribute__((used, visibility("default")))
void AASDL_GetFramebufferSize(int *w, int *h) {
    int width = gMC263WindowWidth;
    int height = gMC263WindowHeight;

    if (width <= 0 || height <= 0) {
        UIView *surface = [SurfaceViewController surface];
        if (surface != nil) {
            CGFloat scale = surface.layer.contentsScale;
            if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
            width = (int)llround(surface.bounds.size.width * scale);
            height = (int)llround(surface.bounds.size.height * scale);
        }
    }

    if (w != NULL) *w = width;
    if (h != NULL) *h = height;
}

__attribute__((used, visibility("default")))
void AASDL_NoteWindow(uint32_t windowID, int w, int h) {
    gMC263WindowID = windowID;
    if (w > 0) gMC263WindowWidth = w;
    if (h > 0) gMC263WindowHeight = h;
    NSLog(@"[MC263] SDL window id=%u size=%dx%d", windowID, w, h);
}

__attribute__((used, visibility("default")))
void AASDL_NoteGrab(bool grabbed) {
    gMC263LastGrabTime = CACurrentMediaTime();
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = UIWindow.mainWindow.rootViewController;
        if ([root isKindOfClass:SurfaceViewController.class]) {
            [(SurfaceViewController *)root updateGrabState];
        }
    });
}

__attribute__((used, visibility("default")))
void AASDL_NoteCursorShape(int shape) {
    (void)shape;
}

__attribute__((used, visibility("default")))
void AASDL_NoteKey(void) {
    gMC263LastKeyTime = CACurrentMediaTime();
}

__attribute__((used, visibility("default")))
double AASDL_LastGrabChangeAge(void) {
    if (gMC263LastGrabTime <= 0.0) return 9999.0;
    return CACurrentMediaTime() - gMC263LastGrabTime;
}

__attribute__((used, visibility("default")))
bool AASDL_HardwareKeySeenWithin(double seconds) {
    return gMC263LastKeyTime > 0.0 &&
           (CACurrentMediaTime() - gMC263LastKeyTime) <= seconds;
}

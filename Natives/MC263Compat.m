#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "SurfaceViewController.h"
#import <objc/runtime.h>

#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

/*
 * Minecraft 26.3 / SDL3 compatibility bootstrap.
 */

static void *gMC263SDLHandle;

static uint32_t gMC263WindowID;
static int gMC263WindowWidth;
static int gMC263WindowHeight;

static double gMC263LastGrabTime;
static double gMC263LastKeyTime;

static atomic_bool gMC263MetalSyncPending = false;

extern void MC263Input_NoteWindow(
    uint32_t windowID,
    int w,
    int h
);

extern void MC263Input_NoteGrab(bool grabbed);


/*
 * Return the actual framebuffer size used by Amethyst.
 *
 * UIKit view sizes are in points. Minecraft/SDL mouse coordinates and
 * the Vulkan swapchain need framebuffer pixels.
 */
static void MC263_GetHostFramebufferSize(
    int *outWidth,
    int *outHeight
) {
    int width = 0;
    int height = 0;

    UIView *surface = [SurfaceViewController surface];

    if (surface != nil) {
        CGFloat scale = surface.layer.contentsScale;

        if (scale <= 0.0) {
            scale = UIScreen.mainScreen.scale;
        }

        width = (int)llround(
            surface.bounds.size.width * scale
        );

        height = (int)llround(
            surface.bounds.size.height * scale
        );
    }

    /*
     * Fallback only. The SDL window dimensions are UIKit points,
     * so convert them to pixels instead of returning them directly.
     */
    if (width <= 0 || height <= 0) {
        CGFloat scale = UIScreen.mainScreen.scale;

        if (scale <= 0.0) {
            scale = 1.0;
        }

        width = (int)llround(
            gMC263WindowWidth * scale
        );

        height = (int)llround(
            gMC263WindowHeight * scale
        );
    }

    if (outWidth != NULL) {
        *outWidth = width;
    }

    if (outHeight != NULL) {
        *outHeight = height;
    }
}


/*
 * Find SDL's Metal view inside Amethyst's game surface.
 */
static UIView *MC263_FindSDLMetalView(UIView *view) {
    if (view == nil) {
        return nil;
    }

    NSString *className =
        NSStringFromClass(view.class);

    if (
        [className
            rangeOfString:@"SDL_uikitmetalview"]
            .location != NSNotFound
    ) {
        return view;
    }

    for (UIView *subview in view.subviews) {
        UIView *result =
            MC263_FindSDLMetalView(subview);

        if (result != nil) {
            return result;
        }
    }

    return nil;
}


/*
 * SDL normally creates its Metal layer using UIScreen.nativeScale.
 *
 * Amethyst can use a different resolution scale. Keep SDL's Metal
 * layer in sync with the framebuffer size Amethyst exposes to
 * Minecraft, otherwise MoltenVK returns VK_SUBOPTIMAL_KHR every
 * frame and Minecraft continually recreates the swapchain.
 */
static void MC263_ScheduleMetalLayerSync(void) {
    bool alreadyPending =
        atomic_exchange_explicit(
            &gMC263MetalSyncPending,
            true,
            memory_order_acq_rel
        );

    if (alreadyPending) {
        return;
    }

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            UIView *surface =
                [SurfaceViewController surface];

            if (surface != nil) {
                UIView *metalView =
                    MC263_FindSDLMetalView(surface);

                if (
                    metalView != nil &&
                    [metalView.layer
                        isKindOfClass:CAMetalLayer.class]
                ) {
                    CAMetalLayer *metalLayer =
                        (CAMetalLayer *)metalView.layer;

                    CGFloat scale =
                        surface.layer.contentsScale;

                    if (scale <= 0.0) {
                        scale =
                            UIScreen.mainScreen.scale;
                    }

                    if (
                        fabs(
                            metalLayer.contentsScale -
                            scale
                        ) > 0.001
                    ) {
                        metalLayer.contentsScale =
                            scale;
                    }

                    CGSize wantedSize =
                        CGSizeMake(
                            metalView.bounds.size.width *
                                scale,
                            metalView.bounds.size.height *
                                scale
                        );

                    if (
                        fabs(
                            metalLayer.drawableSize.width -
                            wantedSize.width
                        ) > 0.5 ||
                        fabs(
                            metalLayer.drawableSize.height -
                            wantedSize.height
                        ) > 0.5
                    ) {
                        metalLayer.drawableSize =
                            wantedSize;
                    }
                }
            }

            atomic_store_explicit(
                &gMC263MetalSyncPending,
                false,
                memory_order_release
            );
        }
    );
}

/*
 * Minecraft 26.3 uses SDL_StartTextInput whenever a text box gains focus.
 * On iOS, SDL responds by focusing its own hidden UITextField, which
 * automatically opens the system keyboard.
 *
 * Amethyst already owns its own TrackedTextField and opens it manually,
 * so prevent only SDL's private field from becoming first responder.
 */
static BOOL MC263_BlockSDLAutomaticKeyboard(
    id self,
    SEL _cmd
) {
    return NO;
}

static void MC263_DisableSDLAutomaticKeyboard(void) {
    Class cls =
        NSClassFromString(@"SDLUITextField");

    if (cls == Nil) {
        NSLog(
            @"[MC263] SDLUITextField not found"
        );
        return;
    }

    SEL selector =
        @selector(becomeFirstResponder);

    Method method =
        class_getInstanceMethod(
            cls,
            selector
        );

    if (method == NULL) {
        NSLog(
            @"[MC263] SDLUITextField becomeFirstResponder not found"
        );
        return;
    }

    const char *types =
        method_getTypeEncoding(method);

    /*
     * SDLUITextField currently inherits becomeFirstResponder.
     * Add an override only to this class so we don't affect normal
     * UITextFields such as Amethyst's TrackedTextField.
     */
    if (
        class_addMethod(
            cls,
            selector,
            (IMP)MC263_BlockSDLAutomaticKeyboard,
            types
        )
    ) {
        NSLog(
            @"[MC263] Disabled SDL automatic keyboard"
        );
    } else {
        /*
         * Future SDL versions may implement it directly.
         * In that case replace SDLUITextField's implementation only.
         */
        Method ownMethod =
            class_getInstanceMethod(
                cls,
                selector
            );

        method_setImplementation(
            ownMethod,
            (IMP)MC263_BlockSDLAutomaticKeyboard
        );

        NSLog(
            @"[MC263] Disabled SDL automatic keyboard"
        );
    }
}

__attribute__((used, visibility("default")))
void AASDL_SetMainReady(void) {
    if (gMC263SDLHandle != NULL) {
        return;
    }

    NSString *path =
        [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:
                @"Frameworks/MC263/libSDL3.dylib"];

    gMC263SDLHandle =
        dlopen(
            path.UTF8String,
            RTLD_LAZY | RTLD_GLOBAL
        );

    if (gMC263SDLHandle == NULL) {
        NSLog(
            @"[MC263] Could not load libSDL3.dylib: %s",
            dlerror()
        );
        return;
    }

    MC263_DisableSDLAutomaticKeyboard();

    void (*setMainReady)(void) =
        (void (*)(void))
        dlsym(
            gMC263SDLHandle,
            "SDL_SetMainReady"
        );

    if (setMainReady != NULL) {
        setMainReady();

        NSLog(
            @"[MC263] SDL_SetMainReady called"
        );
    } else {
        NSLog(
            @"[MC263] SDL_SetMainReady symbol not found"
        );
    }
}


/*
 * Give SDL Amethyst's existing game surface.
 */
__attribute__((used, visibility("default")))
UIView *AASDL_GetHostView(void) {
    return [SurfaceViewController surface];
}


/*
 * This must return framebuffer PIXELS, not UIKit points.
 */
__attribute__((used, visibility("default")))
void AASDL_GetFramebufferSize(
    int *w,
    int *h
) {
    MC263_GetHostFramebufferSize(w, h);

    MC263_ScheduleMetalLayerSync();
}


__attribute__((used, visibility("default")))
void AASDL_NoteWindow(
    uint32_t windowID,
    int w,
    int h
) {
    gMC263WindowID = windowID;

    if (w > 0) {
        gMC263WindowWidth = w;
    }

    if (h > 0) {
        gMC263WindowHeight = h;
    }

    int framebufferWidth = 0;
    int framebufferHeight = 0;

    MC263_GetHostFramebufferSize(
        &framebufferWidth,
        &framebufferHeight
    );

    /*
     * The input bridge operates in framebuffer coordinates too,
     * so give it the pixel dimensions rather than SDL's point size.
     */
    MC263Input_NoteWindow(
        windowID,
        framebufferWidth,
        framebufferHeight
    );

    MC263_ScheduleMetalLayerSync();

    NSLog(
        @"[MC263] SDL window id=%u points=%dx%d framebuffer=%dx%d",
        windowID,
        w,
        h,
        framebufferWidth,
        framebufferHeight
    );
}


__attribute__((used, visibility("default")))
void AASDL_NoteGrab(bool grabbed) {
    gMC263LastGrabTime =
        CACurrentMediaTime();

    MC263Input_NoteGrab(grabbed);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            UIViewController *root =
                UIWindow.mainWindow.rootViewController;

            if (
                [root
                    isKindOfClass:
                        SurfaceViewController.class]
            ) {
                [(SurfaceViewController *)root
                    updateGrabState];
            }
        }
    );
}


__attribute__((used, visibility("default")))
void AASDL_NoteCursorShape(int shape) {
    (void)shape;
}


__attribute__((used, visibility("default")))
void AASDL_NoteKey(void) {
    gMC263LastKeyTime =
        CACurrentMediaTime();
}


__attribute__((used, visibility("default")))
double AASDL_LastGrabChangeAge(void) {
    if (gMC263LastGrabTime <= 0.0) {
        return 9999.0;
    }

    return
        CACurrentMediaTime() -
        gMC263LastGrabTime;
}


__attribute__((used, visibility("default")))
bool AASDL_HardwareKeySeenWithin(
    double seconds
) {
    return
        gMC263LastKeyTime > 0.0 &&
        (
            CACurrentMediaTime() -
            gMC263LastKeyTime
        ) <= seconds;
}

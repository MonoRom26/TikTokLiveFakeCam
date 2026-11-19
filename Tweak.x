#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>

static BOOL gFakeCamEnabled = NO;
static BOOL gPromptShownThisSession = NO;
static NSString *gSelectedVideoPath = nil;

// Frame reader state
static AVAssetReader *gAssetReader = nil;
static AVAssetReaderTrackOutput *gTrackOutput = nil;
static CMSampleBufferRef gLastSampleBuffer = NULL;
static NSTimeInterval gLastFrameTime = 0;
static NSTimeInterval gFrameInterval = 1.0 / 30.0;
static OSType gTargetPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
static dispatch_queue_t gVideoQueue = nil;

#pragma mark - Helper Functions

static NSString *GetSavedVideoPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths.firstObject stringByAppendingPathComponent:@"fakecam_live.mp4"];
}

static UIViewController *TopMostViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

static void ResetAssetReader(void) {
    if (gAssetReader) {
        [gAssetReader cancelReading];
        gAssetReader = nil;
        gTrackOutput = nil;
    }
    if (gLastSampleBuffer) {
        CFRelease(gLastSampleBuffer);
        gLastSampleBuffer = NULL;
    }
}

static BOOL SetupAssetReader(void) {
    ResetAssetReader();
    if (!gSelectedVideoPath || ![[NSFileManager defaultManager] fileExistsAtPath:gSelectedVideoPath]) {
        return NO;
    }

    NSURL *url = [NSURL fileURLWithPath:gSelectedVideoPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) return NO;

    float fps = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30.0f;
    gFrameInterval = 1.0 / fps;

    NSError *error = nil;
    gAssetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error || !gAssetReader) return NO;

    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(gTargetPixelFormat)
    };

    gTrackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
    gTrackOutput.alwaysCopiesSampleData = NO;

    if ([gAssetReader canAddOutput:gTrackOutput]) {
        [gAssetReader addOutput:gTrackOutput];
        return [gAssetReader startReading];
    }
    return NO;
}

static CMSampleBufferRef CreateRetimedSampleBuffer(CMSampleBufferRef sourceBuffer, CMTime presentationTime) {
    if (!sourceBuffer) return NULL;
    CMSampleTimingInfo timingInfo;
    timingInfo.duration = CMSampleBufferGetDuration(sourceBuffer);
    timingInfo.presentationTimeStamp = presentationTime;
    timingInfo.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef newBuffer = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sourceBuffer, 1, &timingInfo, &newBuffer);
    return newBuffer;
}

static CMSampleBufferRef NextVideoSampleBuffer(CMTime originalPTS) {
    if (!gAssetReader || gAssetReader.status != AVAssetReaderStatusReading) {
        if (!SetupAssetReader()) return NULL;
    }

    NSTimeInterval now = CACurrentMediaTime();
    if (gLastSampleBuffer && (now - gLastFrameTime) < gFrameInterval) {
        return CreateRetimedSampleBuffer(gLastSampleBuffer, originalPTS);
    }

    CMSampleBufferRef nextBuffer = [gTrackOutput copyNextSampleBuffer];
    if (!nextBuffer) {
        // Loop video seamlessly when it reaches the end
        if (SetupAssetReader()) {
            nextBuffer = [gTrackOutput copyNextSampleBuffer];
        }
    }

    if (nextBuffer) {
        if (gLastSampleBuffer) CFRelease(gLastSampleBuffer);
        gLastSampleBuffer = nextBuffer;
        gLastFrameTime = now;
        return CreateRetimedSampleBuffer(gLastSampleBuffer, originalPTS);
    }
    return NULL;
}

#pragma mark - Photo Picker & Popup Controller

@interface FakeCamPickerDelegate : NSObject <PHPickerViewControllerDelegate>
+ (instancetype)sharedInstance;
- (void)presentSourceMenu;
@end

@implementation FakeCamPickerDelegate

+ (instancetype)sharedInstance {
    static FakeCamPickerDelegate *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FakeCamPickerDelegate alloc] init];
        gVideoQueue = dispatch_queue_create("com.custom.fakecam.videoqueue", DISPATCH_QUEUE_SERIAL);
        gSelectedVideoPath = GetSavedVideoPath();
    });
    return instance;
}

- (void)presentSourceMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = TopMostViewController();
        if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TikTok LIVE Video Source"
                                                                       message:@"Choose your video feed for LIVE:"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];

        UIAlertAction *cameraAction = [UIAlertAction actionWithTitle:@"Use Live Camera"
                                                               style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction *action) {
            dispatch_sync(gVideoQueue, ^{
                gFakeCamEnabled = NO;
                ResetAssetReader();
            });
        }];

        UIAlertAction *photoAction = [UIAlertAction actionWithTitle:@"Select Video from Photos"
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *action) {
            [self openPhotoPickerFrom:topVC];
        }];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];

        [alert addAction:cameraAction];
        [alert addAction:photoAction];
        [alert addAction:cancelAction];

        // iPad popover safety
        if (alert.popoverPresentationController) {
            alert.popoverPresentationController.sourceView = topVC.view;
            alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(topVC.view.bounds), CGRectGetMidY(topVC.view.bounds), 1, 1);
        }

        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

- (void)openPhotoPickerFrom:(UIViewController *)presenter {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.selectionLimit = 1;
    config.filter = [PHPickerFilter videosFilter];

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *result = results.firstObject;
    if (!result) return;

    NSItemProvider *provider = result.itemProvider;
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *error) {
            if (!url || error) return;

            NSString *destPath = GetSavedVideoPath();
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:destPath error:nil];

            NSError *copyError = nil;
            if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:&copyError]) {
                dispatch_sync(gVideoQueue, ^{
                    gSelectedVideoPath = destPath;
                    gFakeCamEnabled = YES;
                    SetupAssetReader();
                });
            }
        }];
    }
}

@end

#pragma mark - LIVE Option Detection & Camera Hooking

static BOOL ViewContainsLiveText(UIView *view, int depth) {
    if (!view || depth > 4) return NO;

    NSString *accLabel = view.accessibilityLabel.uppercaseString;
    if ([accLabel isEqualToString:@"LIVE"] || [accLabel containsString:@"GO LIVE"]) {
        return YES;
    }

    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)view).text.uppercaseString;
        if ([text isEqualToString:@"LIVE"]) return YES;
    }

    for (UIView *subview in view.subviews) {
        if (ViewContainsLiveText(subview, depth + 1)) return YES;
    }
    return NO;
}

// Original IMPs, keyed by delegate class (TikTok may use more than one delegate class)
static NSMutableDictionary<NSValue *, NSValue *> *gOrigIMPs = nil;

static IMP OrigIMPForObject(id obj) {
    @synchronized (gOrigIMPs) {
        for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
            NSValue *v = gOrigIMPs[[NSValue valueWithPointer:(__bridge void *)c]];
            if (v) return (IMP)[v pointerValue];
        }
    }
    return NULL;
}

typedef void (*CaptureOutputIMP)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);

static void hooked_captureOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    CaptureOutputIMP orig = (CaptureOutputIMP)OrigIMPForObject(self);
    if (!orig) return;

    if (gFakeCamEnabled && sampleBuffer) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (imageBuffer) {
            gTargetPixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
        }

        __block CMSampleBufferRef fakeBuffer = NULL;
        CMTime origPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

        dispatch_sync(gVideoQueue, ^{
            fakeBuffer = NextVideoSampleBuffer(origPTS);
        });

        if (fakeBuffer) {
            orig(self, _cmd, output, fakeBuffer, connection);
            CFRelease(fakeBuffer);
            return;
        }
    }

    // Fake cam off (or no frame available): pass the real camera frame through
    orig(self, _cmd, output, sampleBuffer, connection);
}

static void HookDelegateClass(Class cls) {
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    @synchronized (gOrigIMPs) {
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)hooked_captureOutput) return; // already hooked (inherited)

        NSValue *key = [NSValue valueWithPointer:(__bridge void *)cls];
        if (gOrigIMPs[key]) return;

        gOrigIMPs[key] = [NSValue valueWithPointer:(void *)orig];
        class_replaceMethod(cls, sel, (IMP)hooked_captureOutput, method_getTypeEncoding(m));
    }
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate) {
        HookDelegateClass([delegate class]);
    }
    %orig;
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (gPromptShownThisSession) return;

    if (ViewContainsLiveText(self.view, 0)) {
        gPromptShownThisSession = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[FakeCamPickerDelegate sharedInstance] presentSourceMenu];
        });
    }
}

%end

%ctor {
    @autoreleasepool {
        gOrigIMPs = [NSMutableDictionary dictionary];
        [FakeCamPickerDelegate sharedInstance]; // creates gVideoQueue + loads saved path
        %init;
    }
}

// Voice-over translation (Yandex VOT) for the main player.
//
// Flow per video: ask Yandex for a translation; when Yandex asks for the
// original audio (AUDIO_REQUESTED) download the audio track with the SABR
// or direct downloader and upload it in chunks; poll until the dubbed mp3 is
// ready; cache it locally and play it on a second AVPlayer that follows the
// YouTube player's time, rate and pause state while the original is ducked.
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"
#import "../Downloads/DirectDownloader.h"
#import "../Downloads/DownloadCoordinator.h"
#import "../Downloads/DownloadLog.h"
#import "../Downloads/SABRDownloader.h"
#import "../Downloads/StreamResolver.h"
#import "VOTClient.h"
#import "YandexAccount.h"
#import "TranslationPanel.h"

#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, YTKACETranslationState) {
    YTKACETranslationStateIdle,
    YTKACETranslationStateWorking,
    YTKACETranslationStateActive,
};

static NSString * const YTKACETranslationButtonIdentifier = @"YTKACE Translate";
static const NSTimeInterval YTKACETranslationTimeout = 20.0 * 60.0;
static const double YTKACETranslationMaxDuration = 4.0 * 60.0 * 60.0;
static const NSTimeInterval YTKACETranslationSyncInterval = 0.25;
static const double YTKACETranslationDriftLimit = 0.35;
static const NSTimeInterval YTKACETranslationCacheLifetime = 7.0 * 24.0 * 60.0 * 60.0;

// Yandex refuses live voices only through a Russian error message ("only the
// standard voice can be used when translating from <language>"); there is no
// status code for it. vot.js detects the refusal by the words "standard voice",
// which is this marker.
static NSString * const YTKACELivelyVoiceRefusalMarker = @"обычная озвучка";

#pragma mark - Original audio ducking

// The HAM player renders audio through AVSampleBufferAudioRenderer objects
// attached to an AVSampleBufferRenderSynchronizer. Tracking them lets the
// original track be lowered without touching YouTube's own volume state.
static IMP OriginalSynchronizerAddRenderer;
static IMP OriginalRendererSetVolume;
static NSHashTable *YTKACETrackedRenderers;
static float YTKACEOriginalVolumeFactor = 1.0f;
static const void *YTKACERequestedVolumeAssociation = &YTKACERequestedVolumeAssociation;

static float YTKACERequestedVolume(id renderer) {
    NSNumber *requested = objc_getAssociatedObject(renderer, YTKACERequestedVolumeAssociation);
    return requested != nil ? requested.floatValue : 1.0f;
}

static void YTKACEApplyRendererVolume(id renderer) {
    if (OriginalRendererSetVolume == NULL) return;
    ((void (*)(id, SEL, float))OriginalRendererSetVolume)(
        renderer, @selector(setVolume:),
        YTKACERequestedVolume(renderer) * YTKACEOriginalVolumeFactor);
}

static void YTKACERendererSetVolume(id receiver, SEL selector, float volume) {
    objc_setAssociatedObject(receiver, YTKACERequestedVolumeAssociation, @(volume),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (OriginalRendererSetVolume != NULL) {
        ((void (*)(id, SEL, float))OriginalRendererSetVolume)(
            receiver, selector, volume * YTKACEOriginalVolumeFactor);
    }
}

static void YTKACESynchronizerAddRenderer(id receiver, SEL selector, id renderer) {
    if (OriginalSynchronizerAddRenderer != NULL) {
        ((void (*)(id, SEL, id))OriginalSynchronizerAddRenderer)(receiver, selector, renderer);
    }
    if (![renderer isKindOfClass:AVSampleBufferAudioRenderer.class]) return;
    @synchronized (YTKACETrackedRenderers) {
        [YTKACETrackedRenderers addObject:renderer];
    }
    if (YTKACEOriginalVolumeFactor < 1.0f) YTKACEApplyRendererVolume(renderer);
}

static void YTKACESetOriginalVolumeFactor(float factor, UIView *playerView) {
    YTKACEOriginalVolumeFactor = MAX(0.0f, MIN(1.0f, factor));
    NSArray *renderers;
    @synchronized (YTKACETrackedRenderers) {
        renderers = YTKACETrackedRenderers.allObjects;
    }
    for (id renderer in renderers) {
        YTKACEApplyRendererVolume(renderer);
    }
    // HLS playback mode uses a plain AVPlayer instead of the HAM renderers.
    UIView *root = playerView;
    while (root.superview != nil) root = root.superview;
    NSMutableArray<CALayer *> *pending = root != nil ? [NSMutableArray arrayWithObject:root.layer]
                                                     : [NSMutableArray array];
    while (pending.count != 0) {
        CALayer *layer = pending.lastObject;
        [pending removeLastObject];
        if ([layer isKindOfClass:AVPlayerLayer.class]) {
            ((AVPlayerLayer *)layer).player.volume = YTKACEOriginalVolumeFactor;
        }
        [pending addObjectsFromArray:layer.sublayers ?: @[]];
    }
}

#pragma mark - Helpers

static id YTKACETranslationMessage(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static double YTKACETranslationDouble(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return 0.0;
    double value = ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
    return isfinite(value) ? value : 0.0;
}

// Returns 0 when the player exposes no usable rate getter.
static double YTKACEPlayerRate(id controller) {
    for (NSString *name in @[@"playbackRate", @"currentPlaybackRate"]) {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [controller methodSignatureForSelector:selector];
        if (signature == nil || ![controller respondsToSelector:selector]) continue;
        const char type = signature.methodReturnType[0];
        double rate = 0.0;
        if (type == 'd') {
            rate = ((double (*)(id, SEL))objc_msgSend)(controller, selector);
        } else if (type == 'f') {
            rate = ((float (*)(id, SEL))objc_msgSend)(controller, selector);
        }
        if (isfinite(rate) && rate >= 0.25 && rate <= 5.0) return rate;
    }
    return 0.0;
}

static NSString *YTKACEControllerVideoID(id controller) {
    id value = YTKACETranslationMessage(controller, @"currentVideoID");
    return [value isKindOfClass:NSString.class] && [value length] != 0 ? value : nil;
}

static NSString *YTKACETranslationTargetLanguage(void) {
    id value = YTKACEPreferenceObject(YTKACETranslationLanguageKey);
    NSArray *supported = @[@"ru", @"en", @"kk"];
    return [value isKindOfClass:NSString.class] && [supported containsObject:value] ? value : @"ru";
}

static double YTKACETranslationPercent(NSString *key, double fallback) {
    id value = YTKACEPreferenceObject(key);
    double percent = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
    return MAX(0.0, MIN(100.0, percent)) / 100.0;
}

// Spoken language from the auto-generated (ASR) caption track. Sending the real
// language instead of "auto" lets Yandex reuse translations other users made.
static NSString *YTKACESpokenLanguage(id playerResponse) {
    if (playerResponse == nil) return nil;
    NSArray *supported = @[@"en", @"ru", @"zh", @"ko", @"ar", @"fr", @"it", @"es",
                           @"de", @"ja", @"lt", @"lv"];
    for (id track in YTKACECaptionTracksForResponse(playerResponse) ?: @[]) {
        id kind = YTKACETranslationMessage(track, @"kind");
        id vssID = YTKACETranslationMessage(track, @"vssId");
        BOOL automatic = ([kind isKindOfClass:NSString.class] && [kind isEqualToString:@"asr"]) ||
            ([vssID isKindOfClass:NSString.class] && [vssID hasPrefix:@"a."]);
        if (!automatic) continue;
        NSString *language = YTKACECaptionTrackLanguage(track);
        NSString *base = [[language componentsSeparatedByString:@"-"].firstObject lowercaseString];
        if ([supported containsObject:base]) return base;
    }
    return nil;
}

static YTKACEStreamOption *YTKACETranslationAudioOption(NSArray<YTKACEStreamOption *> *options) {
    NSMutableArray<YTKACEStreamOption *> *audio = [NSMutableArray array];
    NSMutableArray<YTKACEStreamOption *> *original = [NSMutableArray array];
    for (YTKACEStreamOption *option in options) {
        if (!option.isAudioOnly) continue;
        [audio addObject:option];
        if (option.isDefaultAudio) [original addObject:option];
    }
    NSArray<YTKACEStreamOption *> *pool = original.count != 0 ? original : audio;
    // itag 140 (AAC-LC in MP4) is the format Yandex accepted in testing.
    // Otherwise prefer MP4 audio, then the smallest bitrate: speech recognition
    // does not need more and the upload stays short.
    YTKACEStreamOption *best = nil;
    for (YTKACEStreamOption *option in pool) {
        if (option.itag == 140) return option;
        BOOL mp4 = [option.mimeType containsString:@"mp4"];
        BOOL bestMP4 = [best.mimeType containsString:@"mp4"];
        if (best == nil || (mp4 && !bestMP4) ||
            (mp4 == bestMP4 && option.bitrate > 0 && option.bitrate < best.bitrate)) {
            best = option;
        }
    }
    return best;
}

static NSURL *YTKACETranslationCacheDirectory(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [caches URLByAppendingPathComponent:@"YTKACE-Translations" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                            attributes:nil error:nil];
    return directory;
}

static NSURL *YTKACETranslationCacheURL(NSString *videoID, NSString *language, BOOL livelyVoice) {
    return [YTKACETranslationCacheDirectory() URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@_%@%@.mp3", videoID, language, livelyVoice ? @"_live" : @""]];
}

static void YTKACEPurgeOldTranslations(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSURL *> *files = [manager contentsOfDirectoryAtURL:YTKACETranslationCacheDirectory()
                                     includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                        options:0 error:nil];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-YTKACETranslationCacheLifetime];
    for (NSURL *file in files) {
        NSDate *modified = nil;
        [file getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (modified != nil && [modified compare:cutoff] == NSOrderedAscending) {
            [manager removeItemAtURL:file error:nil];
        }
    }
}

#pragma mark - Coordinator

@interface YTKACETranslationCoordinator : NSObject <YTKACETranslationPanelHost>
+ (instancetype)sharedCoordinator;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *button;
@property(nonatomic, weak) YTKACETranslationPanelController *panel;
@property(nonatomic, weak) id playerController;
@property(nonatomic, assign) YTKACETranslationState state;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *videoURL;
@property(nonatomic, copy) NSString *language;
@property(nonatomic, copy) NSString *sourceLanguage;
@property(nonatomic, copy) NSString *videoTitle;
@property(nonatomic, assign) BOOL livelyVoice;
@property(nonatomic, copy) NSString *spokenLanguage;
@property(nonatomic, assign) double duration;
@property(nonatomic, strong) NSDate *startDate;
@property(nonatomic, strong) id playerResponse;
@property(nonatomic, assign) NSUInteger uploadAttempts;
@property(nonatomic, assign) BOOL audioUploaded;
@property(nonatomic, assign) BOOL failedAudioSent;
@property(nonatomic, assign) NSUInteger networkFailures;
@property(nonatomic, assign) NSUInteger serverRetries;
@property(nonatomic, assign) NSInteger lastAnnouncedMinutes;
@property(nonatomic, strong) id audioTask;
@property(nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) NSTimer *syncTimer;
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, assign) double lastMediaTime;
@property(nonatomic, assign) CFTimeInterval lastSampleTime;
@property(nonatomic, assign) double estimatedRate;
@property(nonatomic, assign) NSUInteger stillTicks;
@property(nonatomic, assign) BOOL originalPlaying;
@property(nonatomic, assign) BOOL seeking;
@end

@implementation YTKACETranslationCoordinator

+ (instancetype)sharedCoordinator {
    static YTKACETranslationCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTKACETranslationCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playbackTimeChanged:)
                                                   name:@"YTKACEPlaybackTimeDidChange"
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(preferencesChanged:)
                                                   name:YTKACEPreferencesDidChangeNotification
                                                 object:nil];
    }
    return self;
}

#pragma mark Player context

- (id)controllerFromOverlay {
    id events = YTKACETranslationMessage(self.overlay, @"eventsDelegate");
    id parent = YTKACETranslationMessage(events, @"parentViewController");
    return YTKACETranslationMessage(parent, @"activeVideoPlayerOverlay") != nil ? parent : nil;
}

- (id)currentController {
    return [self controllerFromOverlay] ?: self.playerController;
}

- (void)playbackTimeChanged:(NSNotification *)notification {
    if (YTKACEPlayerIsShorts(notification.object)) return;
    self.playerController = notification.object;
}

- (void)preferencesChanged:(NSNotification *)notification {
    NSString *key = notification.userInfo[@"key"];
    if ([key isEqualToString:YTKACETranslationKey] && !YTKACEFeatureEnabled(YTKACETranslationKey)) {
        [self stopWithNotice:nil];
    } else if ([key isEqualToString:YTKACETranslationLanguageKey] &&
               self.state != YTKACETranslationStateIdle &&
               ![self.language isEqualToString:YTKACETranslationTargetLanguage()]) {
        [self stopWithNotice:YTKACELocalized(@"Translation language changed. Tap translate again.")];
    } else if (self.state == YTKACETranslationStateActive &&
               ([key isEqualToString:YTKACETranslationOriginalVolumeKey] ||
                [key isEqualToString:YTKACETranslationVolumeKey])) {
        [self applyVolumes];
    }
    [self updateButton];
}

#pragma mark Button

- (void)updateButton {
    [self.panel refresh];
    UIButton *button = self.button;
    if (button == nil) return;
    button.hidden = !YTKACEFeatureEnabled(YTKACETranslationKey);
    BOOL working = self.state == YTKACETranslationStateWorking;
    // The overlay lays out often; restarting the pulse each time makes it stutter.
    BOOL pulsing = [button.layer animationForKey:@"YTKACETranslationPulse"] != nil;
    if (working && !pulsing) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @1.0;
        pulse.toValue = @0.35;
        pulse.duration = 0.8;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        pulse.removedOnCompletion = NO;
        [button.layer addAnimation:pulse forKey:@"YTKACETranslationPulse"];
    } else if (!working && pulsing) {
        [button.layer removeAnimationForKey:@"YTKACETranslationPulse"];
    }
    switch (self.state) {
        case YTKACETranslationStateIdle:
            button.tintColor = UIColor.whiteColor;
            break;
        case YTKACETranslationStateWorking:
            button.tintColor = UIColor.systemYellowColor;
            break;
        case YTKACETranslationStateActive:
            button.tintColor = UIColor.systemRedColor;
            break;
    }
    button.accessibilityLabel = self.state == YTKACETranslationStateActive
        ? YTKACELocalized(@"Turn off translation")
        : YTKACELocalized(@"Voice-over Translation");
}

- (void)toggleTranslation {
    if (self.state == YTKACETranslationStateIdle) {
        [self start];
    } else {
        [self stopWithNotice:YTKACELocalized(@"Translation off")];
    }
}

- (void)buttonLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    UIViewController *presenter = YTKACETranslationPresenter();
    if (presenter == nil || self.panel.presentingViewController != nil) return;
    YTKACETranslationPanelController *panel =
        [[YTKACETranslationPanelController alloc] initWithHost:self];
    self.panel = panel;
    [presenter presentViewController:panel animated:YES completion:nil];
}

#pragma mark Panel host

- (BOOL)translationRunning {
    return self.state != YTKACETranslationStateIdle;
}

- (NSString *)translationStatusText {
    switch (self.state) {
        case YTKACETranslationStateIdle:
            return YTKACELocalized(@"Translation off");
        case YTKACETranslationStateWorking:
            return YTKACELocalized(@"Yandex is translating…");
        case YTKACETranslationStateActive:
            return YTKACELocalized(self.livelyVoice ? @"Translation on · live voice"
                                                    : @"Translation on · standard voice");
    }
}

#pragma mark Lifecycle

- (void)start {
    id controller = [self currentController];
    NSString *videoID = YTKACEControllerVideoID(controller) ?: YTKACELastVideoID();
    if (controller == nil || videoID.length == 0) {
        YTKACEShowNotice(YTKACELocalized(@"Start the video, then tap translate."));
        return;
    }
    double duration = YTKACETranslationDouble(controller, @"currentVideoTotalMediaTime");
    if (duration > YTKACETranslationMaxDuration) {
        YTKACEShowNotice(YTKACELocalized(@"Yandex cannot translate videos longer than 4 hours."));
        return;
    }
    [self resetWork];
    self.playerController = controller;
    self.videoID = videoID;
    self.videoURL = [@"https://youtu.be/" stringByAppendingString:videoID];
    self.language = YTKACETranslationTargetLanguage();
    // Yandex offers live voices only for translation into Russian.
    self.livelyVoice = YTKACEFeatureEnabled(YTKACETranslationLivelyVoiceKey) &&
        [self.language isEqualToString:@"ru"];
    // vot.js sends 310 seconds when the duration is unknown.
    self.duration = duration > 0.0 ? duration : 310.0;
    self.startDate = NSDate.date;
    self.state = YTKACETranslationStateWorking;
    [self updateButton];
    YTKACEDownloadLog(@"vot", @"start video=%@ lang=%@ lively=%d duration=%.0f",
                      videoID, self.language, self.livelyVoice, self.duration);

    NSURL *cached = YTKACETranslationCacheURL(videoID, self.language, self.livelyVoice);
    if ([NSFileManager.defaultManager fileExistsAtPath:cached.path]) {
        [self startPlaybackWithFile:cached];
        return;
    }
    YTKACEShowNotice(YTKACELocalized(@"Requesting translation from Yandex…"));
    NSUInteger generation = self.generation;
    __weak YTKACETranslationCoordinator *weakSelf = self;
    YTKACEResolvePlayerResponse(videoID, ^(id response, __unused NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACETranslationCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil || generation != strongSelf.generation) return;
            strongSelf.playerResponse = response;
            NSString *spoken = YTKACESpokenLanguage(response);
            if ([spoken isEqualToString:strongSelf.language]) {
                [strongSelf stopWithNotice:YTKACELocalized(@"The video is already in this language.")];
                return;
            }
            // Live voices refuse "auto"; vot.js asks for English in that case.
            strongSelf.spokenLanguage = spoken;
            strongSelf.sourceLanguage = spoken ?: (strongSelf.livelyVoice ? @"en" : @"auto");
            strongSelf.videoTitle = response != nil
                ? [YTKACEStreamResolver titleFromPlayerResponse:response] : nil;
            [strongSelf requestTranslation];
        });
    });
}

// Cancels in-flight work and invalidates stale callbacks via the generation.
- (void)resetWork {
    self.generation += 1;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.syncTimer invalidate];
    self.syncTimer = nil;
    if ([self.audioTask respondsToSelector:@selector(cancel)]) {
        [self.audioTask cancel];
    }
    self.audioTask = nil;
    [self.downloadTask cancel];
    self.downloadTask = nil;
    [self.player pause];
    self.player = nil;
    self.playerResponse = nil;
    self.uploadAttempts = 0;
    self.audioUploaded = NO;
    self.failedAudioSent = NO;
    self.networkFailures = 0;
    self.serverRetries = 0;
    self.lastAnnouncedMinutes = -1;
    self.stillTicks = 0;
    self.originalPlaying = NO;
    self.seeking = NO;
}

- (void)stopWithNotice:(NSString *)notice {
    BOOL wasRunning = self.state != YTKACETranslationStateIdle;
    [self resetWork];
    self.state = YTKACETranslationStateIdle;
    YTKACESetOriginalVolumeFactor(1.0f, self.overlay);
    [self updateButton];
    if (wasRunning && notice.length != 0) YTKACEShowNotice(notice);
}

- (void)failWithMessage:(NSString *)message {
    YTKACEDownloadLog(@"vot", @"failed video=%@: %@", self.videoID, message);
    [self stopWithNotice:[NSString stringWithFormat:@"%@: %@",
        YTKACELocalized(@"Translation failed"), message]];
}

- (BOOL)isCurrent:(NSUInteger)generation {
    return generation == self.generation && self.state == YTKACETranslationStateWorking;
}

#pragma mark Translation requests

- (void)requestTranslation {
    if (-self.startDate.timeIntervalSinceNow > YTKACETranslationTimeout) {
        [self failWithMessage:YTKACELocalized(@"Yandex is taking too long. Try again later.")];
        return;
    }
    NSUInteger generation = self.generation;
    __weak YTKACETranslationCoordinator *weakSelf = self;
    [YTKACEVOTClient.sharedClient translateVideoURL:self.videoURL
                                           duration:self.duration
                                    requestLanguage:self.sourceLanguage ?: @"auto"
                                   responseLanguage:self.language
                                        livelyVoice:self.livelyVoice
                                         oauthToken:YTKACEYandexAccount.sharedAccount.token
                                              title:self.videoTitle
                                         completion:^(YTKACEVOTTranslation *translation,
                                                      NSError *error) {
        YTKACETranslationCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil || ![strongSelf isCurrent:generation]) return;
        if (error != nil) {
            strongSelf.networkFailures += 1;
            if (strongSelf.networkFailures >= 3) {
                [strongSelf failWithMessage:error.localizedDescription];
            } else {
                [strongSelf schedulePollAfter:5.0];
            }
            return;
        }
        strongSelf.networkFailures = 0;
        [strongSelf handleTranslation:translation];
    }];
}

- (void)handleTranslation:(YTKACEVOTTranslation *)translation {
    switch (translation.status) {
        case YTKACEVOTStatusFinished:
        case YTKACEVOTStatusPartContent:
            if (translation.audioURL != nil && translation.remainingTime < 1) {
                [self downloadTranslationFrom:translation.audioURL];
            } else {
                [self announceWait:translation.remainingTime];
                [self schedulePollAfter:translation.remainingTime];
            }
            break;
        case YTKACEVOTStatusWaiting:
        case YTKACEVOTStatusLongWaiting:
            [self announceWait:translation.remainingTime];
            [self schedulePollAfter:translation.remainingTime];
            break;
        case YTKACEVOTStatusAudioRequested:
            if (self.audioUploaded) {
                // Yandex keeps reporting AUDIO_REQUESTED briefly after the upload.
                [self schedulePollAfter:translation.remainingTime];
            } else if (self.uploadAttempts < 2) {
                self.uploadAttempts += 1;
                [self provideAudioForTranslation:translation.translationID];
            } else if (!self.failedAudioSent) {
                [self sendFailedAudioForTranslation:translation.translationID];
            } else {
                [self schedulePollAfter:translation.remainingTime];
            }
            break;
        case YTKACEVOTStatusSessionRequired:
            if (self.livelyVoice) {
                [self fallBackToStandardVoice:YTKACEYandexAccount.sharedAccount.token != nil
                    ? YTKACELocalized(@"Yandex sign-in expired. Sign in again for live voices.")
                    : YTKACELocalized(@"Sign in to Yandex for live voices.")];
            } else {
                [self failWithMessage:YTKACELocalized(@"Yandex requires an account for this video.")];
            }
            break;
        case YTKACEVOTStatusFailed:
            if (self.livelyVoice &&
                [translation.message.lowercaseString containsString:YTKACELivelyVoiceRefusalMarker]) {
                [self fallBackToStandardVoice:
                    YTKACELocalized(@"No live voice for this video. Using the standard voice.")];
                break;
            }
            [[fallthrough]];
        default:
            if (translation.shouldRetry && self.serverRetries < 1) {
                self.serverRetries += 1;
                [self schedulePollAfter:10.0];
            } else {
                [self failWithMessage:translation.message.length != 0
                    ? translation.message
                    : YTKACELocalized(@"Yandex could not translate this video.")];
            }
            break;
    }
}

// Yandex refused the live voice (unsupported pair or sign-in required):
// continue the same video with the standard voice instead of failing.
- (void)fallBackToStandardVoice:(NSString *)notice {
    YTKACEDownloadLog(@"vot", @"lively fallback: %@", notice);
    self.livelyVoice = NO;
    self.sourceLanguage = self.spokenLanguage ?: @"auto";
    self.uploadAttempts = 0;
    self.audioUploaded = NO;
    self.failedAudioSent = NO;
    self.serverRetries = 0;
    NSURL *cached = YTKACETranslationCacheURL(self.videoID, self.language, NO);
    if ([NSFileManager.defaultManager fileExistsAtPath:cached.path]) {
        YTKACEShowNotice(notice);
        [self startPlaybackWithFile:cached];
        return;
    }
    YTKACEShowNotice(notice);
    [self requestTranslation];
}

- (void)announceWait:(NSInteger)remaining {
    NSInteger minutes = remaining > 0 ? MAX(1, (remaining + 59) / 60) : 0;
    if (minutes == self.lastAnnouncedMinutes) return;
    self.lastAnnouncedMinutes = minutes;
    YTKACEShowNotice(minutes > 0
        ? [NSString stringWithFormat:YTKACELocalized(@"Yandex is translating, about %ld min"),
           (long)minutes]
        : YTKACELocalized(@"Yandex is translating…"));
}

- (void)schedulePollAfter:(double)seconds {
    [self.pollTimer invalidate];
    NSTimeInterval delay = MAX(5.0, MIN(20.0, seconds > 0 ? seconds : 10.0));
    NSUInteger generation = self.generation;
    __weak YTKACETranslationCoordinator *weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO
                                                       block:^(__unused NSTimer *timer) {
        YTKACETranslationCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil || ![strongSelf isCurrent:generation]) return;
        [strongSelf requestTranslation];
    }];
}

#pragma mark Original audio upload

- (void)provideAudioForTranslation:(NSString *)translationID {
    YTKACEShowNotice(YTKACELocalized(@"Preparing audio for Yandex…"));
    NSUInteger generation = self.generation;
    __weak YTKACETranslationCoordinator *weakSelf = self;
    void (^finish)(NSURL *, NSError *) = ^(NSURL *audioURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACETranslationCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil || ![strongSelf isCurrent:generation]) {
                if (audioURL != nil) [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
                return;
            }
            strongSelf.audioTask = nil;
            if (audioURL == nil) {
                YTKACEDownloadLog(@"vot", @"audio unavailable: %@", error.localizedDescription);
                [strongSelf sendFailedAudioForTranslation:translationID];
                return;
            }
            [strongSelf uploadAudio:audioURL translationID:translationID];
        });
    };

    id response = self.playerResponse;
    YTKACEStreamOption *option = response != nil
        ? YTKACETranslationAudioOption([YTKACEStreamResolver audioOptionsFromPlayerResponse:response])
        : nil;
    if (option == nil) {
        [self downloadDirectAudioWithCompletion:finish];
        return;
    }
    YTKACEStreamOption *noVideo = nil;
    NSString *identifier = [@"translation-" stringByAppendingString:self.videoID];
    self.audioTask = [YTKACESABRDownloader downloadPlayerResponse:response
        videoOption:noVideo audioOption:option audioOnly:YES videoID:self.videoID
        identifier:identifier progress:nil
        completion:^(__unused NSURL *videoURL, NSURL *audioURL, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                YTKACETranslationCoordinator *strongSelf = weakSelf;
                if (audioURL != nil || strongSelf == nil || ![strongSelf isCurrent:generation]) {
                    finish(audioURL, error);
                    return;
                }
                YTKACEDownloadLog(@"vot", @"sabr audio failed: %@, trying direct",
                                  error.localizedDescription);
                [strongSelf downloadDirectAudioWithCompletion:finish];
            });
        }];
}

- (void)downloadDirectAudioWithCompletion:(void (^)(NSURL *, NSError *))finish {
    NSString *videoID = self.videoID;
    NSString *identifier = [@"translation-direct-" stringByAppendingString:videoID];
    NSUInteger generation = self.generation;
    __weak YTKACETranslationCoordinator *weakSelf = self;
    [YTKACEDirectDownloader fetchOptionsForVideoID:videoID
                                        completion:^(NSArray<YTKACEStreamOption *> *options) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACETranslationCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil || ![strongSelf isCurrent:generation]) return;
            YTKACEStreamOption *option = YTKACETranslationAudioOption(options);
            if (option == nil) {
                finish(nil, nil);
                return;
            }
            strongSelf.audioTask = [YTKACEDirectDownloader downloadVideoID:videoID
                videoOption:nil audioOption:option audioOnly:YES identifier:identifier
                progress:nil
                completion:^(__unused NSURL *videoURL, NSURL *audioURL, NSError *error) {
                    finish(audioURL, error);
                }];
        });
    }];
}

- (void)uploadAudio:(NSURL *)audioURL translationID:(NSString *)translationID {
    YTKACEShowNotice(YTKACELocalized(@"Sending audio to Yandex…"));
    NSUInteger generation = self.generation;
    __weak YTKACETranslationCoordinator *weakSelf = self;
    [YTKACEVOTClient.sharedClient uploadAudioFile:audioURL videoURL:self.videoURL
                                    translationID:translationID
                                        cancelled:^BOOL {
        YTKACETranslationCoordinator *strongSelf = weakSelf;
        return strongSelf == nil || ![strongSelf isCurrent:generation];
    }
                                       completion:^(NSError *error) {
        [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
        YTKACETranslationCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil || ![strongSelf isCurrent:generation]) return;
        if (error != nil) {
            YTKACEDownloadLog(@"vot", @"upload failed: %@", error.localizedDescription);
            [strongSelf schedulePollAfter:5.0];
            return;
        }
        strongSelf.audioUploaded = YES;
        [strongSelf requestTranslation];
    }];
}

- (void)sendFailedAudioForTranslation:(NSString *)translationID {
    if (self.failedAudioSent) {
        [self failWithMessage:YTKACELocalized(@"Could not get the video's audio.")];
        return;
    }
    self.failedAudioSent = YES;
    NSUInteger generation = self.generation;
    __weak YTKACETranslationCoordinator *weakSelf = self;
    [YTKACEVOTClient.sharedClient sendFailedAudioForVideoURL:self.videoURL
                                                     videoID:self.videoID
                                               translationID:translationID
                                                  completion:^(NSError *error) {
        YTKACETranslationCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil || ![strongSelf isCurrent:generation]) return;
        if (error != nil) {
            [strongSelf failWithMessage:YTKACELocalized(@"Could not get the video's audio.")];
            return;
        }
        [strongSelf schedulePollAfter:5.0];
    }];
}

#pragma mark Dubbed audio

- (void)downloadTranslationFrom:(NSURL *)remoteURL {
    NSUInteger generation = self.generation;
    NSURL *destination = YTKACETranslationCacheURL(self.videoID, self.language, self.livelyVoice);
    __weak YTKACETranslationCoordinator *weakSelf = self;
    self.downloadTask = [NSURLSession.sharedSession downloadTaskWithURL:remoteURL
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            BOOL saved = NO;
            if (error == nil && status == 200 && location != nil) {
                [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
                saved = [NSFileManager.defaultManager moveItemAtURL:location toURL:destination
                                                              error:&error];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                YTKACETranslationCoordinator *strongSelf = weakSelf;
                if (strongSelf == nil || ![strongSelf isCurrent:generation]) return;
                strongSelf.downloadTask = nil;
                if (!saved) {
                    [strongSelf failWithMessage:error.localizedDescription ?:
                        YTKACELocalized(@"Could not download the translation.")];
                    return;
                }
                [strongSelf startPlaybackWithFile:destination];
            });
        }];
    [self.downloadTask resume];
}

- (void)startPlaybackWithFile:(NSURL *)fileURL {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:fileURL];
    item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.automaticallyWaitsToMinimizeStalling = NO;
    self.state = YTKACETranslationStateActive;
    self.lastMediaTime = -1.0;
    self.lastSampleTime = CACurrentMediaTime();
    self.estimatedRate = 1.0;
    [self applyVolumes];
    [self updateButton];
    __weak YTKACETranslationCoordinator *weakSelf = self;
    self.syncTimer = [NSTimer timerWithTimeInterval:YTKACETranslationSyncInterval repeats:YES
                                              block:^(__unused NSTimer *timer) {
        [weakSelf synchronize];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.syncTimer forMode:NSRunLoopCommonModes];
    [self synchronize];
    // synchronize stops the translation if the user already switched videos.
    if (self.state != YTKACETranslationStateActive) return;
    YTKACEShowNotice(YTKACELocalized(@"Translation on"));
    YTKACEDownloadLog(@"vot", @"playing translation video=%@", self.videoID);
}

- (void)applyVolumes {
    self.player.volume = (float)YTKACETranslationPercent(YTKACETranslationVolumeKey, 100.0);
    YTKACESetOriginalVolumeFactor(
        (float)YTKACETranslationPercent(YTKACETranslationOriginalVolumeKey, 15.0), self.overlay);
}

// Keeps the dub on the YouTube player's clock. Pause is inferred from the
// media time not advancing, which also covers buffering and ads.
- (void)synchronize {
    if (self.state != YTKACETranslationStateActive || self.player == nil) return;
    id controller = self.playerController;
    NSString *currentID = YTKACEControllerVideoID(controller);
    if (currentID.length != 0 && ![currentID isEqualToString:self.videoID]) {
        [self stopWithNotice:YTKACELocalized(@"Translation off")];
        return;
    }
    double time = YTKACETranslationDouble(controller, @"currentVideoMediaTime");
    CFTimeInterval now = CACurrentMediaTime();
    double mediaDelta = time - self.lastMediaTime;
    double wallDelta = now - self.lastSampleTime;
    if (controller == nil || fabs(mediaDelta) < 0.01) {
        self.stillTicks += 1;
        if (self.stillTicks >= 3) self.originalPlaying = NO;
    } else {
        self.stillTicks = 0;
        self.originalPlaying = YES;
        // Fallback speed estimate for players without a rate getter;
        // jumps larger than a 5x step are seeks and are ignored.
        if (self.lastMediaTime >= 0.0 && wallDelta > 0.15 && mediaDelta > 0.0 &&
            mediaDelta < wallDelta * 5.5) {
            self.estimatedRate = self.estimatedRate * 0.7 + (mediaDelta / wallDelta) * 0.3;
        }
    }
    self.lastMediaTime = time;
    self.lastSampleTime = now;

    AVPlayer *player = self.player;
    if (!self.originalPlaying) {
        if (player.rate != 0.0f) [player pause];
        return;
    }
    if (self.seeking) return;
    double rate = YTKACEPlayerRate(controller);
    if (rate <= 0.0) {
        rate = MAX(0.25, MIN(5.0, round(self.estimatedRate * 20.0) / 20.0));
    }
    double position = CMTimeGetSeconds(player.currentTime);
    BOOL drifted = !isfinite(position) || fabs(position - time) > YTKACETranslationDriftLimit;
    if (player.rate == 0.0f || drifted) {
        self.seeking = YES;
        __weak YTKACETranslationCoordinator *weakSelf = self;
        // Seek slightly ahead to cover the seek latency of a local mp3.
        CMTime target = CMTimeMakeWithSeconds(time + 0.05, 600);
        [player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
         completionHandler:^(BOOL finished) {
            YTKACETranslationCoordinator *strongSelf = weakSelf;
            strongSelf.seeking = NO;
            if (finished && strongSelf.originalPlaying && strongSelf.player == player) {
                [player playImmediatelyAtRate:(float)rate];
            }
        }];
    } else if (fabs(player.rate - rate) > 0.01) {
        player.rate = (float)rate;
    }
}

@end

void YTKACEInstallTranslationHooks(void) {
    YTKACETrackedRenderers = [NSHashTable weakObjectsHashTable];
    YTKACEInstallInstanceHook(@"AVSampleBufferRenderSynchronizer", @"addRenderer:",
                              (IMP)YTKACESynchronizerAddRenderer,
                              &OriginalSynchronizerAddRenderer);
    YTKACEInstallInstanceHook(@"AVSampleBufferAudioRenderer", @"setVolume:",
                              (IMP)YTKACERendererSetVolume, &OriginalRendererSetVolume);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        YTKACEPurgeOldTranslations();
    });

    YTKACERegisterOverlayConfigurator(@"translation", ^(UIView *overlay, UIStackView *stack) {
        YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;
        UIButton *button = YTKACEOverlayButton(stack, YTKACETranslationButtonIdentifier,
                                               @"translate", coordinator,
                                               @selector(toggleTranslation));
        static const void *longPressAssociation = &longPressAssociation;
        if (objc_getAssociatedObject(button, longPressAssociation) == nil) {
            objc_setAssociatedObject(button, longPressAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
                initWithTarget:coordinator action:@selector(buttonLongPressed:)];
            [button addGestureRecognizer:longPress];
        }
        coordinator.button = button;
        [coordinator updateButton];
    });
}

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Status codes of VideoTranslationResponse (vot.js VideoTranslationStatus).
typedef NS_ENUM(NSInteger, YTKACEVOTStatus) {
    YTKACEVOTStatusFailed = 0,
    YTKACEVOTStatusFinished = 1,
    YTKACEVOTStatusWaiting = 2,
    YTKACEVOTStatusLongWaiting = 3,
    YTKACEVOTStatusPartContent = 5,
    YTKACEVOTStatusAudioRequested = 6,
    YTKACEVOTStatusSessionRequired = 7,
};

FOUNDATION_EXPORT NSString * const YTKACEVOTErrorDomain;

@interface YTKACEVOTTranslation : NSObject
@property(nonatomic, assign) YTKACEVOTStatus status;
@property(nonatomic, copy) NSString *translationID;
@property(nonatomic, copy, nullable) NSURL *audioURL;
@property(nonatomic, assign) NSInteger remainingTime;
@property(nonatomic, copy, nullable) NSString *message;
@property(nonatomic, assign) BOOL shouldRetry;
@property(nonatomic, assign) BOOL livelyVoice;
@end

typedef void (^YTKACEVOTTranslationCompletion)(YTKACEVOTTranslation * _Nullable translation,
                                               NSError * _Nullable error);
typedef void (^YTKACEVOTCompletion)(NSError * _Nullable error);

// Client for Yandex's browser video translation API (api.browser.yandex.ru),
// a native port of the parts of FOSWLY/vot.js the player needs.
// Completions run on the main queue.
@interface YTKACEVOTClient : NSObject
+ (instancetype)sharedClient;
// livelyVoice asks for Yandex "live voices"; oauthToken (a Yandex account
// token) is sent only together with it.
- (void)translateVideoURL:(NSString *)videoURL
                 duration:(double)duration
          requestLanguage:(NSString *)requestLanguage
         responseLanguage:(NSString *)responseLanguage
              livelyVoice:(BOOL)livelyVoice
               oauthToken:(nullable NSString *)oauthToken
                    title:(nullable NSString *)title
               completion:(YTKACEVOTTranslationCompletion)completion;

// Uploads the original audio track in chunks after AUDIO_REQUESTED.
// `cancelled` is checked before every chunk; it stops the upload early.
- (void)uploadAudioFile:(NSURL *)fileURL
               videoURL:(NSString *)videoURL
          translationID:(NSString *)translationID
              cancelled:(BOOL (^)(void))cancelled
             completion:(YTKACEVOTCompletion)completion;

// vot.js fallback when audio cannot be obtained: fail-audio-js + empty audio.
- (void)sendFailedAudioForVideoURL:(NSString *)videoURL
                           videoID:(NSString *)videoID
                     translationID:(NSString *)translationID
                        completion:(YTKACEVOTCompletion)completion;
@end

NS_ASSUME_NONNULL_END

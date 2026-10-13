#import "VOTClient.h"
#import "VOTProto.h"
#import "../Downloads/DownloadLog.h"

#import <CommonCrypto/CommonHMAC.h>

NSString * const YTKACEVOTErrorDomain = @"YTKACEVOT";

// Values from FOSWLY/vot.js packages/shared/src/data/config.ts (v3.1.5).
// Yandex rotates componentVersion and the HMAC key with Yandex Browser
// releases; update them together when requests start failing with 4xx.
static NSString * const YTKACEVOTHost = @"https://api.browser.yandex.ru";
static NSString * const YTKACEVOTUserAgent =
    @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    @"(KHTML, like Gecko) Chrome/150.0.0.0 YaBrowser/26.8.0.0 Safari/537.36";
static NSString * const YTKACEVOTComponentVersion = @"26.10.0.1796";
static NSString * const YTKACEVOTHMACKey = @"bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf";
static const NSUInteger YTKACEVOTMinChunkSize = 5295308;
static NSString * const YTKACEVOTSessionModule = @"video-translation";

@implementation YTKACEVOTTranslation
@end

@interface YTKACEVOTClient ()
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, copy, nullable) NSString *sessionUUID;
@property(nonatomic, copy, nullable) NSString *sessionSecret;
@property(nonatomic, assign) NSTimeInterval sessionExpiry;
@property(nonatomic, strong) NSMutableArray<YTKACEVOTCompletion> *sessionWaiters;
@end

static NSError *YTKACEVOTError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:YTKACEVOTErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *YTKACEVOTSignature(NSData *data) {
    NSData *key = [YTKACEVOTHMACKey dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static NSString *YTKACEVOTUUID(void) {
    static const char digits[] = "0123456789ABCDEF";
    char buffer[33];
    for (int index = 0; index < 32; index++) {
        buffer[index] = digits[arc4random_uniform(16)];
    }
    buffer[32] = '\0';
    return [NSString stringWithUTF8String:buffer];
}

// Takes ownership of the buffer contents.
static NSData *YTKACEVOTData(VOTBuffer *buffer) {
    if (buffer->data == NULL) return [NSData data];
    NSData *data = [NSData dataWithBytesNoCopy:buffer->data length:buffer->length
                                  freeWhenDone:YES];
    buffer->data = NULL;
    buffer->length = 0;
    buffer->capacity = 0;
    return data;
}

static NSString *YTKACEVOTString(const char *value) {
    return value == NULL ? nil : [NSString stringWithUTF8String:value];
}

@implementation YTKACEVOTClient

+ (instancetype)sharedClient {
    static YTKACEVOTClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [YTKACEVOTClient new];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 60.0;
        configuration.HTTPShouldSetCookies = NO;
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        _session = [NSURLSession sessionWithConfiguration:configuration];
        _sessionWaiters = [NSMutableArray array];
    }
    return self;
}

- (void)sendPath:(NSString *)path
          method:(NSString *)method
            body:(NSData *)body
         headers:(NSDictionary<NSString *, NSString *> *)headers
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion {
    NSURL *url = [NSURL URLWithString:[YTKACEVOTHost stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.HTTPBody = body;
    request.timeoutInterval = timeout;
    NSDictionary *base = @{
        @"User-Agent": YTKACEVOTUserAgent,
        @"Accept": @"application/x-protobuf",
        @"Accept-Language": @"en",
        @"Content-Type": @"application/x-protobuf",
        @"Pragma": @"no-cache",
        @"Cache-Control": @"no-cache",
    };
    [base enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    [[self.session dataTaskWithRequest:request
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error == nil && status != 200) {
            error = YTKACEVOTError(status, [NSString stringWithFormat:
                @"Yandex responded with HTTP %ld", (long)status]);
        }
        if (error != nil) {
            YTKACEDownloadLog(@"vot", @"%@ %@ failed: %@", method, path,
                              error.localizedDescription);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error == nil ? (data ?: [NSData data]) : nil, error);
        });
    }] resume];
}

- (void)withSession:(YTKACEVOTCompletion)completion {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (self.sessionSecret != nil && now < self.sessionExpiry) {
        completion(nil);
        return;
    }
    [self.sessionWaiters addObject:[completion copy]];
    if (self.sessionWaiters.count > 1) return;

    NSString *uuid = YTKACEVOTUUID();
    VOTBuffer buffer = {};
    if (!VOTEncodeSessionRequest(&buffer, uuid.UTF8String,
                                 YTKACEVOTSessionModule.UTF8String)) {
        [self finishSessionWithError:YTKACEVOTError(-1, @"Could not encode session request")];
        return;
    }
    NSData *body = YTKACEVOTData(&buffer);
    [self sendPath:@"/session/create" method:@"POST" body:body
           headers:@{@"Vtrans-Signature": YTKACEVOTSignature(body)}
           timeout:30.0
        completion:^(NSData *data, NSError *error) {
        if (error != nil) {
            [self finishSessionWithError:error];
            return;
        }
        VOTSessionResponse response;
        if (!VOTDecodeSessionResponse((const uint8_t *)data.bytes, data.length, &response)) {
            [self finishSessionWithError:YTKACEVOTError(-2, @"Invalid session response")];
            return;
        }
        self.sessionUUID = uuid;
        self.sessionSecret = YTKACEVOTString(response.secretKey);
        // Renew a minute early so a request never races the expiry.
        NSTimeInterval lifetime = MAX(60.0, (NSTimeInterval)response.expires - 60.0);
        self.sessionExpiry = NSDate.date.timeIntervalSince1970 + lifetime;
        VOTSessionResponseFree(&response);
        [self finishSessionWithError:nil];
    }];
}

- (void)finishSessionWithError:(nullable NSError *)error {
    NSArray<YTKACEVOTCompletion> *waiters = [self.sessionWaiters copy];
    [self.sessionWaiters removeAllObjects];
    for (YTKACEVOTCompletion waiter in waiters) {
        waiter(error);
    }
}

- (NSDictionary<NSString *, NSString *> *)secureHeadersForBody:(NSData *)body
                                                          path:(NSString *)path {
    NSString *token = [NSString stringWithFormat:@"%@:%@:%@",
        self.sessionUUID, path, YTKACEVOTComponentVersion];
    NSString *tokenSignature =
        YTKACEVOTSignature([token dataUsingEncoding:NSUTF8StringEncoding]);
    return @{
        @"Vtrans-Signature": YTKACEVOTSignature(body),
        @"Sec-Vtrans-Sk": self.sessionSecret ?: @"",
        @"Sec-Vtrans-Token": [NSString stringWithFormat:@"%@:%@", tokenSignature, token],
    };
}

- (void)sendSecurePath:(NSString *)path
                method:(NSString *)method
                  body:(NSData *)body
          extraHeaders:(nullable NSDictionary<NSString *, NSString *> *)extraHeaders
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion {
    [self withSession:^(NSError *sessionError) {
        if (sessionError != nil) {
            completion(nil, sessionError);
            return;
        }
        NSMutableDictionary *headers = [[self secureHeadersForBody:body path:path] mutableCopy];
        [headers addEntriesFromDictionary:extraHeaders ?: @{}];
        [self sendPath:path method:method body:body headers:headers
               timeout:timeout completion:completion];
    }];
}

- (void)translateVideoURL:(NSString *)videoURL
                 duration:(double)duration
          requestLanguage:(NSString *)requestLanguage
         responseLanguage:(NSString *)responseLanguage
              livelyVoice:(BOOL)livelyVoice
               oauthToken:(NSString *)oauthToken
                    title:(NSString *)title
               completion:(YTKACEVOTTranslationCompletion)completion {
    VOTBuffer buffer = {};
    if (!VOTEncodeTranslationRequest(&buffer, videoURL.UTF8String, duration,
                                     requestLanguage.UTF8String,
                                     responseLanguage.UTF8String,
                                     livelyVoice ? 1 : 0, title.UTF8String)) {
        completion(nil, YTKACEVOTError(-1, @"Could not encode translation request"));
        return;
    }
    // vot.js sends the account token only with live-voice requests.
    NSDictionary *authorization = livelyVoice && oauthToken.length != 0
        ? @{@"Authorization": [@"OAuth " stringByAppendingString:oauthToken]}
        : nil;
    [self sendSecurePath:@"/video-translation/translate" method:@"POST"
                    body:YTKACEVOTData(&buffer) extraHeaders:authorization timeout:30.0
              completion:^(NSData *data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        VOTTranslationResponse response;
        if (!VOTDecodeTranslationResponse((const uint8_t *)data.bytes, data.length, &response)) {
            completion(nil, YTKACEVOTError(-2, @"Invalid translation response"));
            return;
        }
        YTKACEVOTTranslation *translation = [YTKACEVOTTranslation new];
        translation.status = (YTKACEVOTStatus)response.status;
        translation.translationID = YTKACEVOTString(response.translationID) ?: @"";
        NSString *url = YTKACEVOTString(response.url);
        translation.audioURL = url.length != 0 ? [NSURL URLWithString:url] : nil;
        translation.remainingTime = response.hasRemainingTime ? response.remainingTime : -1;
        translation.message = YTKACEVOTString(response.message);
        translation.shouldRetry = response.shouldRetry == 1;
        translation.livelyVoice = response.isLivelyVoice != 0;
        VOTTranslationResponseFree(&response);
        YTKACEDownloadLog(@"vot", @"translate lively=%d auth=%d status=%ld remaining=%ld "
                          @"serverLively=%d id=%@ message=%@",
                          livelyVoice, authorization != nil,
                          (long)translation.status, (long)translation.remainingTime,
                          translation.livelyVoice, translation.translationID,
                          translation.message ?: @"");
        completion(translation, nil);
    }];
}

- (void)putAudioBody:(NSData *)body
            attempts:(NSUInteger)attempts
          completion:(void (^)(int32_t status, NSError * _Nullable error))completion {
    [self sendSecurePath:@"/video-translation/audio" method:@"PUT" body:body
            extraHeaders:nil timeout:120.0
              completion:^(NSData *data, NSError *error) {
        if (error != nil) {
            if (attempts > 1) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self putAudioBody:body attempts:attempts - 1 completion:completion];
                });
                return;
            }
            completion(0, error);
            return;
        }
        int32_t status = 0;
        if (!VOTDecodeAudioResponse((const uint8_t *)data.bytes, data.length, &status)) {
            completion(0, YTKACEVOTError(-2, @"Invalid audio response"));
            return;
        }
        completion(status, nil);
    }];
}

- (void)uploadAudioFile:(NSURL *)fileURL
               videoURL:(NSString *)videoURL
          translationID:(NSString *)translationID
              cancelled:(BOOL (^)(void))cancelled
             completion:(YTKACEVOTCompletion)completion {
    NSError *readError = nil;
    NSData *audio = [NSData dataWithContentsOfURL:fileURL
                                          options:NSDataReadingMappedIfSafe
                                            error:&readError];
    if (audio.length == 0) {
        completion(readError ?: YTKACEVOTError(-3, @"Audio file is empty"));
        return;
    }
    NSString *fileID = [NSString stringWithFormat:@"random-web_mse_proxy-%@",
                        NSUUID.UUID.UUIDString.lowercaseString];
    NSUInteger total = (audio.length + YTKACEVOTMinChunkSize - 1) / YTKACEVOTMinChunkSize;
    YTKACEDownloadLog(@"vot", @"upload id=%@ bytes=%lu chunks=%lu", translationID,
                      (unsigned long)audio.length, (unsigned long)total);
    [self uploadChunk:0 total:total audio:audio fileID:fileID videoURL:videoURL
        translationID:translationID cancelled:cancelled completion:completion];
}

- (void)uploadChunk:(NSUInteger)index
              total:(NSUInteger)total
              audio:(NSData *)audio
             fileID:(NSString *)fileID
           videoURL:(NSString *)videoURL
      translationID:(NSString *)translationID
          cancelled:(BOOL (^)(void))cancelled
         completion:(YTKACEVOTCompletion)completion {
    if (index >= total) {
        completion(nil);
        return;
    }
    // Stopping translation mid-upload must not keep sending ~5 MB chunks.
    if (cancelled()) {
        completion([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled
                                   userInfo:nil]);
        return;
    }
    NSUInteger offset = index * YTKACEVOTMinChunkSize;
    NSUInteger length = MIN(YTKACEVOTMinChunkSize, audio.length - offset);
    BOOL last = index == total - 1;
    VOTBuffer buffer = {};
    if (!VOTEncodeAudioChunkRequest(&buffer, videoURL.UTF8String, translationID.UTF8String,
                                    (const uint8_t *)audio.bytes + offset, length,
                                    (int32_t)index, last ? (int32_t)total : 0,
                                    fileID.UTF8String, 1)) {
        completion(YTKACEVOTError(-1, @"Could not encode audio chunk"));
        return;
    }
    [self putAudioBody:YTKACEVOTData(&buffer) attempts:3
            completion:^(int32_t status, NSError *error) {
        if (error != nil) {
            completion(error);
            return;
        }
        YTKACEDownloadLog(@"vot", @"chunk %lu/%lu status=%d",
                          (unsigned long)index + 1, (unsigned long)total, status);
        [self uploadChunk:index + 1 total:total audio:audio fileID:fileID
                 videoURL:videoURL translationID:translationID
                cancelled:cancelled completion:completion];
    }];
}

- (void)sendFailedAudioForVideoURL:(NSString *)videoURL
                           videoID:(NSString *)videoID
                     translationID:(NSString *)translationID
                        completion:(YTKACEVOTCompletion)completion {
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"video_url": videoURL}
                                                   options:0 error:nil];
    [self sendPath:@"/video-translation/fail-audio-js" method:@"PUT" body:json
           headers:@{@"Accept": @"application/json", @"Content-Type": @"application/json"}
           timeout:30.0
        completion:^(NSData *data, NSError *error) {
        id object = data == nil ? nil :
            [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id status = [object isKindOfClass:NSDictionary.class] ? object[@"status"] : nil;
        if (error != nil || ![status respondsToSelector:@selector(integerValue)] ||
            [status integerValue] != 1) {
            completion(error ?: YTKACEVOTError(-4, @"fail-audio-js was rejected"));
            return;
        }
        NSString *fileID = [@"fallback-empty-audio:video-translation:"
                            stringByAppendingString:videoID];
        VOTBuffer buffer = {};
        if (!VOTEncodeAudioFileRequest(&buffer, videoURL.UTF8String,
                                       translationID.UTF8String, NULL, 0,
                                       fileID.UTF8String)) {
            completion(YTKACEVOTError(-1, @"Could not encode audio request"));
            return;
        }
        [self putAudioBody:YTKACEVOTData(&buffer) attempts:2
                completion:^(__unused int32_t status, NSError *putError) {
            completion(putError);
        }];
    }];
}

@end

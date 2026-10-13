#import "YandexAccount.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"

#import <Security/Security.h>
#import <WebKit/WebKit.h>

// voice-over-translation's auth server redirects this to oauth.yandex.ru with
// its client id, and Yandex returns to <server>/auth/callback#access_token=…
static NSString * const YTKACEYandexLoginURL = @"https://rust-server-531j.onrender.com/v1/auth/handle";
static NSString * const YTKACEYandexCallbackHost = @"rust-server-531j.onrender.com";
static NSString * const YTKACEYandexCallbackPath = @"/auth/callback";
static NSString * const YTKACEYandexKeychainService = @"YTKACE.YandexAccount";
static NSString * const YTKACEYandexKeychainAccount = @"oauth";

typedef void (^YTKACEYandexCompletion)(BOOL success);

static NSDictionary *YTKACEKeychainQuery(void) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: YTKACEYandexKeychainService,
        (__bridge id)kSecAttrAccount: YTKACEYandexKeychainAccount,
    };
}

// Stored as JSON: {"token": "...", "expires": <unix seconds>, "login": "..."}.
static NSDictionary *YTKACEReadKeychain(void) {
    NSMutableDictionary *query = [YTKACEKeychainQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) {
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static BOOL YTKACEWriteKeychain(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (data == nil) return NO;
    SecItemDelete((__bridge CFDictionaryRef)YTKACEKeychainQuery());
    NSMutableDictionary *item = [YTKACEKeychainQuery() mutableCopy];
    item[(__bridge id)kSecValueData] = data;
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) {
        YTKACEDownloadLog(@"vot", @"keychain write failed status=%d", (int)status);
    }
    return status == errSecSuccess;
}

@interface YTKACEYandexLoginController : UIViewController <WKNavigationDelegate>
@property(nonatomic, copy) void (^onToken)(NSString * _Nullable token, NSTimeInterval expiresIn);
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, assign) BOOL finished;
@end

@implementation YTKACEYandexLoginController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTKACELocalized(@"Yandex Account");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancel)];
    // Non-persistent store: the Yandex session cookies are not kept after
    // sign-in, only the OAuth token is.
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];
    [self.webView loadRequest:[NSURLRequest requestWithURL:
        [NSURL URLWithString:YTKACEYandexLoginURL]]];
}

- (void)finishWithToken:(NSString *)token expiresIn:(NSTimeInterval)expiresIn {
    if (self.finished) return;
    self.finished = YES;
    [self.webView stopLoading];
    void (^handler)(NSString *, NSTimeInterval) = self.onToken;
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler != nil) handler(token, expiresIn);
    }];
}

- (void)cancel {
    [self finishWithToken:nil expiresIn:0];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    BOOL callback = [url.host isEqualToString:YTKACEYandexCallbackHost] &&
        [url.path isEqualToString:YTKACEYandexCallbackPath];
    if (!callback) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    decisionHandler(WKNavigationActionPolicyCancel);
    NSURLComponents *fragment = [NSURLComponents new];
    fragment.percentEncodedQuery = url.fragment;
    NSString *token = nil;
    NSTimeInterval expiresIn = 0;
    for (NSURLQueryItem *item in fragment.queryItems) {
        if ([item.name isEqualToString:@"access_token"]) token = item.value;
        if ([item.name isEqualToString:@"expires_in"]) expiresIn = item.value.doubleValue;
    }
    YTKACEDownloadLog(@"vot", @"yandex callback token=%d expires=%.0f",
                      token.length != 0, expiresIn);
    [self finishWithToken:token.length != 0 ? token : nil expiresIn:expiresIn];
}

@end

@interface YTKACEYandexAccount ()
// In-memory copy of the Keychain item: the panel reads the login on every
// refresh, which must not hit the Keychain on the main thread each time.
@property(nonatomic, copy, nullable) NSDictionary *stored;
@property(nonatomic, assign) BOOL loaded;
@end

@implementation YTKACEYandexAccount

+ (instancetype)sharedAccount {
    static YTKACEYandexAccount *account;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        account = [YTKACEYandexAccount new];
    });
    return account;
}

- (NSDictionary *)record {
    if (!self.loaded) {
        self.stored = YTKACEReadKeychain();
        self.loaded = YES;
    }
    return self.stored;
}

- (BOOL)saveRecord:(NSDictionary *)record {
    if (!YTKACEWriteKeychain(record)) return NO;
    self.stored = record;
    self.loaded = YES;
    return YES;
}

- (NSString *)token {
    NSDictionary *stored = [self record];
    NSString *token = stored[@"token"];
    NSNumber *expires = stored[@"expires"];
    if (![token isKindOfClass:NSString.class] || token.length == 0) return nil;
    if ([expires isKindOfClass:NSNumber.class] &&
        expires.doubleValue <= NSDate.date.timeIntervalSince1970) {
        return nil;
    }
    return token;
}

- (NSString *)login {
    if (self.token == nil) return nil;
    NSString *login = [self record][@"login"];
    return [login isKindOfClass:NSString.class] && login.length != 0 ? login : nil;
}

- (void)signInFromViewController:(UIViewController *)presenter
                      completion:(YTKACEYandexCompletion)completion {
    YTKACEYandexLoginController *login = [YTKACEYandexLoginController new];
    login.onToken = ^(NSString *token, NSTimeInterval expiresIn) {
        if (token == nil) {
            completion(NO);
            return;
        }
        // Yandex tokens live a year; keep a day of margin.
        NSTimeInterval lifetime = expiresIn > 86400.0 ? expiresIn - 86400.0 : 365.0 * 86400.0;
        NSMutableDictionary *stored = [@{
            @"token": token,
            @"expires": @(NSDate.date.timeIntervalSince1970 + lifetime),
        } mutableCopy];
        if (![self saveRecord:stored]) {
            completion(NO);
            return;
        }
        [self fetchLoginWithToken:token completion:^(NSString *name) {
            if (name.length != 0) {
                stored[@"login"] = name;
                [self saveRecord:stored];
            }
            completion(YES);
        }];
    };
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:login];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    // Swipe-to-dismiss would skip onToken; Cancel is the only way out.
    navigation.modalInPresentation = YES;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)fetchLoginWithToken:(NSString *)token completion:(void (^)(NSString * _Nullable))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://login.yandex.ru/info?format=json"]];
    [request setValue:[@"OAuth " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    request.timeoutInterval = 20.0;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
                                   completionHandler:^(NSData *data, __unused NSURLResponse *response,
                                                       __unused NSError *error) {
        id object = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *name = nil;
        if ([object isKindOfClass:NSDictionary.class]) {
            id value = object[@"login"] ?: object[@"display_name"];
            name = [value isKindOfClass:NSString.class] ? value : nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(name); });
    }] resume];
}

- (void)signOut {
    SecItemDelete((__bridge CFDictionaryRef)YTKACEKeychainQuery());
    self.stored = nil;
    self.loaded = YES;
}

@end

void YTKACEPresentYandexAccountOptions(UIViewController *presenter, dispatch_block_t changed) {
    YTKACEYandexAccount *account = YTKACEYandexAccount.sharedAccount;
    if (account.token == nil) {
        [account signInFromViewController:presenter completion:^(BOOL success) {
            YTKACEShowNotice(success
                ? [NSString stringWithFormat:YTKACELocalized(@"Signed in to Yandex as %@"),
                   account.login ?: @"—"]
                : YTKACELocalized(@"Yandex sign-in cancelled"));
            if (success && changed != nil) changed();
        }];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:YTKACELocalized(@"Yandex Account")
                         message:account.login ?: YTKACELocalized(@"Signed in")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Sign Out")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [account signOut];
        YTKACEShowNotice(YTKACELocalized(@"Signed out of Yandex"));
        if (changed != nil) changed();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

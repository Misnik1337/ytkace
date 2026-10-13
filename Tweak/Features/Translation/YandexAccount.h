#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Yandex account used for "live voices". Signs in through the same OAuth
// client as voice-over-translation; the token returns in the URL fragment of
// the callback page, which is intercepted locally and never loaded, and is
// stored only in the Keychain.
@interface YTKACEYandexAccount : NSObject
+ (instancetype)sharedAccount;
// nil when signed out or the token has expired.
@property(nonatomic, readonly, nullable) NSString *token;
@property(nonatomic, readonly, nullable) NSString *login;
- (void)signInFromViewController:(UIViewController *)presenter
                      completion:(void (^)(BOOL success))completion;
- (void)signOut;
@end

// Signs in when signed out; otherwise offers to sign out. `changed` runs
// after a successful sign-in or sign-out.
FOUNDATION_EXPORT void YTKACEPresentYandexAccountOptions(UIViewController *presenter,
                                                        dispatch_block_t _Nullable changed);

NS_ASSUME_NONNULL_END

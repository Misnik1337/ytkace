#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol YTKACETranslationPanelHost <NSObject>
- (BOOL)translationRunning;
- (NSString *)translationStatusText;
- (void)toggleTranslation;
@end

// Half-height sheet opened by holding the translate button: start/stop,
// live voices, target language, original and translation volume sliders,
// Yandex account. Every control writes the YTKACE preference directly, so
// the playing translation reacts immediately.
@interface YTKACETranslationPanelController : UIViewController
- (instancetype)initWithHost:(id<YTKACETranslationPanelHost>)host NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (void)refresh;
@end

FOUNDATION_EXPORT UIViewController * _Nullable YTKACETranslationPresenter(void);

NS_ASSUME_NONNULL_END

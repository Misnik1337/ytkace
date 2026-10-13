#import "TranslationPanel.h"
#import "YandexAccount.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"

#import <math.h>

static NSArray<NSString *> *YTKACEPanelLanguages(void) {
    return @[@"ru", @"en", @"kk"];
}

static double YTKACEPanelPercent(NSString *key, double fallback) {
    id value = YTKACEPreferenceObject(key);
    double percent = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
    return MAX(0.0, MIN(100.0, percent));
}

UIViewController *YTKACETranslationPresenter(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) keyWindow = window;
        }
    }
    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController != nil &&
           !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

@interface YTKACETranslationPanelController ()
@property(nonatomic, weak) id<YTKACETranslationPanelHost> host;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *toggleButton;
@property(nonatomic, strong) UISwitch *livelySwitch;
@property(nonatomic, strong) UISegmentedControl *languageControl;
@property(nonatomic, strong) UISlider *originalSlider;
@property(nonatomic, strong) UILabel *originalValue;
@property(nonatomic, strong) UISlider *translationSlider;
@property(nonatomic, strong) UILabel *translationValue;
@property(nonatomic, strong) UIButton *accountButton;
@end

@implementation YTKACETranslationPanelController

- (instancetype)initWithHost:(id<YTKACETranslationPanelHost>)host {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _host = host;
        self.modalPresentationStyle = UIModalPresentationPageSheet;
        UISheetPresentationController *sheet = self.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                          UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        // In landscape (fullscreen video) a page sheet would cover the whole
        // screen, leaving no dimmed area to tap and YouTube's fullscreen
        // gestures eat the swipe down. Attach it to the bottom edge with a
        // fixed width instead; the close button covers every layout.
        sheet.prefersEdgeAttachedInCompactHeight = YES;
        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
        self.preferredContentSize = CGSizeMake(440.0, 0.0);
    }
    return self;
}

- (UILabel *)labelWithText:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
    label.textColor = UIColor.labelColor;
    return label;
}

- (UIView *)rowWithTitle:(NSString *)title accessory:(UIView *)accessory {
    UILabel *label = [self labelWithText:title];
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow
                             forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, accessory]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    return row;
}

- (UIView *)sliderBlockWithTitle:(NSString *)title
                          symbol:(NSString *)symbol
                          slider:(UISlider *)slider
                      valueLabel:(UILabel *)valueLabel {
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
    valueLabel.textColor = UIColor.secondaryLabelColor;
    valueLabel.textAlignment = NSTextAlignmentRight;
    [valueLabel.widthAnchor constraintEqualToConstant:52.0].active = YES;
    UIView *header = [self rowWithTitle:title accessory:valueLabel];

    slider.minimumValue = 0.0f;
    slider.maximumValue = 100.0f;
    slider.minimumValueImage = [UIImage systemImageNamed:@"speaker.fill"];
    slider.maximumValueImage = [UIImage systemImageNamed:symbol];
    slider.tintColor = UIColor.systemRedColor;
    [slider addTarget:self action:@selector(sliderChanged:)
     forControlEvents:UIControlEventValueChanged];

    UIStackView *block = [[UIStackView alloc] initWithArrangedSubviews:@[header, slider]];
    block.axis = UILayoutConstraintAxisVertical;
    block.spacing = 6.0;
    return block;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [UILabel new];
    title.text = YTKACELocalized(@"Voice-over Translation");
    title.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeClose];
    close.accessibilityLabel = YTKACELocalized(@"Close");
    [close addTarget:self action:@selector(closeTapped)
    forControlEvents:UIControlEventTouchUpInside];
    [close setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, close]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;

    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont systemFontOfSize:14.0];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 2;

    UIButtonConfiguration *toggleStyle = UIButtonConfiguration.filledButtonConfiguration;
    toggleStyle.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    self.toggleButton = [UIButton buttonWithConfiguration:toggleStyle primaryAction:nil];
    [self.toggleButton addTarget:self action:@selector(toggleTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.toggleButton.heightAnchor constraintEqualToConstant:46.0].active = YES;

    self.livelySwitch = [UISwitch new];
    self.livelySwitch.onTintColor = UIColor.systemRedColor;
    [self.livelySwitch addTarget:self action:@selector(livelyChanged:)
                forControlEvents:UIControlEventValueChanged];

    self.languageControl = [[UISegmentedControl alloc] initWithItems:@[
        YTKACELocalized(@"Russian"), YTKACELocalized(@"English"), YTKACELocalized(@"Kazakh")]];
    [self.languageControl addTarget:self action:@selector(languageChanged:)
                   forControlEvents:UIControlEventValueChanged];
    UILabel *languageTitle = [self labelWithText:YTKACELocalized(@"Translation Language")];
    UIStackView *languageBlock = [[UIStackView alloc]
        initWithArrangedSubviews:@[languageTitle, self.languageControl]];
    languageBlock.axis = UILayoutConstraintAxisVertical;
    languageBlock.spacing = 8.0;

    self.originalSlider = [UISlider new];
    self.originalValue = [UILabel new];
    UIView *originalBlock = [self sliderBlockWithTitle:YTKACELocalized(@"Original Volume")
                                                symbol:@"speaker.wave.3.fill"
                                                slider:self.originalSlider
                                            valueLabel:self.originalValue];
    self.translationSlider = [UISlider new];
    self.translationValue = [UILabel new];
    UIView *translationBlock = [self sliderBlockWithTitle:YTKACELocalized(@"Translation Volume")
                                                   symbol:@"person.wave.2.fill"
                                                   slider:self.translationSlider
                                               valueLabel:self.translationValue];

    UIButtonConfiguration *accountStyle = UIButtonConfiguration.plainButtonConfiguration;
    accountStyle.contentInsets = NSDirectionalEdgeInsetsZero;
    self.accountButton = [UIButton buttonWithConfiguration:accountStyle primaryAction:nil];
    [self.accountButton addTarget:self action:@selector(accountTapped)
                 forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        header, self.statusLabel, self.toggleButton,
        [self rowWithTitle:YTKACELocalized(@"Live Voices") accessory:self.livelySwitch],
        languageBlock, originalBlock, translationBlock,
        [self rowWithTitle:YTKACELocalized(@"Yandex Account") accessory:self.accountButton],
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18.0;
    [stack setCustomSpacing:4.0 afterView:header];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [scroll addSubview:stack];
    [self.view addSubview:scroll];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20.0],
    ]];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)refresh {
    if (!self.isViewLoaded) return;
    id<YTKACETranslationPanelHost> host = self.host;
    BOOL running = host.translationRunning;
    self.statusLabel.text = host.translationStatusText;

    UIButtonConfiguration *style = self.toggleButton.configuration;
    style.title = YTKACELocalized(running ? @"Turn off translation" : @"Translate this video");
    style.image = [UIImage systemImageNamed:running ? @"stop.fill" : @"play.fill"];
    style.imagePadding = 8.0;
    style.baseBackgroundColor = running ? UIColor.systemGray4Color : UIColor.systemRedColor;
    style.baseForegroundColor = running ? UIColor.labelColor : UIColor.whiteColor;
    self.toggleButton.configuration = style;

    self.livelySwitch.on = YTKACEFeatureEnabled(YTKACETranslationLivelyVoiceKey);
    id language = YTKACEPreferenceObject(YTKACETranslationLanguageKey);
    NSUInteger index = [language isKindOfClass:NSString.class]
        ? [YTKACEPanelLanguages() indexOfObject:language] : NSNotFound;
    self.languageControl.selectedSegmentIndex = index == NSNotFound ? 0 : (NSInteger)index;

    double original = YTKACEPanelPercent(YTKACETranslationOriginalVolumeKey, 15.0);
    double translation = YTKACEPanelPercent(YTKACETranslationVolumeKey, 100.0);
    if (!self.originalSlider.isTracking) self.originalSlider.value = (float)original;
    if (!self.translationSlider.isTracking) self.translationSlider.value = (float)translation;
    self.originalValue.text = [NSString stringWithFormat:@"%.0f%%", original];
    self.translationValue.text = [NSString stringWithFormat:@"%.0f%%", translation];

    UIButtonConfiguration *account = self.accountButton.configuration;
    account.title = YTKACEYandexAccount.sharedAccount.login ?: YTKACELocalized(@"Not signed in");
    self.accountButton.configuration = account;
}

- (void)toggleTapped {
    [self.host toggleTranslation];
    [self refresh];
}

- (void)livelyChanged:(UISwitch *)sender {
    YTKACESetPreference(YTKACETranslationLivelyVoiceKey, sender.isOn);
}

- (void)languageChanged:(UISegmentedControl *)sender {
    NSArray<NSString *> *languages = YTKACEPanelLanguages();
    if ((NSUInteger)sender.selectedSegmentIndex < languages.count) {
        YTKACESetPreferenceObject(YTKACETranslationLanguageKey,
                                  languages[(NSUInteger)sender.selectedSegmentIndex]);
    }
}

- (void)sliderChanged:(UISlider *)slider {
    // Step of 5 % keeps the value readable and the preference writes few.
    double value = round(slider.value / 5.0) * 5.0;
    BOOL original = slider == self.originalSlider;
    NSString *key = original ? YTKACETranslationOriginalVolumeKey : YTKACETranslationVolumeKey;
    if (fabs(YTKACEPanelPercent(key, -1.0) - value) < 0.5) return;
    YTKACESetPreferenceObject(key, @(value));
    (original ? self.originalValue : self.translationValue).text =
        [NSString stringWithFormat:@"%.0f%%", value];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)accountTapped {
    __weak YTKACETranslationPanelController *weakSelf = self;
    YTKACEPresentYandexAccountOptions(self, ^{ [weakSelf refresh]; });
}

@end

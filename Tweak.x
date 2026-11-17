//
//  FilesFullName.x
//  Show the complete file name in the Files app instead of "head…tail".
//
//  iOS 15 / 16, com.apple.DocumentsApp, arm64e (RootHide / rootless).
//
//  No Swift ivar access: everything is found by walking the view tree, so the
//  tweak can never read a bogus offset and crash the app.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define FELog(fmt, ...) NSLog((@"[FilesFullName] " fmt), ##__VA_ARGS__)

static NSString *const kPrefsDomain = @"com.voring.filesfullname";
static NSString *const kReloadNotification = @"com.voring.filesfullname.reload";
static NSString *const kPrefsFile = @"/var/mobile/Library/Preferences/com.voring.filesfullname.plist";

typedef struct {
    BOOL enabled;
    BOOL gridEnabled;
    BOOL shrink;
    BOOL wrap;
    BOOL resizeRows;
    BOOL showAlert;
    NSInteger maxLines;
} FEPrefs;

static FEPrefs gPrefs = {YES, YES, NO, YES, YES, YES, 0};
static NSUInteger gConfiguredCount = 0;

#pragma mark - Preferences

static id FEPrefCopyValue(NSString *key)
{
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)kPrefsDomain));
    if (value) {
        return value;
    }
    static NSArray<NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = @[@"/var/jb/var/mobile/Library/Preferences/com.voring.filesfullname.plist",
                  kPrefsFile];
    });
    for (NSString *path in paths) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        id candidate = plist[key];
        if (candidate) {
            return candidate;
        }
    }
    return nil;
}

static BOOL FEPrefBool(NSString *key, BOOL fallback)
{
    id value = FEPrefCopyValue(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSInteger FEPrefInt(NSString *key, NSInteger fallback)
{
    id value = FEPrefCopyValue(key);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static void FELoadPrefs(void)
{
    gPrefs.enabled = FEPrefBool(@"Enabled", YES);
    gPrefs.gridEnabled = FEPrefBool(@"GridEnabled", YES);
    gPrefs.shrink = FEPrefBool(@"ShrinkToFit", NO);
    gPrefs.wrap = FEPrefBool(@"WrapLines", YES);
    gPrefs.resizeRows = FEPrefBool(@"ResizeRows", YES);
    gPrefs.showAlert = FEPrefBool(@"ShowLoadAlert", YES);
    gPrefs.maxLines = FEPrefInt(@"ListMaxLines", 0);
    if (gPrefs.maxLines < 0) gPrefs.maxLines = 0;
}

static void FEPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    FELoadPrefs();
}

#pragma mark - Hooking

static BOOL FEHook(Class cls, SEL selector, void *replacement, void **original, NSString *tag)
{
    if (!cls) {
        return NO;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        FELog(@"%@ has no -%@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return NO;
    }
    IMP repl = (IMP)replacement;
    IMP previous = method_getImplementation(method);
    if (!class_addMethod(cls, selector, repl, method_getTypeEncoding(method))) {
        method_setImplementation(method, repl);
    }
    if (original) {
        *original = (void *)previous;
    }
    FELog(@"hooked -%@ on %@ (%@)", NSStringFromSelector(selector), NSStringFromClass(cls), tag);
    return YES;
}

#pragma mark - View tree helpers

static BOOL FEIsInsideCell(UIView *view)
{
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 12; depth++, current = current.superview) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"Cell"] || [name containsString:@"Row"]) {
            return YES;
        }
    }
    return NO;
}

static void FECollectLabels(UIView *view, NSMutableArray<UILabel *> *into, NSInteger depth)
{
    if (!view || depth > 10) {
        return;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        [into addObject:(UILabel *)view];
    }
    for (UIView *child in view.subviews) {
        FECollectLabels(child, into, depth + 1);
    }
}

/// The filing card's file-name label is the widest label in the cell.
static UILabel *FETitleLabel(UIView *cell)
{
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    FECollectLabels(cell, labels, 0);

    UILabel *best = nil;
    CGFloat bestWidth = 0;
    for (UILabel *label in labels) {
        if (label.hidden || label.alpha < 0.05) {
            continue;
        }
        NSString *text = label.text.length ? label.text : label.attributedText.string;
        if (text.length == 0) {
            continue;
        }
        CGFloat width = label.bounds.size.width;
        if (width <= 1.0) {
            width = label.frame.size.width;
        }
        if (width > bestWidth) {
            bestWidth = width;
            best = label;
        }
    }
    return best;
}

static NSAttributedString *PERewrite(NSAttributedString *attributed, NSLineBreakMode mode)
{
    if (attributed.length == 0) {
        return attributed;
    }
    NSMutableAttributedString *mutable = [attributed mutableCopy];
    __block BOOL changed = NO;
    [attributed enumerateAttribute:NSParagraphStyleAttributeName
                            inRange:NSMakeRange(0, attributed.length)
                            options:0
                         usingBlock:^(id value, NSRange range, BOOL *stop) {
        NSMutableParagraphStyle *style = value ? [value mutableCopy] : [[NSMutableParagraphStyle alloc] init];
        if (style.lineBreakMode != mode) {
            style.lineBreakMode = mode;
            [mutable addAttribute:NSParagraphStyleAttributeName value:style range:range];
            changed = YES;
        }
    }];
    return changed ? mutable : attributed;
}

static void FEConfigureLabel(UILabel *label)
{
    if (!label || !gPrefs.enabled) {
        return;
    }
    BOOL singleLine = gPrefs.shrink || !gPrefs.wrap;
    NSInteger lines = singleLine ? 1 : gPrefs.maxLines;
    NSLineBreakMode mode = singleLine ? NSLineBreakByTruncatingTail : NSLineBreakByCharWrapping;

    if (label.numberOfLines != lines) label.numberOfLines = lines;
    if (label.lineBreakMode != mode) label.lineBreakMode = mode;
    if (label.adjustsFontSizeToFitWidth != singleLine) label.adjustsFontSizeToFitWidth = singleLine;
    if (singleLine && label.minimumScaleFactor < 0.4) label.minimumScaleFactor = 0.4;

    CGFloat width = label.bounds.size.width;
    if (width > 1.0 && fabs(label.preferredMaxLayoutWidth - width) > 0.5) {
        label.preferredMaxLayoutWidth = width;
    }

    NSAttributedString *text = label.attributedText;
    if (text.length) {
        NSAttributedString *fixed = PERewrite(text, mode);
        if (fixed != text) label.attributedText = fixed;
    }
    gConfiguredCount++;
}

#pragma mark - UILabel setters

static void (*orig_setLineBreakMode)(id, SEL, NSLineBreakMode);
static void (*orig_setNumberOfLines)(id, SEL, NSInteger);
static void (*orig_setAttributedText)(id, SEL, NSAttributedString *);

static void FESetLineBreakMode(id self, SEL _cmd, NSLineBreakMode mode)
{
    orig_setLineBreakMode(self, _cmd, mode);
    if (mode == NSLineBreakByTruncatingMiddle && FEIsInsideCell(self) && !gPrefs.shrink && gPrefs.enabled) {
        FEConfigureLabel((UILabel *)self);
    }
}

static void FESetNumberOfLines(id self, SEL _cmd, NSInteger lines)
{
    orig_setNumberOfLines(self, _cmd, lines);
    if (lines == 1 && FEIsInsideCell(self) && !gPrefs.shrink && gPrefs.wrap && gPrefs.enabled) {
        FEConfigureLabel((UILabel *)self);
    }
}

static void FESetAttributedText(id self, SEL _cmd, NSAttributedString *text)
{
    if (FEIsInsideCell(self) && !gPrefs.shrink && gPrefs.enabled && text.length) {
        text = PERewrite(text, NSLineBreakByCharWrapping);
    }
    orig_setAttributedText(self, _cmd, text);
}

#pragma mark - Cell layout

static void (*orig_cellLayout)(id, SEL);
static id (*orig_preferredAttrs)(id, SEL, id);
static CGSize (*orig_cellSizing)(id, SEL, CGSize, float, float);

static CGFloat FEHeightDelta(UIView *cell, CGFloat width)
{
    UILabel *label = FETitleLabel(cell);
    if (!label) {
        return 0;
    }
    NSString *text = label.text.length ? label.text : label.attributedText.string;
    if (text.length == 0) {
        return 0;
    }
    CGFloat labelWidth = label.bounds.size.width;
    if (labelWidth <= 1.0) labelWidth = width;
    if (labelWidth <= 1.0) labelWidth = cell.bounds.size.width - 72.0;
    if (labelWidth <= 1.0) return 0;

    if (label.numberOfLines != 0) label.numberOfLines = 0;
    label.preferredMaxLayoutWidth = labelWidth;

    CGFloat wanted = ceil([label sizeThatFits:CGSizeMake(labelWidth, CGFLOAT_MAX)].height);
    CGFloat current = label.font.lineHeight;
    CGFloat delta = wanted - current;
    return delta > 0.5 && delta < 200.0 ? delta : 0;
}

static void FECellLayout(id self, SEL _cmd)
{
    orig_cellLayout(self, _cmd);
    if (!gPrefs.enabled) {
        return;
    }
    UIView *cell = (UIView *)self;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    FECollectLabels(cell, labels, 0);
    for (UILabel *label in labels) {
        if (label.numberOfLines == 1 && FEIsInsideCell(label)) {
            FEConfigureLabel(label);
        }
    }
}

static id FEPreferredAttrs(id self, SEL _cmd, id attributes)
{
    id result = orig_preferredAttrs(self, _cmd, attributes);
    if (!gPrefs.enabled || !gPrefs.resizeRows || gPrefs.shrink) {
        return result;
    }
    UIView *cell = (UIView *)self;
    CGFloat delta = FEHeightDelta(cell, cell.bounds.size.width);
    if (delta > 0 && [result isKindOfClass:[UICollectionViewLayoutAttributes class]]) {
        UICollectionViewLayoutAttributes *attrs = result;
        CGRect frame = attrs.frame;
        frame.size.height += delta;
        attrs.frame = frame;
        attrs.size = frame.size;
    }
    return result;
}

static CGSize FECellSizing(id self, SEL _cmd, CGSize size, float hPriority, float vPriority)
{
    CGSize base = orig_cellSizing(self, _cmd, size, hPriority, vPriority);
    if (!gPrefs.enabled || !gPrefs.resizeRows || gPrefs.shrink) {
        return base;
    }
    CGFloat delta = FEHeightDelta((UIView *)self, size.width);
    if (delta > 0) {
        base.height += delta;
    }
    return base;
}

#pragma mark - Load confirmation

static void FEShowAlert(NSString *message)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
            if (window) break;
        }
        UIViewController *root = window.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        if (!root) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"FilesFullName"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [root presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Install

__attribute__((constructor)) static void FEInitialize(void)
{
    FELog(@"loaded (v0.0.10)");
    FELoadPrefs();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, FEPrefsChanged,
                                    (__bridge CFStringRef)kReloadNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    Class labelClass = [UILabel class];
    FEHook(labelClass, @selector(setLineBreakMode:), (void *)&FESetLineBreakMode,
           (void **)&orig_setLineBreakMode, @"label");
    FEHook(labelClass, @selector(setNumberOfLines:), (void *)&FESetNumberOfLines,
           (void **)&orig_setNumberOfLines, @"label");
    FEHook(labelClass, @selector(setAttributedText:), (void *)&FESetAttributedText,
           (void **)&orig_setAttributedText, @"label");

    Class cellClass = NSClassFromString(@"UICollectionViewCell");
    if (cellClass) {
        FEHook(cellClass, @selector(layoutSubviews), (void *)&FECellLayout,
               (void **)&orig_cellLayout, @"cell");
        FEHook(cellClass, @selector(preferredLayoutAttributesFittingAttributes:),
               (void *)&FEPreferredAttrs, (void **)&orig_preferredAttrs, @"cell");
        FEHook(cellClass, @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:),
               (void *)&FECellSizing, (void **)&orig_cellSizing, @"cell");
    }

    if (gPrefs.showAlert) {
        FEShowAlert([NSString stringWithFormat:@"插件已加载 (0.0.10)\n已处理标签数：%lu", (unsigned long)gConfiguredCount]);
    }
}

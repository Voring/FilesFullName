//
//  FilesFullName.x
//  Show the complete file name in the Files app instead of "head…tail".
//
//  iOS 15 / 16, com.apple.DocumentsApp, arm64e (RootHide / rootless).
//
//  Design notes:
//  - Never touch Swift ivars; everything is found by walking the view tree.
//  - No UICollectionViewCell hooks at all: mutating views inside layoutSubviews
//    made Files' Swift list cell hit an assertion and crash.
//  - Only wide list-row title labels (> 200pt) are rewritten, by intercepting
//    the UILabel setters, so the grid / icon view is untouched.
//  - File-type icons are clamped back to square size off the layout pass.
//  - No load alert: the tweak stays silent.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define FELog(fmt, ...) NSLog((@"[FilesFullName] " fmt), ##__VA_ARGS__)

static NSString *const kPrefsDomain = @"com.voring.filesfullname";
static NSString *const kReloadNotification = @"com.voring.filesfullname.reload";
static NSString *const kPrefsFile = @"/var/mobile/Library/Preferences/com.voring.filesfullname.plist";

/// Only rows with a label at least this wide count as list rows.
static const CGFloat FEWideLabelMinWidth = 200.0;

typedef struct {
    BOOL enabled;
    BOOL shrink;
    BOOL wrap;
    BOOL keepIconSize;
    NSInteger maxLines;
} FEPrefs;

static FEPrefs gPrefs = {YES, NO, YES, YES, 0};

#pragma mark - Preferences

static id FEPrefCopyValue(NSString *key)
{
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)kPrefsDomain));
    if (value) return value;

    static NSArray<NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = @[@"/var/jb/var/mobile/Library/Preferences/com.voring.filesfullname.plist",
                  kPrefsFile];
    });
    for (NSString *path in paths) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        id candidate = plist[key];
        if (candidate) return candidate;
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
    gPrefs.shrink = FEPrefBool(@"ShrinkToFit", NO);
    gPrefs.wrap = FEPrefBool(@"WrapLines", YES);
    gPrefs.keepIconSize = FEPrefBool(@"KeepIconSize", YES);
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
    if (!cls) return NO;

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
    if (original) *original = (void *)previous;
    FELog(@"hooked -%@ on %@ (%@)", NSStringFromSelector(selector), NSStringFromClass(cls), tag);
    return YES;
}

#pragma mark - View tree helpers

static UIView *FEEnclosingCell(UIView *view)
{
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 12; depth++, current = current.superview) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"Cell"] || [name containsString:@"Row"]) return current;
    }
    return nil;
}

static void FECollectViews(UIView *view, Class cls, NSMutableArray *into, NSInteger depth)
{
    if (!view || depth > 10) return;
    if ([view isKindOfClass:cls]) [into addObject:view];
    for (UIView *child in view.subviews) FECollectViews(child, cls, into, depth + 1);
}

static CGFloat FELabelWidth(UILabel *label)
{
    CGFloat width = label.bounds.size.width;
    if (width <= 1.0) width = label.frame.size.width;
    return width;
}

static BOOL FEIsWideListLabel(UILabel *label)
{
    return FEEnclosingCell(label) != nil && FELabelWidth(label) >= FEWideLabelMinWidth;
}

static NSAttributedString *PERewrite(NSAttributedString *attributed, NSLineBreakMode mode)
{
    if (attributed.length == 0) return attributed;

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

#pragma mark - Icon size

static void FEClampIconSize(UIView *cell)
{
    if (!gPrefs.keepIconSize || !cell) return;

    NSMutableArray<UIImageView *> *icons = [NSMutableArray array];
    FECollectViews(cell, [UIImageView class], icons, 0);
    for (UIImageView *icon in icons) {
        CGRect frame = icon.frame;
        if (frame.size.height > frame.size.width + 1.0 && frame.size.width > 8.0) {
            CGFloat centerY = CGRectGetMidY(frame);
            frame.size.height = frame.size.width;
            frame.origin.y = centerY - frame.size.height / 2.0;
            icon.frame = frame;
        }
    }
}

/// Runs after the current layout pass finishes, so no assertion can be tripped.
static void FEScheduleIconClamp(UILabel *label)
{
    static const void *kPendingKey = &kPendingKey;
    UIView *cell = FEEnclosingCell(label);
    if (!cell || objc_getAssociatedObject(cell, kPendingKey)) return;
    objc_setAssociatedObject(cell, kPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(cell, kPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FEClampIconSize(cell);
    });
}

#pragma mark - Label configuration

static void FEConfigureLabel(UILabel *label)
{
    if (!label || !gPrefs.enabled) return;

    BOOL singleLine = gPrefs.shrink || !gPrefs.wrap;
    NSInteger lines = singleLine ? 1 : gPrefs.maxLines;
    NSLineBreakMode mode = singleLine ? NSLineBreakByTruncatingTail : NSLineBreakByCharWrapping;

    if (label.numberOfLines != lines) label.numberOfLines = lines;
    if (label.lineBreakMode != mode) label.lineBreakMode = mode;
    if (label.adjustsFontSizeToFitWidth != singleLine) label.adjustsFontSizeToFitWidth = singleLine;
    if (singleLine && label.minimumScaleFactor < 0.4) label.minimumScaleFactor = 0.4;

    CGFloat width = FELabelWidth(label);
    if (width > 1.0 && fabs(label.preferredMaxLayoutWidth - width) > 0.5) {
        label.preferredMaxLayoutWidth = width;
    }

    NSAttributedString *text = label.attributedText;
    if (text.length) {
        NSAttributedString *fixed = PERewrite(text, mode);
        if (fixed != text) label.attributedText = fixed;
    }

    FEScheduleIconClamp(label);
}

#pragma mark - UILabel setters

static void (*orig_setLineBreakMode)(id, SEL, NSLineBreakMode);
static void (*orig_setNumberOfLines)(id, SEL, NSInteger);
static void (*orig_setAttributedText)(id, SEL, NSAttributedString *);

static void FESetLineBreakMode(id self, SEL _cmd, NSLineBreakMode mode)
{
    orig_setLineBreakMode(self, _cmd, mode);
    if (mode == NSLineBreakByTruncatingMiddle && gPrefs.enabled && !gPrefs.shrink &&
        FEIsWideListLabel((UILabel *)self)) {
        FEConfigureLabel((UILabel *)self);
    }
}

static void FESetNumberOfLines(id self, SEL _cmd, NSInteger lines)
{
    orig_setNumberOfLines(self, _cmd, lines);
    if (lines == 1 && gPrefs.enabled && !gPrefs.shrink && gPrefs.wrap &&
        FEIsWideListLabel((UILabel *)self)) {
        FEConfigureLabel((UILabel *)self);
    }
}

static void FESetAttributedText(id self, SEL _cmd, NSAttributedString *text)
{
    if (gPrefs.enabled && !gPrefs.shrink && text.length && FEIsWideListLabel((UILabel *)self)) {
        text = PERewrite(text, NSLineBreakByCharWrapping);
    }
    orig_setAttributedText(self, _cmd, text);
}

#pragma mark - Install

__attribute__((constructor)) static void FEInitialize(void)
{
    FELog(@"loaded (v0.0.11)");
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
}

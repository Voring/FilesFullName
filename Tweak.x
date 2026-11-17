//
//  FilesFullName.x
//  Show the complete file name in the Files app instead of "head…tail".
//
//  iOS 15 / 16, com.apple.DocumentsApp, arm64e (RootHide / rootless).
//
//  Design notes:
//  - Never touch Swift ivars; every element is found by walking the view tree.
//  - No layoutSubviews hook on cells and no constraint surgery.
//  - Label setters are hooked, and a post-layout rescan of the visible window
//    covers labels whose text/icon were laid out after the setter ran.
//  - Icons keep their natural size by aspect-fitting at layout time.
//  - Only two surfaces are touched: list cell title labels and the center
//    filename under the large preview artwork.
//  - Silent load: no alert.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define FELog(fmt, ...) NSLog((@"[FilesFullName] " fmt), ##__VA_ARGS__)

static NSString *const kPrefsDomain = @"com.voring.filesfullname";
static NSString *const kReloadNotification = @"com.voring.filesfullname.reload";
static NSString *const kPrefsFile = @"/var/mobile/Library/Preferences/com.voring.filesfullname.plist";
static NSString *const kTreeDumpFile = @"/var/mobile/Library/Preferences/com.voring.filesfullname.tree.txt";

static const CGFloat FEWideLabelMinWidth = 200.0;

typedef struct {
    BOOL enabled;
    BOOL shrink;
    BOOL wrap;
    BOOL resizeRows;
    BOOL keepIconSize;
    BOOL dumpToDownloads;
    NSInteger maxLines;
} FEPrefs;

static FEPrefs gPrefs = {YES, NO, YES, YES, YES, YES, 0};

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
    gPrefs.resizeRows = FEPrefBool(@"ResizeRows", YES);
    gPrefs.keepIconSize = FEPrefBool(@"KeepIconSize", YES);
    gPrefs.dumpToDownloads = FEPrefBool(@"DumpToDownloads", YES);
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
    if (!view || depth > 12) return;
    if ([view isKindOfClass:cls]) [into addObject:view];
    for (UIView *child in view.subviews) FECollectViews(child, cls, into, depth + 1);
}

static CGFloat FELabelWidth(UILabel *label)
{
    CGFloat width = label.bounds.size.width;
    if (width <= 1.0) width = label.frame.size.width;
    return width;
}

static BOOL FEIsNavAncestor(UIView *view)
{
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 12; depth++, current = current.superview) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"NavigationBar"] || [name containsString:@"NavBar"] ||
            [name containsString:@"Toolbar"] || [name containsString:@"TabBar"]) {
            return YES;
        }
    }
    return NO;
}

/// Preview/detail page: the filename sits directly under a large file icon.
/// Walk all the way up to the window; the icon may be several levels away and
/// its frame may only be laid out after the label's setter ran.
static BOOL FEHasLargeIconNearby(UILabel *label)
{
    UIView *container = label.superview;
    for (NSInteger depth = 0; container && depth < 8; depth++, container = container.superview) {
        NSMutableArray<UIView *> *icons = [NSMutableArray array];
        FECollectViews(container, [UIView class], icons, 0);
        for (UIView *icon in icons) {
            if ([icon isKindOfClass:[UILabel class]]) continue;
            NSString *name = NSStringFromClass([icon class]);
            if ([name containsString:@"Cell"] || [name containsString:@"Collection"] ||
                [name containsString:@"ScrollView"] || [name containsString:@"Window"]) {
                continue;
            }
            CGFloat w = icon.bounds.size.width > 1.0 ? icon.bounds.size.width : icon.frame.size.width;
            CGFloat h = icon.bounds.size.height > 1.0 ? icon.bounds.size.height : icon.frame.size.height;
            if (w > 60.0 && h > 60.0) return YES;
        }
    }
    return NO;
}

/// Only two surfaces are touched:
///  1. title labels inside list/grid cells (file listing)
///  2. the center filename under the large preview icon
/// Everything else (sidebar, search, sheet, subtitles, nav title) keeps the
/// system layout.
static BOOL FEIsManagedLabel(UILabel *label)
{
    if (FEIsNavAncestor(label)) return NO;
    CGFloat width = FELabelWidth(label);

    // The app's own choice is the strongest signal: only file names are drawn
    // with a middle truncation. Wrap those wherever they live, so the preview
    // page no longer depends on guessing its container. Narrow grid labels stay
    // untouched so the grid keeps its cell size.
    if (label.lineBreakMode == NSLineBreakByTruncatingMiddle) {
        if (width <= 1.0) return YES;
        if (FEEnclosingCell(label) && width < 140.0) return NO;
        return width >= 60.0;
    }

    // Detail / preview center filename: its container can be narrower than a
    // list row, so the list-row width gate must not apply here.
    if (FEHasLargeIconNearby(label)) {
        return width <= 1.0 || width >= 100.0;
    }

    if (FEEnclosingCell(label)) {
        return width <= 1.0 || width >= FEWideLabelMinWidth;
    }
    return NO;
}

static UILabel *FETitleLabel(UIView *cell)
{
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    FECollectViews(cell, [UILabel class], labels, 0);

    UILabel *best = nil;
    CGFloat bestWidth = 0;
    for (UILabel *label in labels) {
        if (label.hidden || label.alpha < 0.05) continue;
        NSString *text = label.text.length ? label.text : label.attributedText.string;
        if (text.length == 0) continue;
        CGFloat width = FELabelWidth(label);
        if (width > 1.0 && width < FEWideLabelMinWidth) continue;
        if (width > bestWidth) {
            bestWidth = width;
            best = label;
        }
    }
    return best;
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

/// Keep the icon at its natural size without touching any constraint.
/// A wrapped row makes the icon frame taller than wide; whatever draws the
/// artwork inside it is told to preserve the aspect ratio, so the glyph is
/// drawn at the frame's width instead of being stretched vertically.
static void FEKeepIconNaturalSize(UIView *icon)
{
    if (!icon || !FEEnclosingCell(icon)) return;
    if ([icon isKindOfClass:[UILabel class]]) return;

    CGRect frame = icon.frame;
    if (frame.size.height <= frame.size.width + 1.0 || frame.size.width <= 8.0) return;

    if ([icon isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)icon;
        if (imageView.contentMode != UIViewContentModeScaleAspectFit) {
            imageView.contentMode = UIViewContentModeScaleAspectFit;
        }
        if (!imageView.clipsToBounds) imageView.clipsToBounds = YES;
    }

    CALayer *layer = icon.layer;
    if (layer.contents && ![layer.contentsGravity isEqualToString:kCAGravityResizeAspect]) {
        layer.contentsGravity = kCAGravityResizeAspect;
    }
}

static void FEClampIconSize(UIView *root)
{
    if (!gPrefs.keepIconSize || !root) return;

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    FECollectViews(root, [UIView class], views, 0);
    for (UIView *view in views) {
        if (view.subviews.count > 0) continue;
        if (![view isKindOfClass:[UIImageView class]] && !view.layer.contents) continue;
        FEKeepIconNaturalSize(view);
    }
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
    if (width <= 1.0) width = label.superview.bounds.size.width;
    if (width > 1.0 && fabs(label.preferredMaxLayoutWidth - width) > 0.5) {
        label.preferredMaxLayoutWidth = width;
    }

    NSAttributedString *text = label.attributedText;
    if (text.length) {
        NSAttributedString *fixed = PERewrite(text, mode);
        if (fixed != text) label.attributedText = fixed;
    }
}

#pragma mark - Visible-window rescan

static UIWindow *FEKeyWindow(void)
{
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static void FEDumpTree(UIView *root)
{
    if (!root) return;
    NSMutableString *dump = [NSMutableString string];
    [dump appendFormat:@"=== tree %@ ===\n", [NSDate date]];

    NSMutableArray *labels = [NSMutableArray array];
    NSMutableArray *images = [NSMutableArray array];
    FECollectViews(root, [UILabel class], labels, 0);
    FECollectViews(root, [UIImageView class], images, 0);

    for (UILabel *label in labels) {
        NSString *text = label.text.length ? label.text : label.attributedText.string;
        [dump appendFormat:@"LABEL %@ frame=%@ lines=%ld mode=%ld text=%@\n",
         NSStringFromClass([label class]),
         NSStringFromCGRect(label.frame),
         (long)label.numberOfLines, (long)label.lineBreakMode,
         text.length > 80 ? [text substringToIndex:80] : text];
    }
    for (UIImageView *imageView in images) {
        [dump appendFormat:@"IMAGE %@ frame=%@ mode=%ld\n",
         NSStringFromClass([imageView class]),
         NSStringFromCGRect(imageView.frame), (long)imageView.contentMode];
    }

    // Every non-label view that carries drawn content, so a SwiftUI or custom
    // drawn title can be identified by class name and size.
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    FECollectViews(root, [UIView class], views, 0);
    for (UIView *view in views) {
        if (view.layer.contents || view.subviews.count == 0) {
            [dump appendFormat:@"VIEW %@ frame=%@ layerContents=%d\n",
             NSStringFromClass([view class]),
             NSStringFromCGRect(view.frame), view.layer.contents != nil];
        }
    }

    NSArray<NSString *> *paths = @[kTreeDumpFile];
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES) firstObject];
    NSMutableArray<NSString *> *extra = [NSMutableArray array];
    if (documents.length) [extra addObject:[documents stringByAppendingPathComponent:@"tree.txt"]];
    if (gPrefs.dumpToDownloads) [extra addObject:@"/var/mobile/Downloads/tree.txt"];
    if (extra.count) paths = [extra arrayByAddingObject:kTreeDumpFile];
    for (NSString *path in paths) {
        [dump writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static void FERescanVisible(void)
{
    UIWindow *window = FEKeyWindow();
    if (!window) return;

    NSMutableArray *labels = [NSMutableArray array];
    FECollectViews(window, [UILabel class], labels, 0);
    for (UILabel *label in labels) {
        if (FEIsManagedLabel(label)) FEConfigureLabel(label);
    }
    FEClampIconSize(window);
    FEDumpTree(window);
}

#pragma mark - UILabel setters

static void (*orig_setLineBreakMode)(id, SEL, NSLineBreakMode);
static void (*orig_setNumberOfLines)(id, SEL, NSInteger);
static void (*orig_setAttributedText)(id, SEL, NSAttributedString *);
static void (*orig_setText)(id, SEL, NSString *);

static void FESetLineBreakMode(id self, SEL _cmd, NSLineBreakMode mode)
{
    orig_setLineBreakMode(self, _cmd, mode);
    if (mode == NSLineBreakByTruncatingMiddle && gPrefs.enabled && !gPrefs.shrink &&
        FEIsManagedLabel((UILabel *)self)) {
        FEConfigureLabel((UILabel *)self);
    }
}

static void FESetNumberOfLines(id self, SEL _cmd, NSInteger lines)
{
    orig_setNumberOfLines(self, _cmd, lines);
    if (lines == 1 && gPrefs.enabled && !gPrefs.shrink && gPrefs.wrap &&
        FEIsManagedLabel((UILabel *)self)) {
        FEConfigureLabel((UILabel *)self);
    }
}

static void FESetAttributedText(id self, SEL _cmd, NSAttributedString *text)
{
    if (gPrefs.enabled && !gPrefs.shrink && text.length && FEIsManagedLabel((UILabel *)self)) {
        text = PERewrite(text, NSLineBreakByCharWrapping);
    }
    orig_setAttributedText(self, _cmd, text);
}

static void FESetText(id self, SEL _cmd, NSString *text)
{
    orig_setText(self, _cmd, text);
    if (gPrefs.enabled && !gPrefs.shrink && text.length && FEIsManagedLabel((UILabel *)self)) {
        FEConfigureLabel((UILabel *)self);
    }
}

#pragma mark - Cell sizing only (no layoutSubviews on cells)

static id (*orig_preferredAttrs)(id, SEL, id);
static CGSize (*orig_cellSizing)(id, SEL, CGSize, float, float);

static CGFloat FEHeightDelta(UIView *cell, CGFloat fallbackWidth)
{
    if (!gPrefs.enabled || !gPrefs.resizeRows || gPrefs.shrink) return 0;

    UILabel *label = FETitleLabel(cell);
    if (!label) return 0;

    NSString *text = label.text.length ? label.text : label.attributedText.string;
    if (text.length == 0) return 0;

    CGFloat width = FELabelWidth(label);
    if (width < FEWideLabelMinWidth) width = fallbackWidth;
    if (width < FEWideLabelMinWidth) return 0;

    if (label.numberOfLines != 0) label.numberOfLines = 0;
    label.preferredMaxLayoutWidth = width;

    CGFloat wanted = ceil([label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    CGFloat current = label.font.lineHeight;
    CGFloat delta = wanted - current;
    return (delta > 0.5 && delta < 200.0) ? delta : 0;
}

static id FEPreferredAttrs(id self, SEL _cmd, id attributes)
{
    id result = orig_preferredAttrs(self, _cmd, attributes);
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
    CGFloat delta = FEHeightDelta((UIView *)self, size.width);
    if (delta > 0) base.height += delta;
    return base;
}

#pragma mark - Install

static void (*orig_imageLayout)(id, SEL);
static void FEImageLayout(id self, SEL _cmd)
{
    orig_imageLayout(self, _cmd);
    FEKeepIconNaturalSize((UIView *)self);
}

static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void FEViewDidAppear(id self, SEL _cmd, BOOL animated)
{
    orig_viewDidAppear(self, _cmd, animated);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FERescanVisible();
    });
}

__attribute__((constructor)) static void FEInitialize(void)
{
    FELog(@"loaded (v0.0.19)");
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
    FEHook(labelClass, @selector(setText:), (void *)&FESetText,
           (void **)&orig_setText, @"label");

    Class imageClass = [UIImageView class];
    FEHook(imageClass, @selector(layoutSubviews), (void *)&FEImageLayout,
           (void **)&orig_imageLayout, @"icon");

    Class vcClass = [UIViewController class];
    FEHook(vcClass, @selector(viewDidAppear:), (void *)&FEViewDidAppear,
           (void **)&orig_viewDidAppear, @"vc");

    Class cellClass = NSClassFromString(@"UICollectionViewCell");
    if (cellClass) {
        FEHook(cellClass, @selector(preferredLayoutAttributesFittingAttributes:),
               (void *)&FEPreferredAttrs, (void **)&orig_preferredAttrs, @"cell");
        FEHook(cellClass, @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:),
               (void *)&FECellSizing, (void **)&orig_cellSizing, @"cell");
    }
}

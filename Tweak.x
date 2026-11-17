//
//  FilesFullName.x
//  Show the complete file name in the Files app instead of "head…tail".
//
//  Target: iOS 15 / 16 Files app (com.apple.DocumentsApp), arm64e, RootHide / rootless.
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
    BOOL resizeRows;
    BOOL showAlert;
    NSInteger listMaxLines;
    NSInteger gridMaxLines;
} FEPrefs;

static FEPrefs gPrefs = {YES, YES, NO, YES, YES, 0, 2};

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
    gPrefs.resizeRows = FEPrefBool(@"ResizeRows", YES);
    gPrefs.showAlert = FEPrefBool(@"ShowLoadAlert", YES);
    gPrefs.listMaxLines = FEPrefInt(@"ListMaxLines", 0);
    gPrefs.gridMaxLines = FEPrefInt(@"GridMaxLines", 2);
    if (gPrefs.listMaxLines < 0) gPrefs.listMaxLines = 0;
    if (gPrefs.gridMaxLines < 0) gPrefs.gridMaxLines = 0;

    FELog(@"prefs: enabled=%d grid=%d shrink=%d resize=%d list=%ld grid=%ld",
          gPrefs.enabled, gPrefs.gridEnabled, gPrefs.shrink, gPrefs.resizeRows,
          (long)gPrefs.listMaxLines, (long)gPrefs.gridMaxLines);
}

static void FEPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    FELoadPrefs();
}

#pragma mark - Runtime helpers

static id FEIvarValue(id object, NSString *name)
{
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (ivar) {
            return (ivar_getTypeEncoding(ivar)[0] == '@') ? object_getIvar(object, ivar) : nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static UILabel *FEIvarLabel(id object, NSString *name)
{
    id value = FEIvarValue(object, name);
    return [value isKindOfClass:[UILabel class]] ? value : nil;
}

static Class FEClassWithNames(NSArray<NSString *> *names)
{
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (cls) {
            return cls;
        }
    }
    return Nil;
}

/// Substrate-free hooking. Pointers are taken as void * so that the many
/// differently-typed IMPs we install never trip clang's pointer type checks.
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

#pragma mark - Label state

static const void *kFEFilenameLabelKey = &kFEFilenameLabelKey;

static BOOL FEIsItemCellLabel(UILabel *label)
{
    UIView *view = label.superview;
    for (NSInteger depth = 0; view && depth < 14; depth++, view = view.superview) {
        NSString *name = NSStringFromClass([view class]);
        if ([name containsString:@"DOCItemCollection"] && [name containsString:@"Cell"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL FEIsManagedLabel(UILabel *label)
{
    if (!gPrefs.enabled) {
        return NO;
    }
    if (objc_getAssociatedObject(label, kFEFilenameLabelKey)) {
        return YES;
    }
    return FEIsItemCellLabel(label);
}

static NSAttributedString *FERewriteAttributedText(NSAttributedString *attributed, NSLineBreakMode mode)
{
    if (attributed.length == 0) {
        return attributed;
    }
    if (![attributed attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL]) {
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

static UILabel *FEListTitleLabel(id cell);
static UILabel *FEGridTitleLabel(id cell);

static void FEConfigureLabel(UILabel *label, NSInteger maxLines)
{
    if (!label) {
        return;
    }
    objc_setAssociatedObject(label, kFEFilenameLabelKey, @(maxLines), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BOOL singleLine = gPrefs.shrink || maxLines == 1;
    NSInteger lines = singleLine ? 1 : maxLines;
    NSLineBreakMode mode = singleLine ? NSLineBreakByTruncatingTail : NSLineBreakByCharWrapping;

    if (label.numberOfLines != lines) label.numberOfLines = lines;
    if (label.lineBreakMode != mode) label.lineBreakMode = mode;
    if (label.adjustsFontSizeToFitWidth != singleLine) label.adjustsFontSizeToFitWidth = singleLine;
    if (singleLine && label.minimumScaleFactor < 0.5) label.minimumScaleFactor = 0.5;

    NSAttributedString *text = label.attributedText;
    if (text.length) {
        NSAttributedString *fixed = FERewriteAttributedText(text, mode);
        if (fixed != text) label.attributedText = fixed;
    }
}

static UILabel *FEListTitleLabel(id cell)
{
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[@"listTitleLabel", @"titleLabel", @"gridTitleLabel"];
    });
    for (NSString *name in names) {
        UILabel *label = FEIvarLabel(cell, name);
        if (label) return label;
    }
    return nil;
}

static UILabel *FEGridTitleLabel(id cell)
{
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[@"gridTitleLabel", @"titleLabel", @"listTitleLabel"];
    });
    for (NSString *name in names) {
        UILabel *label = FEIvarLabel(cell, name);
        if (label) return label;
    }
    return nil;
}

#pragma mark - UILabel setters (protect against later resets)

static void (*orig_setLineBreakMode)(id, SEL, NSLineBreakMode);
static void (*orig_setNumberOfLines)(id, SEL, NSInteger);
static void (*orig_setAttributedText)(id, SEL, NSAttributedString *);

static void FESetLineBreakMode(id self, SEL _cmd, NSLineBreakMode mode)
{
    if (mode == NSLineBreakByTruncatingMiddle && FEIsManagedLabel(self) && !gPrefs.shrink) {
        mode = NSLineBreakByCharWrapping;
    }
    orig_setLineBreakMode(self, _cmd, mode);
}

static void FESetNumberOfLines(id self, SEL _cmd, NSInteger lines)
{
    if (FEIsManagedLabel(self) && !gPrefs.shrink && lines == 1) {
        NSNumber *desired = objc_getAssociatedObject(self, kFEFilenameLabelKey);
        if (desired) {
            lines = desired.integerValue;
        }
    }
    orig_setNumberOfLines(self, _cmd, lines);
}

static void FESetAttributedText(id self, SEL _cmd, NSAttributedString *text)
{
    if (FEIsManagedLabel(self) && !gPrefs.shrink) {
        text = FERewriteAttributedText(text, NSLineBreakByCharWrapping);
    }
    orig_setAttributedText(self, _cmd, text);
}

#pragma mark - List cell

static void (*orig_listLayout)(id, SEL);
static void (*orig_listWindow)(id, SEL);
static void (*orig_listConfig)(id, SEL, id);
static void (*orig_listReuse)(id, SEL);
static CGSize (*orig_listSizing)(id, SEL, CGSize, float, float);

static void FEApplyList(id cell)
{
    if (!gPrefs.enabled) {
        return;
    }
    UILabel *label = FEListTitleLabel(cell);
    if (!label) {
        return;
    }
    if (!gPrefs.shrink) {
        CGFloat width = label.bounds.size.width;
        if (width > 1.0 && fabs(label.preferredMaxLayoutWidth - width) > 0.5) {
            label.preferredMaxLayoutWidth = width;
        }
    }
    FEConfigureLabel(label, gPrefs.listMaxLines);
}

static void FEListLayout(id self, SEL _cmd)
{
    FEApplyList(self);
    orig_listLayout(self, _cmd);
    FEApplyList(self);
}

static void FEListWindow(id self, SEL _cmd)
{
    orig_listWindow(self, _cmd);
    FEApplyList(self);
}

static void FEListConfig(id self, SEL _cmd, id state)
{
    orig_listConfig(self, _cmd, state);
    FEApplyList(self);
}

static void FEListReuse(id self, SEL _cmd)
{
    orig_listReuse(self, _cmd);
    FEApplyList(self);
}

static CGSize FEListSizing(id self, SEL _cmd, CGSize size, float hPriority, float vPriority)
{
    CGSize base = orig_listSizing(self, _cmd, size, hPriority, vPriority);
    if (!gPrefs.enabled || !gPrefs.resizeRows || gPrefs.shrink) {
        return base;
    }
    UILabel *label = FEListTitleLabel(self);
    if (!label || label.text.length == 0) {
        return base;
    }

    CGFloat width = label.bounds.size.width;
    if (width <= 1.0) {
        CGFloat cellWidth = size.width > 1.0 ? size.width : ((UIView *)self).bounds.size.width;
        width = MAX(cellWidth - 72.0, 0);
    }
    if (width <= 1.0) {
        return base;
    }

    label.preferredMaxLayoutWidth = width;
    CGFloat wanted = ceil([label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    CGFloat current = label.bounds.size.height > 0 ? label.bounds.size.height : ceil(label.font.lineHeight);
    if (wanted - current > 0.5) {
        base.height += wanted - current;
    }
    return base;
}

#pragma mark - Grid cell

static void (*orig_gridLayout)(id, SEL);
static void (*orig_gridWindow)(id, SEL);
static void (*orig_gridConfig)(id, SEL, id);
static void (*orig_gridReuse)(id, SEL);

static void FEApplyGrid(id cell)
{
    if (!gPrefs.enabled || !gPrefs.gridEnabled) {
        return;
    }
    FEConfigureLabel(FEGridTitleLabel(cell), gPrefs.gridMaxLines);
}

static void FEGridLayout(id self, SEL _cmd)
{
    FEApplyGrid(self);
    orig_gridLayout(self, _cmd);
    FEApplyGrid(self);
}

static void FEGridWindow(id self, SEL _cmd)
{
    orig_gridWindow(self, _cmd);
    FEApplyGrid(self);
}

static void FEGridConfig(id self, SEL _cmd, id state)
{
    orig_gridConfig(self, _cmd, state);
    FEApplyGrid(self);
}

static void FEGridReuse(id self, SEL _cmd)
{
    orig_gridReuse(self, _cmd);
    FEApplyGrid(self);
}

#pragma mark - Load confirmation

static void FEShowAlert(NSString *message)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
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
    FELog(@"loaded (v0.0.8)");
    FELoadPrefs();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, FEPrefsChanged,
                                    (__bridge CFStringRef)kReloadNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    Class listCell = FEClassWithNames(@[@"_TtC5Files25DOCItemCollectionListCell",
                                        @"Files.DOCItemCollectionListCell",
                                        @"DOCItemCollectionListCell"]);
    Class gridCell = FEClassWithNames(@[@"_TtC5Files25DOCItemCollectionGridCell",
                                        @"Files.DOCItemCollectionGridCell",
                                        @"DOCItemCollectionGridCell"]);

    FELog(@"classes: list=%@ grid=%@",
          listCell ? NSStringFromClass(listCell) : @"(nil)",
          gridCell ? NSStringFromClass(gridCell) : @"(nil)");

    Class labelClass = [UILabel class];
    FEHook(labelClass, @selector(setLineBreakMode:), (void *)&FESetLineBreakMode,
           (void **)&orig_setLineBreakMode, @"label");
    FEHook(labelClass, @selector(setNumberOfLines:), (void *)&FESetNumberOfLines,
           (void **)&orig_setNumberOfLines, @"label");
    FEHook(labelClass, @selector(setAttributedText:), (void *)&FESetAttributedText,
           (void **)&orig_setAttributedText, @"label");

    if (listCell) {
        FEHook(listCell, @selector(layoutSubviews), (void *)&FEListLayout, (void **)&orig_listLayout, @"list");
        FEHook(listCell, @selector(didMoveToWindow), (void *)&FEListWindow, (void **)&orig_listWindow, @"list");
        FEHook(listCell, @selector(_bridgedUpdateConfigurationUsingState:), (void *)&FEListConfig,
               (void **)&orig_listConfig, @"list");
        FEHook(listCell, @selector(prepareForReuse), (void *)&FEListReuse, (void **)&orig_listReuse, @"list");
        FEHook(listCell, @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:),
               (void *)&FEListSizing, (void **)&orig_listSizing, @"list");
    }
    if (gridCell) {
        FEHook(gridCell, @selector(layoutSubviews), (void *)&FEGridLayout, (void **)&orig_gridLayout, @"grid");
        FEHook(gridCell, @selector(didMoveToWindow), (void *)&FEGridWindow, (void **)&orig_gridWindow, @"grid");
        FEHook(gridCell, @selector(_bridgedUpdateConfigurationUsingState:), (void *)&FEGridConfig,
               (void **)&orig_gridConfig, @"grid");
        FEHook(gridCell, @selector(prepareForReuse), (void *)&FEGridReuse, (void **)&orig_gridReuse, @"grid");
    }

    if (gPrefs.showAlert) {
        FEShowAlert([NSString stringWithFormat:@"插件已加载\nlistCell = %@\ngridCell = %@",
                     listCell ? NSStringFromClass(listCell) : @"未找到",
                     gridCell ? NSStringFromClass(gridCell) : @"未找到"]);
    }
}

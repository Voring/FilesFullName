//
//  FilesFullName.x
//  Show the complete file name in the Files app instead of "head…tail".
//
//  Target: iOS 15 / 16 Files app (com.apple.DocumentsApp), arm64e, RootHide or rootless.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

#define FELog(fmt, ...) do { if (gPrefs.debugLog) NSLog((@"[FilesFullName] " fmt), ##__VA_ARGS__); } while (0)

static NSString *const kPrefsDomain = @"com.voring.filesfullname";
static NSString *const kReloadNotification = @"com.voring.filesfullname.reload";
static NSString *const kPrefsFile = @"/var/mobile/Library/Preferences/com.voring.filesfullname.plist";

typedef struct {
    BOOL enabled;        // 总开关
    BOOL gridEnabled;    // 是否处理图标（网格）视图
    BOOL shrink;         // YES = 单行缩字号显示；NO = 多行换行显示
    BOOL resizeRows;     // YES = 自动增高列表行以容纳多行文件名
    BOOL debugLog;
    NSInteger listMaxLines;  // 0 = 不限行数
    NSInteger gridMaxLines;  // 0 = 不限行数
} FEPrefs;

static FEPrefs gPrefs = {YES, YES, NO, YES, NO, 0, 2};

#pragma mark - Preferences

static id FEPrefCopyValue(NSString *key)
{
    CFStringRef valueKey = (__bridge CFStringRef)key;
    id value = (__bridge_transfer id)CFPreferencesCopyAppValue(valueKey, (__bridge CFStringRef)kPrefsDomain);
    if (value) {
        return value;
    }

    // Fallback: read the plist directly. On rootless / RootHide layouts the
    // preferences file does not live at the plain /var/mobile path.
    static NSMutableArray<NSString *> *candidates;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        candidates = [NSMutableArray array];
#if THEOS_PACKAGE_SCHEME_ROOTHIDE
        [candidates addObject:jbroot(kPrefsFile)];
#endif
        [candidates addObject:[@"/var/jb" stringByAppendingString:kPrefsFile]];
        [candidates addObject:kPrefsFile];
    });

    for (NSString *path in candidates) {
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
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return fallback;
}

static NSInteger FEPrefInt(NSString *key, NSInteger fallback)
{
    id value = FEPrefCopyValue(key);
    if ([value respondsToSelector:@selector(integerValue)]) {
        return [value integerValue];
    }
    return fallback;
}

static void FELoadPrefs(void)
{
    gPrefs.enabled = FEPrefBool(@"Enabled", YES);
    gPrefs.gridEnabled = FEPrefBool(@"GridEnabled", YES);
    gPrefs.shrink = FEPrefBool(@"ShrinkToFit", NO);
    gPrefs.resizeRows = FEPrefBool(@"ResizeRows", YES);
    gPrefs.debugLog = FEPrefBool(@"DebugLog", NO);
    gPrefs.listMaxLines = FEPrefInt(@"ListMaxLines", 0);
    gPrefs.gridMaxLines = FEPrefInt(@"GridMaxLines", 2);

    if (gPrefs.listMaxLines < 0) gPrefs.listMaxLines = 0;
    if (gPrefs.gridMaxLines < 0) gPrefs.gridMaxLines = 0;

    FELog(@"prefs loaded: enabled=%d grid=%d shrink=%d resize=%d listLines=%ld gridLines=%ld",
          gPrefs.enabled, gPrefs.gridEnabled, gPrefs.shrink, gPrefs.resizeRows,
          (long)gPrefs.listMaxLines, (long)gPrefs.gridMaxLines);
}

static void FEPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    FELoadPrefs();
}

#pragma mark - Runtime helpers

/// Reads an object ivar by name, walking up the class hierarchy.
/// Swift stored properties are exposed as plain ivars, e.g. "listTitleLabel".
static id FEIvarValue(id object, NSString *name)
{
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (ivar) {
            const char *type = ivar_getTypeEncoding(ivar);
            if (type && type[0] == '@') {
                return object_getIvar(object, ivar);
            }
            return nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static UILabel *FEObjectIvarAsLabel(id object, NSString *name)
{
    id value = FEIvarValue(object, name);
    return [value isKindOfClass:[UILabel class]] ? value : nil;
}

static Class FEClassWithNames(NSArray<NSString *> *names)
{
    for (NSString *name in names) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) {
            cls = NSClassFromString(name);
        }
        if (cls) {
            return cls;
        }
    }
    return Nil;
}

#pragma mark - Managed labels

// Every title label we touch is tagged with its desired maximum line count, so
// later UIKit setters from the app can be intercepted and corrected.
static const void *kFEFilenameLabelKey = &kFEFilenameLabelKey;

static NSInteger FEDesiredLines(UILabel *label)
{
    NSNumber *number = objc_getAssociatedObject(label, kFEFilenameLabelKey);
    return number ? number.integerValue : -1;
}

static void FESetDesiredLines(UILabel *label, NSInteger lines)
{
    objc_setAssociatedObject(label, kFEFilenameLabelKey, @(lines), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Filename labels live inside a DOCItemCollection*Cell. Checked at setter
/// time because the app may reset properties before our layout hook runs.
static BOOL FELabelLivesInItemCell(UILabel *label)
{
    UIView *view = label.superview;
    NSInteger depth = 0;
    while (view && depth++ < 14) {
        NSString *name = NSStringFromClass([view class]);
        if ([name containsString:@"DOCItemCollection"] && [name containsString:@"Cell"]) {
            return YES;
        }
        view = view.superview;
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
    return FELabelLivesInItemCell(label);
}

/// The label may render an attributed string whose paragraph style wins over
/// -lineBreakMode:, so the paragraph style needs to be rewritten as well.
static NSAttributedString *FERewrittenAttributedText(NSAttributedString *attributed, NSLineBreakMode mode)
{
    if (attributed.length == 0) {
        return attributed;
    }
    if ([attributed attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] == nil) {
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

#pragma mark - Label configuration

static void FEFixAttributedTextInPlace(UILabel *label, NSLineBreakMode mode)
{
    NSAttributedString *current = label.attributedText;
    if (current.length == 0) {
        return;
    }
    NSAttributedString *fixed = FERewrittenAttributedText(current, mode);
    if (fixed != current) {
        label.attributedText = fixed;
    }
}

static void FEConfigureLabel(UILabel *label, NSInteger maxLines)
{
    if (!label || ![label isKindOfClass:[UILabel class]]) {
        return;
    }

    FESetDesiredLines(label, maxLines);

    BOOL singleLine = gPrefs.shrink || maxLines == 1;
    NSInteger lines = singleLine ? 1 : maxLines;
    NSLineBreakMode mode = singleLine ? NSLineBreakByTruncatingTail : NSLineBreakByCharWrapping;

    if (label.numberOfLines != lines) {
        label.numberOfLines = lines;
    }
    if (label.lineBreakMode != mode) {
        label.lineBreakMode = mode;
    }
    if (label.adjustsFontSizeToFitWidth != singleLine) {
        label.adjustsFontSizeToFitWidth = singleLine;
    }
    if (singleLine && label.minimumScaleFactor < 0.5) {
        label.minimumScaleFactor = 0.5;
    }
    FEFixAttributedTextInPlace(label, mode);
}

static UILabel *FEListTitleLabel(id cell)
{
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[@"listTitleLabel", @"titleLabel", @"gridTitleLabel"];
    });
    for (NSString *name in names) {
        UILabel *label = FEObjectIvarAsLabel(cell, name);
        if (label) {
            return label;
        }
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
        UILabel *label = FEObjectIvarAsLabel(cell, name);
        if (label) {
            return label;
        }
    }
    return nil;
}

#pragma mark - UILabel setters (protect against later resets by the app)

static void (*orig_uilabel_setLineBreakMode)(id, SEL, NSLineBreakMode);
static void (*orig_uilabel_setNumberOfLines)(id, SEL, NSInteger);
static void (*orig_uilabel_setAttributedText)(id, SEL, NSAttributedString *);

static void FEUILabelSetLineBreakMode(id self, SEL _cmd, NSLineBreakMode mode)
{
    if (mode == NSLineBreakByTruncatingMiddle && FEIsManagedLabel(self) && !gPrefs.shrink) {
        mode = NSLineBreakByCharWrapping;
    }
    orig_uilabel_setLineBreakMode(self, _cmd, mode);
}

static void FEUILabelSetNumberOfLines(id self, SEL _cmd, NSInteger lines)
{
    if (FEIsManagedLabel(self) && !gPrefs.shrink) {
        NSInteger desired = FEDesiredLines(self);
        if (desired >= 0 && lines == 1) {
            lines = desired;
        }
    }
    orig_uilabel_setNumberOfLines(self, _cmd, lines);
}

static void FEUILabelSetAttributedText(id self, SEL _cmd, NSAttributedString *text)
{
    if (FEIsManagedLabel(self) && !gPrefs.shrink) {
        text = FERewrittenAttributedText(text, NSLineBreakByCharWrapping);
    }
    orig_uilabel_setAttributedText(self, _cmd, text);
}

#pragma mark - Hooks: list view

static void (*orig_listLayoutSubviews)(id, SEL);
static void (*orig_listDidMoveToWindow)(id, SEL);
static void (*orig_listUpdateConfiguration)(id, SEL, id);
static void (*orig_listPrepareForReuse)(id, SEL);
static CGSize (*orig_listSizeFitting)(id, SEL, CGSize, float, float);

static void FEApplyToListCell(id cell)
{
    if (!gPrefs.enabled) {
        return;
    }
    UILabel *label = FEListTitleLabel(cell);
    if (!label) {
        return;
    }
    if (!gPrefs.shrink) {
        // Multiline labels need a known width before Auto Layout can compute
        // their intrinsic height.
        CGFloat width = label.bounds.size.width;
        if (width > 1.0 && fabs(label.preferredMaxLayoutWidth - width) > 0.5) {
            label.preferredMaxLayoutWidth = width;
        }
    }
    FEConfigureLabel(label, gPrefs.listMaxLines);
}

static void FEListLayoutSubviews(id self, SEL _cmd)
{
    FEApplyToListCell(self);
    orig_listLayoutSubviews(self, _cmd);
    // Some builds re-apply their title configuration during layout; win the
    // last word here as well.
    FEApplyToListCell(self);
}

static void FEListDidMoveToWindow(id self, SEL _cmd)
{
    orig_listDidMoveToWindow(self, _cmd);
    FEApplyToListCell(self);
}

static void FEListUpdateConfiguration(id self, SEL _cmd, id state)
{
    orig_listUpdateConfiguration(self, _cmd, state);
    FEApplyToListCell(self);
}

static void FEListPrepareForReuse(id self, SEL _cmd)
{
    orig_listPrepareForReuse(self, _cmd);
    FEApplyToListCell(self);
}

static CGFloat FEAvailableTextWidth(id cell, UILabel *label, CGFloat proposedWidth)
{
    CGFloat width = label.bounds.size.width;
    if (width > 1.0) {
        return width;
    }

    CGFloat cellWidth = proposedWidth;
    if (cellWidth <= 1.0) {
        cellWidth = ((UIView *)cell).bounds.size.width;
    }
    if (cellWidth <= 1.0) {
        return 0;
    }
    // 16pt leading inset + thumbnail + spacing, roughly.
    return MAX(cellWidth - 16.0 - 56.0, 0);
}

static CGSize FEListSizeFitting(id self, SEL _cmd, CGSize size, float horizontalPriority, float verticalPriority)
{
    CGSize base = orig_listSizeFitting(self, _cmd, size, horizontalPriority, verticalPriority);

    if (!gPrefs.enabled || !gPrefs.resizeRows || gPrefs.shrink) {
        return base;
    }

    UILabel *label = FEListTitleLabel(self);
    if (!label || label.text.length == 0) {
        return base;
    }

    CGFloat width = FEAvailableTextWidth(self, label, size.width);
    if (width <= 1.0) {
        return base;
    }

    label.preferredMaxLayoutWidth = width;
    CGFloat wanted = ceil([label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    CGFloat current = label.bounds.size.height;
    if (current <= 0) {
        current = ceil(label.font.lineHeight);
    }

    CGFloat delta = wanted - current;
    if (delta > 0.5) {
        base.height += delta;
        FELog(@"row height %g -> %g (label wants %g)", base.height - delta, base.height, wanted);
    }
    return base;
}

#pragma mark - Hooks: grid view

static void (*orig_gridLayoutSubviews)(id, SEL);
static void (*orig_gridDidMoveToWindow)(id, SEL);
static void (*orig_gridUpdateConfiguration)(id, SEL, id);
static void (*orig_gridPrepareForReuse)(id, SEL);

static void FEApplyToGridCell(id cell)
{
    if (!gPrefs.enabled || !gPrefs.gridEnabled) {
        return;
    }
    FEConfigureLabel(FEGridTitleLabel(cell), gPrefs.gridMaxLines);
}

static void FEGridLayoutSubviews(id self, SEL _cmd)
{
    FEApplyToGridCell(self);
    orig_gridLayoutSubviews(self, _cmd);
    FEApplyToGridCell(self);
}

static void FEGridDidMoveToWindow(id self, SEL _cmd)
{
    orig_gridDidMoveToWindow(self, _cmd);
    FEApplyToGridCell(self);
}

static void FEGridUpdateConfiguration(id self, SEL _cmd, id state)
{
    orig_gridUpdateConfiguration(self, _cmd, state);
    FEApplyToGridCell(self);
}

static void FEGridPrepareForReuse(id self, SEL _cmd)
{
    orig_gridPrepareForReuse(self, _cmd);
    FEApplyToGridCell(self);
}

#pragma mark - Install

static BOOL FEHookMethod(Class cls, SEL selector, IMP replacement, IMP *original, const char *what)
{
    if (!cls) {
        return NO;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[FilesFullName] %@ has no -%s (%s)", NSStringFromClass(cls), sel_getName(selector), what);
        return NO;
    }
    MSHookMessageEx(cls, selector, replacement, original);
    FELog(@"hooked -%s on %s", sel_getName(selector), class_getName(cls));
    return YES;
}

__attribute__((constructor)) static void FEInitialize(void)
{
    FELoadPrefs();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    FEPrefsChanged,
                                    (__bridge CFStringRef)kReloadNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    Class listCell = FEClassWithNames(@[@"_TtC5Files25DOCItemCollectionListCell",
                                        @"Files.DOCItemCollectionListCell",
                                        @"DocumentManagerExecutables.DOCItemCollectionListCell",
                                        @"DOCItemCollectionListCell"]);
    Class gridCell = FEClassWithNames(@[@"_TtC5Files25DOCItemCollectionGridCell",
                                        @"Files.DOCItemCollectionGridCell",
                                        @"DocumentManagerExecutables.DOCItemCollectionGridCell",
                                        @"DOCItemCollectionGridCell"]);

    NSLog(@"[FilesFullName] loaded. listCell=%@ gridCell=%@",
          listCell ? NSStringFromClass(listCell) : @"(nil)",
          gridCell ? NSStringFromClass(gridCell) : @"(nil)");

    // Protect the title labels against setters the app may call later.
    Class labelClass = [UILabel class];
    FEHookMethod(labelClass, @selector(setLineBreakMode:), (IMP)&FEUILabelSetLineBreakMode,
                 (IMP *)&orig_uilabel_setLineBreakMode, "label line break");
    FEHookMethod(labelClass, @selector(setNumberOfLines:), (IMP)&FEUILabelSetNumberOfLines,
                 (IMP *)&orig_uilabel_setNumberOfLines, "label number of lines");
    FEHookMethod(labelClass, @selector(setAttributedText:), (IMP)&FEUILabelSetAttributedText,
                 (IMP *)&orig_uilabel_setAttributedText, "label attributed text");

    if (listCell) {
        FEHookMethod(listCell, @selector(layoutSubviews), (IMP)&FEListLayoutSubviews,
                     (IMP *)&orig_listLayoutSubviews, "list layout");
        FEHookMethod(listCell, @selector(didMoveToWindow), (IMP)&FEListDidMoveToWindow,
                     (IMP *)&orig_listDidMoveToWindow, "list window");
        FEHookMethod(listCell, @selector(_bridgedUpdateConfigurationUsingState:), (IMP)&FEListUpdateConfiguration,
                     (IMP *)&orig_listUpdateConfiguration, "list configuration");
        FEHookMethod(listCell, @selector(prepareForReuse), (IMP)&FEListPrepareForReuse,
                     (IMP *)&orig_listPrepareForReuse, "list reuse");
        FEHookMethod(listCell, @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:),
                     (IMP)&FEListSizeFitting, (IMP *)&orig_listSizeFitting, "list sizing");
    }

    if (gridCell) {
        FEHookMethod(gridCell, @selector(layoutSubviews), (IMP)&FEGridLayoutSubviews,
                     (IMP *)&orig_gridLayoutSubviews, "grid layout");
        FEHookMethod(gridCell, @selector(didMoveToWindow), (IMP)&FEGridDidMoveToWindow,
                     (IMP *)&orig_gridDidMoveToWindow, "grid window");
        FEHookMethod(gridCell, @selector(_bridgedUpdateConfigurationUsingState:), (IMP)&FEGridUpdateConfiguration,
                     (IMP *)&orig_gridUpdateConfiguration, "grid configuration");
        FEHookMethod(gridCell, @selector(prepareForReuse), (IMP)&FEGridPrepareForReuse,
                     (IMP *)&orig_gridPrepareForReuse, "grid reuse");
    }
}

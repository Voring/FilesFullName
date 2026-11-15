//
//  FilesFullName.x
//  Show the complete file name in the Files app instead of "head…tail".
//
//  Target: iOS 15 / 16 Files app (com.apple.DocumentsApp), arm64, RootHide or rootless.
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
    NSInteger gridMaxLines;
} FEPrefs;

static FEPrefs gPrefs = {YES, NO, NO, YES, NO, 0, 2};

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
    gPrefs.gridEnabled = FEPrefBool(@"GridEnabled", NO);
    gPrefs.shrink = FEPrefBool(@"ShrinkToFit", NO);
    gPrefs.resizeRows = FEPrefBool(@"ResizeRows", YES);
    gPrefs.debugLog = FEPrefBool(@"DebugLog", NO);
    gPrefs.listMaxLines = FEPrefInt(@"ListMaxLines", 0);
    gPrefs.gridMaxLines = FEPrefInt(@"GridMaxLines", 2);

    if (gPrefs.listMaxLines < 0) gPrefs.listMaxLines = 0;
    if (gPrefs.gridMaxLines < 1) gPrefs.gridMaxLines = 1;

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

/// The label may render an attributed string whose paragraph style wins over
/// -lineBreakMode:, so the paragraph style needs to be rewritten as well.
static void FEFixParagraphStyle(UILabel *label, NSLineBreakMode mode)
{
    NSAttributedString *attributed = label.attributedText;
    if (attributed.length == 0) {
        return;
    }
    if ([attributed attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] == nil) {
        return;
    }

    NSMutableAttributedString *mutable = [attributed mutableCopy];
    [attributed enumerateAttribute:NSParagraphStyleAttributeName
                            inRange:NSMakeRange(0, attributed.length)
                            options:0
                         usingBlock:^(id value, NSRange range, BOOL *stop) {
        NSMutableParagraphStyle *style = value ? [value mutableCopy] : [[NSMutableParagraphStyle alloc] init];
        if (style.lineBreakMode != mode) {
            style.lineBreakMode = mode;
            [mutable addAttribute:NSParagraphStyleAttributeName value:style range:range];
        }
    }];
    label.attributedText = mutable;
}

#pragma mark - Label configuration

static void FEApplyLabel(UILabel *label, NSInteger maxLines)
{
    if (!label || ![label isKindOfClass:[UILabel class]]) {
        return;
    }

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
    FEFixParagraphStyle(label, mode);
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

#pragma mark - Hooks: list view

static void (*orig_listLayoutSubviews)(id, SEL);
static CGSize (*orig_listSizeFitting)(id, SEL, CGSize, float, float);

static void FEListLayoutSubviews(id self, SEL _cmd)
{
    if (gPrefs.enabled && !gPrefs.shrink) {
        UILabel *label = FEListTitleLabel(self);
        if (label) {
            // Multiline labels need a known width before Auto Layout can
            // compute their intrinsic height.
            CGFloat width = label.bounds.size.width;
            if (width > 1.0 && fabs(label.preferredMaxLayoutWidth - width) > 0.5) {
                label.preferredMaxLayoutWidth = width;
            }
            FEApplyLabel(label, gPrefs.listMaxLines);
        }
    } else if (gPrefs.enabled) {
        FEApplyLabel(FEListTitleLabel(self), 1);
    }
    orig_listLayoutSubviews(self, _cmd);
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

static void FEGridLayoutSubviews(id self, SEL _cmd)
{
    if (gPrefs.enabled && gPrefs.gridEnabled) {
        UILabel *label = FEGridTitleLabel(self);
        if (label) {
            FEApplyLabel(label, gPrefs.gridMaxLines);
        }
    }
    orig_gridLayoutSubviews(self, _cmd);
}

#pragma mark - Install

static BOOL FEHookClass(Class cls, SEL selector, IMP replacement, IMP *original, const char *what)
{
    if (!cls) {
        return NO;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        FELog(@"%@ is missing -%s", NSStringFromClass(cls), sel_getName(selector));
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

    if (!listCell) {
        NSLog(@"[FilesFullName] list cell class not found; tweak inactive.");
    }
    if (!gridCell) {
        FELog(@"grid cell class not found; grid titles untouched.");
    }

    FEHookClass(listCell, @selector(layoutSubviews), (IMP)&FEListLayoutSubviews, (IMP *)&orig_listLayoutSubviews, "list layout");
    FEHookClass(listCell, @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:),
                (IMP)&FEListSizeFitting, (IMP *)&orig_listSizeFitting, "list sizing");

    if (gridCell) {
        FEHookClass(gridCell, @selector(layoutSubviews), (IMP)&FEGridLayoutSubviews, (IMP *)&orig_gridLayoutSubviews, "grid layout");
    }
}

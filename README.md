# FilesFullName

一个 iOS 越狱插件（dylib），让「文件」App 显示**完整的文件名**，而不是像系统默认那样把文件名中间省略成 `前半段…后半段`。

- 目标 App：`com.apple.DocumentsApp`（文件 App），iOS 15 / 16
- 架构：**arm64e**（iOS 的 arm64e 进程（如「文件」App）不会加载只有 arm64 切片的 dylib，必须提供 arm64e 切片）
- 已按 RootHide（Dopamine roothide）布局打包：`.jbroot` 相对路径链接、rootful 风格安装路径
- 依赖：`mobilesubstrate`

## 效果

| 位置 | 默认行为 |
| --- | --- |
| 列表视图（列） | 标题改为按字符换行（默认可显示任意行数），列表行会自动增高以容纳完整名称 |
| 图标视图（网格） | 同样改为换行，默认最多 2 行（`GridEnabled` / `GridMaxLines` 可关闭或调整） |

如果你不喜欢多行，可以把 `ShrinkToFit` 设为 `true`：标题保持单行，自动缩小字号来塞下完整名称。

## 安装

在越狱设备上直接安装 `packages/` 里的 deb：

```bash
# 例：通过 SSH / TrollStore 环境安装
dpkg -i com.voring.filesfullname_0.0.2_iphoneos-arm64e.deb
killall -9 Files
```

也可以把 deb 放进 Sileo / Zebra 的本地源安装。

## 配置（可选）

默认参数已经可用。需要调整时，写入：

```
/var/mobile/Library/Preferences/com.voring.filesfullname.plist
```

（RootHide / rootless 环境下就是各自 jbroot 里的同名路径，插件会依次尝试 `jbroot` 路径、`/var/jb` 路径和普通路径。）

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `Enabled` | bool | `true` | 总开关 |
| `ListMaxLines` | int | `0` | 列表标题最多行数，`0` = 不限（完整显示） |
| `GridEnabled` | bool | `true` | 是否也处理网格视图的标题 |
| `GridMaxLines` | int | `2` | 网格标题最多行数 |
| `ShrinkToFit` | bool | `false` | `true` = 单行缩字号；`false` = 多行换行 |
| `ResizeRows` | bool | `true` | 让列表行按文字高度自动增高 |
| `DebugLog` | bool | `false` | 输出调试日志（Console.app / `log stream` 可看） |

修改后重启「文件」App 生效；也可以发送 Darwin 通知让插件重新读取配置：

```bash
notifyutil -p com.voring.filesfullname.reload
```

## 工作原理

「文件」App 的列表 / 网格单元格是 `Files` 模块里的 Swift 类：

- `_TtC5Files25DOCItemCollectionListCell` → 标题 `UILabel` ivar：`listTitleLabel`
- `_TtC5Files25DOCItemCollectionGridCell` → 标题 `UILabel` ivar：`gridTitleLabel`

系统给这些 label 设置了 `numberOfLines = 1` + `NSLineBreakByTruncatingMiddle`，所以长文件名会变成中间省略号。插件：

1. 在 `-layoutSubviews`、`-didMoveToWindow`、`-_bridgedUpdateConfigurationUsingState:`、`-prepareForReuse` 前后把标题 label 改成 `numberOfLines = ListMaxLines`、`lineBreakMode = NSLineBreakByCharWrapping`；
2. 如果标题是富文本（带 `NSParagraphStyle`），同步改写段落样式里的换行模式；并 Hook `UILabel` 的 `setLineBreakMode:` / `setNumberOfLines:` / `setAttributedText:`，拦掉 App 之后又把标题改回单行中间省略的行为；
3. 在 `-systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:` 里按 `sizeThatFits:` 计算文字实际需要的高度，把单元格高度补足，避免多行文字被裁掉或重叠。

类名同时兼容 `Files.DOCItemCollectionListCell` / `DocumentManagerExecutables.DOCItemCollectionListCell` 等不同系统版本的名字；找不到类时插件会安全退出，不影响 App。

## 编译

需要 [Theos](https://github.com/theos/theos) + iOS SDK：

```bash
export THEOS=/opt/theos
make clean
make package FINALPACKAGE=1
```

`Makefile` 里默认 `THEOS_PACKAGE_SCHEME = roothide`（RootHide / Dopamine）。如果你的设备是普通 rootless 越狱，把这一行改成：

```make
THEOS_PACKAGE_SCHEME = rootless
```

rootful 环境则删掉这一行。

Linux 上如果链接报 `ld: unrecognised emulation mode`，说明 clang 调用了宿主 GNU ld，需要显式指定 Theos 自带的 ld64：

```bash
make package ADDITIONAL_LDFLAGS="-fuse-ld=$THEOS/toolchain/linux/iphone/bin/ld64"
```

另外 Linux 的 clang/lld 生成的 arm64e Mach-O 头里 `cpusubtype` 可能是 `0`，而 iOS 要求带 ptrauth ABI 位（`0x80000002`），否则 dyld 仍会拒绝加载。构建后执行：

```bash
./tools/fix-arm64e.sh .theos/obj/debug/FilesFullName.dylib
```

（macOS 上用 Xcode 版 Theos 构建则不需要这一步。）

仓库里的 GitHub Actions 工作流会在 macOS 上自动构建并上传 deb。

## 调试建议

安装后先用 Console / `log stream` 确认插件是否被加载（启动「文件」App 时应看到）：

```
[FilesFullName] loaded. listCell=... gridCell=...
```

`listCell=(nil)` 说明类名没匹配上；完全没有这条日志说明 dylib 没有被注入（检查架构是否为 arm64e、签名是否有效）。

如果日志出现但样式没变：

1. 把 `DebugLog` 设为 `true`，看是否命中 `layoutSubviews` / 行高计算；
2. 保持 `ResizeRows = true`，避免多行文字被裁；
3. 仍然不理想时把 `ShrinkToFit` 设为 `true`，退回单行缩字号的稳妥方案。

## 目录

```
Tweak.x                                       插件源码
FilesFullName.plist                           MobileSubstrate 过滤（com.apple.DocumentsApp）
Makefile / control                             Theos 工程与包信息
tools/fix-arm64e.sh                           Linux 构建的 arm64e 头修补 + 重签
packages/*.deb                                 已构建的安装包
.github/workflows/build.yml                    CI 构建
```

## License

MIT

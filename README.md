# VHDX Reader

外置 SSD 上的 VHDX / BitLocker / NTFS 只读浏览器。包含 Rust 核心、Windows / Android / macOS / iOS/iPadOS Flutter 界面，以及 Windows / Linux 命令行工具。已接入文本、图片、PDF 内嵌预览和视频播放；独立音频界面仍待实现。

## 当前桌面测试版：0.6.12+19

当前源码已为 Windows/macOS 使用已保存 BitLocker 凭据接入系统身份验证：Windows 11+ 使用 Windows Hello PIN/指纹/人脸，Mac 使用 Touch ID/登录密码。已有记录同样受保护，取消或不可用时保留手动解锁；已打开的卷仍需主动锁定或关闭。Windows x64 和 macOS ARM64 测试包均位于 `artifacts/0.6.12/`，与 `manifest.json`、`SHA256SUMS` 平铺存放。Windows 完整解压后运行 `vhdx_reader.exe`；Mac 解压后运行 `VHDX Reader.app`。Windows 需先配置 Windows Hello；Mac 使用 Touch ID 或登录密码。首次解锁时勾选记住，再锁定分区并点击“验证身份并解锁”即可测试。

## 四平台发布：0.6.11+18

移动端使用已保存 BitLocker 凭据前必须通过系统人脸、指纹或设备锁屏密码验证；取消、认证不可用或旧原生组件均不会跳过验证。视频预览改为根据实际播放失败事件显示错误，避免可恢复的解码诊断遮挡正常播放。

本次全部交付文件平铺在 `artifacts/0.6.11/`，不再分平台子目录：Windows x64 ZIP、Android ARM64 APK、macOS ARM64 ZIP、iOS 开发签名 IPA、未签名真机 ZIP 和模拟器 ZIP。该目录的 `manifest.json` 与 `SHA256SUMS` 记录版本、验证结果和包校验值；构建与测试日志保存在 `.native/release-0.6.11/`。

Windows 完整解压后运行 `vhdx_reader.exe`；Android 为开发签名测试包；macOS 未做 Developer ID 公证；iOS 开发签名包仅限描述文件允许的设备。移动端真实人脸/指纹/PIN 成功验证仍需人工验收。

构建输出可用 Windows/Android 脚本的目录参数和 Apple 脚本的 `VHDX_ARTIFACT_DIR` 指定，避免新产物散落到 `artifacts/` 根目录。下文保留旧版本记录。

## 读取性能与缓存设置（0.6.10+17）

本版合并 BitLocker 小扇区读取、复用目录分页句柄并优化缓存淘汰。设置新增“文件读取缓存”（16 / 32 / 64 / 128 / 256 MiB，默认 16）和“BitLocker 密文缓存”（1 / 2 / 4 / 8 / 16 MiB，默认 1）。配置保存在本机，重新解锁或重新打开镜像后生效；按每个已解锁卷分别计量，不产生明文磁盘缓存。大缓存主要改善重复访问，首次读取不保证更快，实测见 [读取性能记录](docs/read-performance.md)。本版应用须与 ABI 7 读取组件配套使用。

本次版本文件：

- Windows x64：`artifacts/vhdx-reader-0.6.10-windows-x64.zip`，完整解压后运行 `vhdx_reader.exe`；展开目录为 `artifacts/gui-windows-cache-settings/`。
- Android ARM64：`artifacts/vhdx-reader-0.6.10-android-arm64.apk`。
- macOS Apple Silicon：`artifacts/vhdx-reader-0.6.10-macos-arm64.zip`。
- iPhone/iPad 开发签名包：`artifacts/vhdx-reader-0.6.10-ios-development.ipa`，仅限签名描述文件允许的设备。
- iPhone/iPad 未签名真机包及 ARM64 模拟器包：`artifacts/vhdx-reader-0.6.10-ios-device-arm64-unsigned.zip`、`artifacts/vhdx-reader-0.6.10-ios-simulator-arm64.zip`。

本次构建验证记录为 `artifacts/cache-settings-release-validation.json`；旧版本文件和验证记录保留。

## BitLocker 记住并自动解锁（v0.6）

解锁时可勾选“在此设备记住，下次自动解锁”，成功后将密码或恢复密钥写入系统安全存储；密码文件也可记住。再次打开同一卷自动尝试一次；移动端需先通过系统人脸、指纹或锁屏 PIN/密码验证（Android 7–10 使用锁屏凭据），取消或失败回到手动输入。侧栏底部的“设置 → 已保存的解锁信息”可删除单条或全部记录。主动锁定不会立刻自动解开，删除记录不影响已打开的文件。

iPhone/iPad/macOS 使用 Keychain，Windows 使用当前用户 DPAPI，Android 使用 Keystore + AES-GCM。凭据不写入 VHDX/U 盘、不回填密码框、不提供跨设备同步；Linux 暂禁用记住功能。凭据功能从 ABI 6 引入，当前包含缓存设置的源码使用 ABI 7，应用和原生组件需要一起更新。具体边界、签名身份和测试说明见 [凭据存储说明](docs/credential-vault.md)。

v0.6 已通过 Windows DPAPI、Android 14 真机 Keystore、macOS 桌面钥匙串，以及 iPhone/iPad 模拟器的保存、重开与删除回归；iPhone SE 真机钥匙串用例也实际执行通过（Xcode 测试后清理停滞，详情见验证记录）；Flutter 10 项测试和 Rust 14 项单元测试通过。平台明细及交付包哈希见 `artifacts/vault-validation/results.json`。

## 统一屏幕与播放体验（0.6.9）

Windows、Android、macOS、iPhone/iPad 共用文件浏览与全屏预览界面。左上角打开磁盘侧栏，底部进入设置；右上角展示菜单提供网格/列表、名称/大小/修改日期/类型排序及升降序。文件列表没有标签栏、筛选栏和列标题，支持下拉刷新，桌面可用 F5。

横屏采用紧凑布局，内容避让刘海、挖孔和导航区域；旋转或调整窗口大小保留目录、排序与预览。所有文件直接占满预览区域：移动端进入沉浸显示，桌面填满当前应用窗口。文本、图片和 PDF 保留文件操作栏；Windows 文档预览保留窗口拖动与最小化/最大化/关闭，macOS 保留系统标题栏。

视频只保留播放/暂停、进度条和静音三个透明控件，单击显隐。左滑下一个、右滑上一个，遵循当前目录排序且首尾不循环；桌面也可用左右方向键。长按画面（桌面按住鼠标）临时 2 倍速，松开恢复原速度与播放/暂停状态。向下拖动时暂停并保留当前帧，画面跟手下移、逐渐半透明并露出列表；短距离松手或触摸取消后回弹并恢复原播放状态，达到阈值后动画退出。拖动进度条不触发切换或退出。空格控制播放，Esc/系统返回退出；进入后台会停止临时倍速并暂停。

Android 与 iPhone/iPad 的设置提供“自动、固定竖屏、固定横屏”，跨重启保存；自动跟随系统。iPad 本版采用全屏配置以支持固定方向，分屏和窗口模式不在本次适配范围。Android 摇晃旋转仍为默认关闭的实验功能：用户反馈未生效，暂缓排查，也未移植到其他平台。

0.6.9 历史交付文件：

- Windows：`artifacts/gui-windows-platform-preview/vhdx_reader.exe`、`artifacts/vhdx-reader-windows-platform-preview.zip`（完整解压运行）。
- Android ARM64：`artifacts/vhdx-reader-android-arm64-platform-preview.apk`。
- macOS Apple Silicon：`artifacts/vhdx-reader-macos-arm64-platform-preview.zip`。
- iPhone/iPad 模拟器：`artifacts/vhdx-reader-ios-simulator-platform-preview.zip`。
- iPhone/iPad 未签名真机包：`artifacts/vhdx-reader-ios-device-platform-preview-unsigned.zip`。
- 已登记 iPhone 的开发签名包：`artifacts/vhdx-reader-ios-platform-preview-development.ipa`，仅限签名描述文件允许的设备。

验证与安装结果见 `artifacts/platform-preview-validation.json`。此前 0.6.3 统一导航验证记录保留在 `artifacts/unified-ui-validation.json`；此前 Android 各次手势体验包和验证记录也保留。Linux 仍仅交付 CLI，没有独立图形应用。

## Windows 图形界面

当前版本请完整解压 `artifacts/vhdx-reader-0.6.10-windows-x64.zip`，打开其中的 `vhdx_reader.exe`。也可从 `artifacts/gui-windows-cache-settings/` 直接运行。保留同目录的 DLL、`native/` 和 `data/`，不要单独复制 EXE。

1. 选择本机或外置 SSD 上的 VHDX，可一次选择多个文件。每个镜像使用独立会话，可从侧栏切换；重复打开同一路径会切换到已有会话。
2. 普通 NTFS 分区直接进入文件列表；BitLocker 分区可输入密码、导入 `password.txt`，或选择恢复密钥模式。
3. 点击文件夹进入目录，点击文件预览。默认隐藏 NTFS 系统项，可切换显示。
4. 支持列表/网格、完整目录排序、导出到新文件、取消操作，以及锁定/关闭镜像。
5. 侧栏切换保留各自的解锁状态、目录、展示方式和预览；锁定、关闭及读取错误仅影响对应镜像。

解锁输入默认不保存，主动勾选记住且解锁成功后才写入设备安全存储；提交后清空输入框。密码文件支持 UTF-8 和带 BOM 的 UTF-16，仅移除文件末尾一个换行；手动输入的密码不修剪空格。示例密码留在 `examples/password.txt`，不写入程序或日志。

文本预览读取最多 256 KiB，支持 UTF-8、UTF-16 LE/BE；图片预览支持 PNG/JPEG/GIF/WebP/BMP，源文件上限 16 MiB，显示解码限制为 2048×2048。其他格式可先导出查看。当前图片预览用于查看内容，不是原始分辨率编辑器。

PDF 点击后进入内嵌阅读区，支持翻页、页码跳转、缩放、适合页面及返回列表。切换镜像保留页码和缩放。PDFium 通过 Rust 文件句柄按需读取，使用 64 KiB 页、1 MiB 的 Dart 读取缓存，不生成临时明文 PDF；每个阅读器的渲染缓存目标为 32 MiB（并非进程内存硬上限）。锁定/切换分区/关闭镜像会让旧文件句柄失效，关闭预览会清空读取缓存。独立 PDF 密码、外部链接、附件、搜索和目录面板尚未接入。

视频点击后直接全屏预览，支持播放/暂停、拖动进度和静音，手势与快捷键见上面的统一体验说明。切换镜像自动暂停，切回保留进度并由用户继续播放；返回列表或锁定/关闭镜像会释放播放器。通过仅绑定 `127.0.0.1` 的随机地址按字节读取，不先导出整个视频；关闭磁盘缓存和临时播放列表。已实测 MP4 / H.264 + AAC，其他扩展名会尝试交给解码器，尚未验证 HEVC、4K、HDR、外挂字幕及音轨切换。

## Android ARM64

0.6.9 已同步上述共享功能到其他图形平台。横屏采用紧凑顶栏、无独立底部状态条、右侧文件辅助信息和较矮网格；展示菜单用三组按钮和分割线。文件点击后直接进入全屏预览，隐藏文件列表、磁盘工具栏和状态条；文本/图片/PDF 保留紧凑的文件操作栏。旋转和窗口调整保留目录、排序与预览状态。页面背景、抽屉和遮罩延伸到屏幕边缘，交互内容避让刘海、挖孔和导航区域。

“磁盘侧栏 → 设置 → 屏幕方向”提供自动（跟随系统）、固定竖屏、固定横屏；选择立即生效并跨重启保存，仅影响本应用。横屏允许左右两侧朝向；自动遵守系统旋转设置。预览继续遵守所选方向，退出恢复正常系统栏。视频仅保留播放/暂停、进度条、静音三个透明悬浮控件；单击画面显示/隐藏，向下拖动时暂停并保留当前帧，画面跟手下移并逐渐变淡，背景露出原文件列表；达到距离阈值或快速下甩后动画退出，否则回弹并恢复拖动前的播放/暂停状态。触摸取消会回弹；旋转中断拖动，进入后台不会自动恢复播放。系统返回键或 Esc 也能退出。左滑下一个视频、右滑上一个视频，按当前目录的展示排序过滤视频文件，首尾提示且不循环；切换保留静音。长按画面临时 2 倍速，松开恢复原速度和播放/暂停状态；指针取消、切换视频或进入后台都会结束倍速，后台恢复后不自动播放。拖动进度条不触发下滑退出；退出释放播放器和读取句柄，并回到原目录及滚动位置。

实验设置“摇晃确认旋转”（默认关闭，用户反馈未生效，当前暂缓排查）的设计如下。在应用全屏前台、屏幕方向为自动且手机关闭自动旋转时，先拿成目标横/竖方向，再明显往返摇晃两三下，保持方向稳定约半秒后确认切换。单次晃动、轻微抖动、平放、同一横竖方向和摇完改变目标不触发；切换后冷却 2.5 秒。固定方向、后台和分屏不启用检测；不修改手机的全局旋转设置。摇晃后的方向只在当前应用前台保持，关闭开关、离开应用或改变系统旋转设置后恢复跟随系统。主动指定方向期间系统旋转建议按钮可能暂时隐藏；iPad 和窗口模式暂未适配。自动化验证使用合成传感器轨迹，实际握持力度及走路/乘车防误触仍需人工体验。

安装 `artifacts/vhdx-reader-android-arm64-platform-preview.apk`，可覆盖旧版并保留解锁记录。这是开发签名的测试包，最低 Android 7.0（API 24），仅支持 ARM64；其他 Android 版本和厂商兼容性仍需扩充验证。

点击左上角图标展开磁盘侧栏，再点击“添加镜像”，通过系统文件选择器选择手机或 USB SSD 中的 VHDX，支持多选。系统必须能够识别 SSD 的文件系统，并由文件提供器提供可随机访问的文件描述符。应用按偏移直接读取，不先把整个 VHDX 复制进手机，也不申请“所有文件访问”权限。云盘/管道等不可随机读取的来源会被拒绝。Android 的 `content://` 地址保持原样，不伪造本地路径。

左上角图标打开动态侧栏：已加载磁盘可切换并标记当前项，下方提供当前磁盘的分区、信息、刷新、锁定和关闭操作。侧栏底部固定“设置”入口，进入独立设置页管理隐藏文件和解锁信息；从设置返回保留目录和展示模式，进入设置前先退出预览。标题不再下拉，右上角只保留“展示”菜单，分三组：网格/列表、名称/大小/修改日期/类型、升序/降序。取消标签条、文件筛选和列标题，列表与网格均可下拉刷新；排序覆盖完整目录。手机预览占据内容区，系统返回键依次关闭预览、返回上级目录；平板同样直接全屏预览。BitLocker 支持输入密码、选择密码文件或恢复密码。导出使用系统“创建文件”窗口；失败/取消后尝试删除本次创建的未完成文件。原镜像只读。文本、图片、PDF、视频复用桌面的有界读取通路。

本次摇晃旋转验证结果见 `artifacts/shake-rotation-validation.json`；下拉动效验证结果见 `artifacts/video-pull-validation.json`；视频手势验证结果见 `artifacts/video-gestures-validation.json`；全屏预览记录见 `artifacts/fullscreen-preview-validation.json`；上一版屏幕适配记录见 `artifacts/android-responsive-validation.json`；跨平台当前结果见 `artifacts/platform-preview-validation.json`。

当前不自动恢复上次打开的镜像；应用退出后需重新选择，已记住的卷会自动尝试解锁。USB 拔插、各厂商外置存储提供器，以及长时间后台运行仍需专门验证。

## macOS ARM64

解压 `artifacts/vhdx-reader-macos-arm64-platform-preview.zip`，将 `VHDX Reader.app` 放到用户的“应用程序”目录并打开。当前包仅用于 Apple Silicon Mac，部署目标为 macOS 12.0，尚不提供已验证的 Intel 包。使用 ad-hoc 开发签名，未完成 Developer ID 签名及公证。

通过系统文件选择器打开 VHDX；密码/恢复密码、多个镜像、文本/图片/PDF/视频使用同一套界面。应用启用 App Sandbox，文件访问由系统选择窗口授予；导出同样通过系统保存窗口选择新文件。Rust 和四个磁盘库随 `.app` 放入 `Contents/Frameworks/vhdx`，移动整个应用后仍按相对位置加载。视频按需读取服务仅绑定回环地址，应用配置了对应网络权限。

## iPhone / iPad ARM64（开发测试版）

`app/ios` 已完成设备 ARM64 与模拟器 ARM64 构建，部署目标为 iOS/iPadOS 15+。0.6.10 当前交付文件及验证结果以本文顶部“读取性能与缓存设置”为准，以下旧文件名和签名记录保留作历史参考。iPhone 和 iPad 模拟器各通过 7 项整合测试及 2 项原生文件访问测试。整合测试覆盖：安全存储保存/重开/删除、密码文件解锁、多镜像隔离、文本预览、PDF 按需渲染/翻页/缩放、H.264 视频播放/拖动进度/全屏/关闭。当前验收环境为 Xcode 27.2、iOS 27.2 模拟器；尚未验证较旧 iOS、真机音频、系统文件选择器的真实外置 SSD 授权及拔插。

- `artifacts/vhdx-reader-ios-simulator-arm64.zip`：Apple Silicon Mac 模拟器应用。
- `artifacts/vhdx-reader-ios-device-arm64-unsigned.zip`：未签名真机 Release 应用，不能直接安装。
- `artifacts/vhdx-reader-ios.sha256`：两个包的 SHA-256。
- `artifacts/vhdx-reader-ios-arm64-development.ipa`：本次已安装到 iPhone SE（第 3 代）的个人开发签名包，仅供描述文件登记的设备使用；另附同名 `.sha256` 校验文件。当前描述文件于 2026-11-11 07:54 UTC 到期，到期需重新签名安装。

此前已在 iOS 27.2 的 iPhone SE（第 3 代）完成 0.6.3 Release 开发签名、覆盖安装和启动验证，启动界面和进程均正常。测试镜像及 `password.txt` 单独复制到“我的 iPhone → VHDX Reader → vhdx-validation”，没有打入 IPA。此项仅确认真机安装和启动，文件选择、解锁、PDF/视频/声音和外置 SSD 的真机交互仍需验收。

上游 libmpv 的模拟器切片未编译音频输出驱动，因此模拟器播放画面时明确提示无声音，并禁用音量控制；真机切片启用 AudioUnit，通过 AVAudioSession 管理播放音频。模拟器测试不能替代真机声音验收。手机退出全屏后保持横屏时，文件区和播放控制栏可滚动，不再发生高度溢出。

通过“文件”选择器打开本机或外置磁盘文件，使用 `asCopy: false`，以只读描述符交给 Rust。iOS 文件授权和 `NSFileCoordinator` 读取访问保持到镜像会话关闭，密码文件只在解锁期间访问。切换镜像保留各自授权，关闭镜像释放对应授权。导出先选择目标文件夹，再以排他创建方式写入新文件；已有同名文件不会被覆盖。系统存储提供器可能自行下载云端文件，外置 SSD 是否可见取决于 iOS 对其文件系统及连接的支持。

Rust 核心和四个 C 库各自封装为随 App 内置的动态 XCFramework，包含设备 ARM64 与模拟器 ARM64 两种构建。PDFium 和视频解码库使用校验哈希固定的 iOS 依赖。测试镜像和密码不放入应用包。

在配置好 Xcode、Rust 1.96.1、Python 3.12+、CocoaPods 和项目 Flutter SDK 的 Mac 上执行：

```bash
bash scripts/build-ios.sh
bash scripts/test-ios.sh
```

构建脚本生成模拟器 ZIP 和 **未签名设备 ZIP**；后者不能直接安装，仍需在 Xcode 的 `app/ios/Runner.xcworkspace` 中配置自己的 Signing Team 后运行到真机。测试脚本创建独立 iPhone/iPad 模拟器，注入私有样本，覆盖密码解锁、多镜像、PDF/视频及文件描述符释放，结束时删除这些测试模拟器。截图保存在 `artifacts/ios-validation/`。`run-ios-integration.sh` 在 Flutter 卸载测试应用前收集截图；XCTest 使用统一构建目录和 ad-hoc 模拟器签名，确保包括 `Ass.framework` 在内的完整依赖随宿主加载。真机文件选择器人工验收和 USB SSD 拔插/后台恢复尚待验证。

## 已实现

- 独立固定/动态 VHDX 读取，GPT 与主 MBR 分区识别。
- 打开前验证 VHDX 双头、区域表 CRC32C；校验 GPT CRC32 和分区边界。
- BitLocker 密码/恢复密码解锁，两种方式均已用现有样本验证；解密数据通过自定义 I/O 直接提供给 NTFS。
- 分页列目录、按偏移读取文件、流式 SHA-256、导出至新文件。
- 设置中的“文件读取缓存”可选 16 / 32 / 64 / 128 / 256 MiB（默认 16），适用于普通 NTFS 和 BitLocker；“BitLocker 密文缓存”可选 1 / 2 / 4 / 8 / 16 MiB（默认 1），用于合并解密器的小扇区读取。按每个已解锁卷分别计量、按需填充，多个卷的内存用量会累加；修改保存到本机，下次重新解锁或重新打开镜像生效，不中断当前预览。CLI 明文容量另行配置，驱逐时清零。原生库和解码器的额外内存不计入此上限。读取优化与基准方法见 [读取性能记录](docs/read-performance.md)。
- C 库通过 `libbfio` 回调串接；同一会话的句柄只能在创建线程使用。
- 桌面适配层使用一个 Rust 工作线程、8 个请求上限的共享队列、独立镜像上下文、会话编号校验和分块取消；Flutter 在各镜像的辅助 isolate 中调用 FFI，取消按镜像上下文隔离。
- 所有镜像句柄和回调均只读。导出不覆盖现有文件。

## Windows 直接运行

本地构建产物位于 `artifacts/windows-x64/`。保持 `vhdx.exe` 和旁边的 `native/` 目录在一起。目标机器需要 x64 Microsoft Visual C++ 运行库（包含 `VCRUNTIME140.dll`）；当前未捆绑运行库安装器。从 PowerShell 运行：

```powershell
cd D:\works\vhdx\artifacts\windows-x64
.\vhdx.exe doctor
.\vhdx.exe inspect D:\works\vhdx\examples\basicvhdx.vhdx
.\vhdx.exe ls D:\works\vhdx\examples\basicvhdx.vhdx
.\vhdx.exe read D:\works\vhdx\examples\basicvhdx.vhdx /can.txt

$key = (Get-ChildItem D:\works\vhdx\examples -Filter 'BitLocker*.TXT' | Select-Object -First 1).FullName
.\vhdx.exe ls D:\works\vhdx\examples\bitlockervhdx.vhdx --recovery-key-file $key
.\vhdx.exe read D:\works\vhdx\examples\bitlockervhdx.vhdx /hello.txt --recovery-key-file $key
.\vhdx.exe read D:\works\vhdx\examples\bitlockervhdx.vhdx /hello.txt --password-file D:\works\vhdx\examples\password.txt
```

额外选项：

```powershell
# 选择分区；分区编号来自 inspect，不是盘符。
.\vhdx.exe ls X:\data.vhdx /documents --partition 1 --start 0 --limit 100
# 密码文件使用 UTF-8 或带 BOM 的 UTF-16；不修剪密码中的空格。
.\vhdx.exe ls X:\data.vhdx --password-file D:\private\password.txt
# 按字节读取，单次最多 4 MiB；read 向 stdout 输出原始字节。
.\vhdx.exe read X:\data.vhdx /movie.mp4 --offset 1048576 --length 65536
.\vhdx.exe hash X:\data.vhdx /documents/manual.pdf
.\vhdx.exe export X:\data.vhdx /documents/manual.pdf D:\export\manual.pdf
```

导出文件含解密后的明文，由用户管理。不要用旧版 PowerShell 的文本重定向保存 `read` 的二进制输出，请使用 `export`。不将密码或恢复密码本身放在命令行参数里。

恢复密钥文件支持 Windows 导出的 UTF-16/UTF-8 TXT，或仅含 `六位数字-...` 八组恢复密码的文件。程序不打印密钥。密钥只适用于它对应的卷；TPM-only 解锁不支持。

## 从源码构建

### Windows x64

依赖 Rust（MSVC 工具链）、Visual Studio C++ Build Tools、Windows SDK，以及 VS 的 CMake 组件。无需 Python、管理员权限或安装虚拟磁盘驱动。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-windows.ps1
# 下载缓存与 Cargo 缓存已齐备时：
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Offline
```

脚本下载固定版本的 C 库源码并验证 SHA-256，将上游 VC 项目中的源文件列表转换为 CMake，构建四个 DLL，再生成便携目录。`-Offline` 仅限制 Cargo；C 源码如缺失仍需下载。`-SkipNative` 可复用已有 DLL。

构建图形版：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-desktop-windows.ps1
# 原生库已构建后：
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-desktop-windows.ps1 -SkipNative
```

首次会把固定版本 Flutter SDK 下载到项目的 `.tools/`（下载约 1.8 GiB）；不修改系统 PATH。也可用 `-FlutterPath C:\your-flutter\bin\flutter.bat` 指定 SDK。项目固定版本及 SHA-256 见 `scripts/flutter-sdk.json`。Flutter 包锁定在 `app/pubspec.lock`。PDFium Windows 原生包固定在 `scripts/pdfium-windows.json`；构建脚本验证归档哈希及最终 DLL，并将随附许可证复制到便携包。视频原生包固定在 `scripts/media-windows.json`，构建时校验归档 SHA-256 和捆绑 DLL。首次构建时 Flutter 原生资产钩子也可能需要联网下载。

### Android ARM64（Windows 构建主机）

依赖 Windows Rust 工具链（`rustup target add aarch64-linux-android`）、Android SDK platform 36 / build-tools、NDK **27.3.13750724**、Android Studio JBR 21，以及 `C:\msys64` 的 MSYS2 shell/tar/sed。脚本使用项目内固定版本的 make、pkgconf、CMake 3.31.6；Gradle 8.14.3、AGP 8.13.0 和 Kotlin 2.2.20 固定在 Android 工程中。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-android.ps1
# 生成 UI 预览包：
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-android.ps1 -SkipNative -Preview
# C 库已构建后；独立 .uitest 包用于 integration_test 和 run-as：
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-android.ps1 -SkipNative -DebugBuild
```

输出 `artifacts/vhdx-reader-android-arm64-release.apk`（或 `-debug.apk`；`-Preview` 输出 `-ui-preview.apk`）。调试包使用独立应用 ID `org.vhdxreader.vhdx_reader.uitest`，隔离回归测试的私有文件和 Keystore，不覆盖日常使用的应用。脚本校验原生归档，将许可证放入 APK 的 `assets/licenses/`。`-Offline` 限制 Cargo/pub 和脚本管理的新增下载；Gradle、Flutter 原生资产钩子和未缓存的 libyal 源码仍可能联网。首次构建需要网络。原生库按 16 KiB LOAD 段对齐构建；最终 APK 仅包含 ARM64。当前使用开发签名，公开发布前需配置正式签名并完成 `THIRD_PARTY.md` 中的二进制依赖核对。

### macOS（在 Mac 上构建）

依赖完整 Xcode、Rust、Python 3.12+、CocoaPods、make 和 pkg-config。构建使用本机架构，首次下载固定 Flutter SDK 到 `.tools/flutter-macos`，pub 包缓存位于 `.tools/pub-cache-macos`。不复用 Windows SDK/构建缓存。

```bash
# 本次验证使用已安装的 Rust 1.96.1；只对当前命令指定工具链。
RUSTUP_TOOLCHAIN=1.96.1 bash scripts/build-macos.sh
# 已编译四个 C 库时：
RUSTUP_TOOLCHAIN=1.96.1 bash scripts/build-macos.sh --skip-native
# 开发调试包：
RUSTUP_TOOLCHAIN=1.96.1 bash scripts/build-macos.sh --skip-native --debug
```

产物为 `app/build/macos/Build/Products/Release/VHDX Reader.app` 和 `artifacts/vhdx-reader-macos-arm64-release.zip`。脚本固定 macOS 12.0 SDK 部署目标，显式选择 ARM64（避免新 Xcode 的 `arm64e` 主机标识误入 Flutter 构建），在应用签名前嵌入原生库，并检查依赖路径、CPU 架构、实际动态加载、签名与沙盒权限。Rust 1.96 在 macOS 27 上裁剪符号后产生的 LINKEDIT 对齐问题通过保留构建产物符号处理；不会通过关闭系统安全检查来加载损坏库。

Apple PDFium 与 libmpv 框架归档及校验值见 `scripts/apple-dependencies.json`。当前媒体插件使用 CocoaPods，Flutter 工程为此固定关闭 Swift Package Manager。当前包仍是本地开发产物，公开分发前需完成 `THIRD_PARTY.md` 中的许可证/源码核对以及正式签名、公证。

### Linux

依赖 Rust、Python 3.12+、GCC、make、pkg-config；使用带 configure 的官方源码归档，无需本机安装 autotools。

```bash
bash scripts/build-native.sh
export VHDX_NATIVE_DIR="$PWD/.native/install-linux/lib"
cargo build --release --locked
target/release/vhdx inspect examples/basicvhdx.vhdx
```

可用 `VHDX_BUILD_ROOT`、`VHDX_PREFIX` 指定构建/安装目录；WSL 建议把构建目录放在 Linux 文件系统以加快编译。若 WSL 无法下载而 Windows 可联网，可先运行 `scripts/download-native.ps1`。

程序优先使用 `--native-dir`，其次使用 `VHDX_NATIVE_DIR`，否则使用可执行文件旁的 `native/`。仅从可信目录加载本项目构建的四个原生库。

## 验证

```bash
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo fmt --all -- --check
# 原生合成镜像测试：跨 2 MiB 块、零块、随机读取、文件截断。
VHDX_NATIVE_DIR=/path/to/libs cargo test -p vhdx-core --test native -- --ignored
# 私有样本测试：解锁、分页、读取、导出、错误密码、只读校验。
VHDX_NATIVE_DIR=/path/to/libs VHDX_SAMPLE_DIR="$PWD/examples" \
  cargo test -p vhdx-cli --test samples -- --ignored
# 桌面协议：密码输入/密码文件/恢复密钥、隐藏文件过滤、锁定后旧会话失效。
VHDX_NATIVE_DIR=/path/to/libs VHDX_SAMPLE_DIR="$PWD/examples" \
  cargo test -p vhdx-app --test desktop -- --ignored
```

Flutter 检查（Windows PowerShell，原生库已构建）：

```powershell
$env:PUB_CACHE = "$PWD\.tools\pub-cache"
$env:VHDX_SAMPLE_DIR = "$PWD\examples"
cd app
..\.tools\flutter\bin\flutter.bat analyze
..\.tools\flutter\bin\flutter.bat test
..\.tools\flutter\bin\flutter.bat test integration_test\native_test.dart -d windows
```

PDF 测试另用自生成镜像，不修改 `examples`。在安装了 `mkntfs`、`ntfscp` 的 Linux/WSL 中运行：

```bash
python3 scripts/create-pdf-fixture.py
```

然后在 Windows PowerShell 中运行：

```powershell
$env:PUB_CACHE = "$PWD\.tools\pub-cache"
$env:VHDX_SAMPLE_DIR = "$PWD\examples"
$env:VHDX_PDF_FIXTURE = "$PWD\.native\pdf-fixture\pdf-preview.vhdx"
cd app
..\.tools\flutter\bin\flutter.bat test integration_test\pdf_test.dart -d windows
```

该测试包含双页渲染、16 MiB 空隙的按需读取、翻页/缩放/跨标签页码保留、损坏 PDF 及关闭后句柄失效。它证明当前读取路径可用，不能代替复杂扫描件、特殊字体、数千页文档和真实 SSD 的兼容性/性能验证。

视频集成测试使用自生成的 32 秒、640×360、H.264/AAC MP4（约 13 MiB），经 `scripts/create-media-fixture.py --video path/to/sample.mp4` 放入新建的 NTFS/VHDX。该脚本同样需要 Linux 的 `mkntfs`、`ntfscp`，输出目录已有测试卷时会拒绝覆盖。Windows 设置 `VHDX_MEDIA_FIXTURE` 为生成的 `.native/media-fixture/media-preview.vhdx` 后运行 `flutter test integration_test/media_test.dart -d windows`，其余环境变量同上。测试覆盖实际解码、进度条跳转、Range 请求、有限预读、无磁盘缓存、全屏、跨标签暂停/进度保留、关闭后撤销读取和损坏视频。BitLocker 样本单独验证 Range 字节读取；尚未将真实加密视频作为端到端播放样本。

Windows 下用 `$env:VHDX_NATIVE_DIR` 和 `$env:VHDX_SAMPLE_DIR` 设置相应路径，再运行同样的 Cargo 测试。私有样本测试以当前两个测试镜像和文件哈希为基准，不适用于任意替换后的 examples。

这两个样本已在 Windows x64 和 Linux x64 验证；测试前后整个镜像的 SHA-256 不变。Windows 原生挂载读取对照、真实 SSD 拔插、更多 Android 设备、4K 逻辑扇区实盘、大容量及各种 NTFS 压缩文件仍需验证。合成镜像测试不等于这些设备/格式已验收。

已在 Android 14 的 TECNO LH7n 上通过应用集成测试：普通卷读取、错误密码/密码文件解锁、独立多镜像、不可随机访问来源拒绝、PDF 渲染、H.264/AAC 视频播放/跳转及跨标签暂停。普通/BitLocker 文件哈希还在 Android 16 ARM64 设备的 CLI 上验证一致。release APK 还通过系统文件选择器打开 VHDX、播放视频并导出 MP4，导出 SHA-256 与原文件一致。Rust 12 项单元测试、Flutter 6 项测试、Windows 3 项协议回归测试及静态检查通过；这不等于真实 USB SSD 已完成验证。

Android 测试（Windows PowerShell，手机已允许 USB 调试/安装）：

```powershell
# 使用已交叉编译的 CLI 和 C 库，在手机私有临时目录验证样本哈希，结束后清理。
powershell -ExecutionPolicy Bypass -File scripts\test-android-core.ps1 -Device YOUR_SERIAL
# 先安装 debug APK（独立 .uitest 包），再把测试文件写入其私有目录；不会进入 APK。
powershell -ExecutionPolicy Bypass -File scripts\push-android-test-fixtures.ps1 -Device YOUR_SERIAL
$env:PUB_CACHE = "$PWD\.tools\pub-cache"
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
cd app
..\.tools\flutter\bin\flutter.bat test integration_test\android_test.dart -d YOUR_SERIAL
```

Android 构建脚本同时生成核心测试需要的 `target/android/aarch64-linux-android/release/vhdx`。应用集成测试还需要上面生成的 PDF、视频夹具；使用仅在 debug 编译、未导出的测试 ContentProvider 验证描述符通路，不代表真实 USB SSD 已验收。测试后可用 `adb -s YOUR_SERIAL shell run-as org.vhdxreader.vhdx_reader.uitest rm -rf files/fixtures` 清理本测试专用目录。

已在 Apple Silicon、macOS 27.0.1、Xcode 27.2、Rust 1.96.1 上验证：19 项 Rust 单元/真实镜像测试、6 项 Flutter 测试及 5 项沙盒应用集成测试全部通过。应用集成测试覆盖密码文件解锁、双镜像独立性、文本、PDF 按需渲染/翻页/缩放，以及 H.264/AAC 播放/跳转/切换暂停/读取撤销。

macOS 复验：先按上文构建 release 应用并准备私有 `examples`、PDF 和视频夹具，再运行：

```bash
VHDX_NATIVE_DIR="$PWD/.native/install-macos-arm64/lib" \
VHDX_SAMPLE_DIR="$PWD/examples" RUSTUP_TOOLCHAIN=1.96.1 \
  cargo test --workspace --locked -- --include-ignored
bash scripts/test-macos.sh
```

界面测试启动真实沙盒应用，将夹具临时放在它的容器目录中，沿用随应用打包的原生库；结束后清理该测试目录。示例镜像和凭据不进入 `.app`/ZIP。它不替代真实外置 SSD、拔插及不同 macOS 版本的兼容性测试。

## 首版边界

- 只读；不创建/修改镜像，不修复卷，不挂载成系统盘。
- 拒绝父盘依赖、有效未重放日志、任一损坏 VHDX 头、区域表不一致，以及损坏的主 GPT。暂不从备份表自动恢复。
- 首版不处理 MBR 扩展分区、无分区表的卷、exFAT/ReFS 等内部文件系统。
- 不跟随 NTFS reparse points，不解密 EFS；WOF 压缩文件若带 reparse 属性也会被当前策略拒绝。C 库声明支持的压缩格式仍需增加实测样本。
- CLI 显示 NTFS 系统项；Flutter 界面默认隐藏隐藏/系统文件及 `$` 开头的项。
- 核心调用是同步、线程隔离的；取消只在调用/数据块之间检查，不承诺中断正在执行的 C 函数。SSD 拔插检测和重连恢复尚待实机验证；读取错误可能关闭当前会话。
- Flutter/Dart 字符串由垃圾回收管理，清空输入框不等同于保证内存中所有密码副本被物理擦除。Rust 尽量对持有的凭据和缓存执行清零。
- 读取期间要求镜像不被外部修改。Windows 文件共享标志拒绝同时写入；Linux 当前未实现外部修改监控。
- 原生依赖是 alpha/experimental，尚未经过损坏文件的完整模糊测试，不应视为生产级解析器。

## 项目结构

```text
crates/vhdx-core/     随机读取、缓存、VHDX 预检查、分区、C FFI、文件接口
crates/vhdx-cli/      命令行与真实样本集成测试
crates/vhdx-app/      跨平台 C ABI、Rust 工作线程、会话协议
app/                 Flutter Windows / Android 界面、控件及原生集成测试
scripts/             固定版本下载、校验、跨平台构建
docs/                实现记录与后续里程碑
examples/            本机私有样本及凭据，禁止提交
.native/             下载、原生源码和构建缓存，禁止提交
artifacts/           本机便携产物，禁止提交
.tools/              项目本地 Flutter SDK 和包缓存，禁止提交
```

自有代码采用 MIT；第三方库保留其原有许可证，见 [THIRD_PARTY.md](THIRD_PARTY.md)。镜像、恢复密钥、密码、导出内容均不属于可分享的源码。当前工作区未初始化 Git，`.gitignore` 已准备好。

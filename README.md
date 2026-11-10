# VHDX Reader

VHDX Reader 是一款 VHDX 镜像只读浏览器，方便在 Mac、iPhone/iPad 和 Android 设备上访问来自 Windows 的虚拟磁盘。无需挂载成系统磁盘，即可读取本机或外置 SSD 上的镜像、打开 NTFS 分区、解锁 BitLocker、预览文件并导出内容。

核心使用 Rust，界面使用 Flutter，同时提供 Windows 图形版和命令行工具。本文以 Mac 上的构建与打包为主。

## 主要功能

- **镜像浏览**：读取独立固定/动态 VHDX，识别 GPT 和主 MBR 分区；支持同时打开多个镜像、目录分页、列表/网格展示和排序。
- **BitLocker 解锁**：支持密码、密码文件和恢复密钥；可将凭据保存在设备安全存储中，再次使用时通过系统身份验证。
- **文件预览**：内嵌查看文本、图片和 PDF，支持 PDF 翻页与缩放；视频支持播放、跳转、倍速、缩放及手势操作。
- **缩略图与缓存**：按需生成图片/视频缩略图，可调整文件内存缓存、磁盘缓存和播放器缓冲。
- **文件导出**：导出到新文件，不覆盖已有文件；命令行还支持镜像检查、按偏移读取和 SHA-256 校验。
- **只读访问**：不修改源镜像，锁定或关闭镜像后撤销对应读取会话。

### 使用方式

1. 打开应用，选择“添加镜像”，选取本机或外置存储中的 `.vhdx` 文件。
2. 进入 NTFS 分区；若为 BitLocker 分区，输入密码或导入密码文件、恢复密钥。
3. 浏览目录，点击文件预览，或将文件导出到指定位置。多个镜像可从侧栏切换。
4. 使用完毕后锁定分区或关闭镜像。桌面关闭窗口会隐藏到托盘/菜单栏，选择“退出应用”才会退出。

Mac 上解压应用包后打开 `VHDX Reader.app`。移动端通过系统文件选择器访问存储，外置 SSD 必须能被系统识别，文件来源须支持随机读取。

### 支持范围

- 当前仅支持 VHDX 内的 NTFS，不支持差分盘、MBR 扩展分区、exFAT/ReFS、EFS 或 TPM-only 解锁；不提供镜像写入、修复和系统挂载。
- 文本、图片预览有大小限制；视频已验证 MP4 / H.264 + AAC，其他编码取决于解码器。独立音频界面尚未实现。
- 文件磁盘缓存默认关闭，BitLocker 缩略图磁盘缓存默认关闭；启用后会在本机保存明文内容。导出文件同样为明文。
- 读取期间请保持源镜像不被其他程序修改。真实外置 SSD 拔插、更多设备和特殊文件格式的兼容性仍需验证。

## Mac 构建环境

- **Xcode**：安装完整 Xcode；构建 iOS/iPadOS 时还需相应 SDK 和 ARM64 模拟器运行时。
- **Rust/Cargo**：脚本默认使用 `1.96.1`，可通过 `RUSTUP_TOOLCHAIN` 指定其他已验证的工具链。
- **构建工具**：Python 3.12+、CocoaPods、make、pkg-config、Perl。
- **Flutter**：使用脚本下载到 `.tools/flutter-macos/` 的固定版本 SDK，无需另行全局安装。

首次构建需要联网。脚本下载并校验 libbfio、libvhdi、libbde、libfsntfs、OpenSSL，以及 PDFium 和媒体解码依赖。OpenSSL 静态链接，无需在运行设备另行安装。

依赖版本和校验值记录在 `scripts/` 下的 JSON 清单中，Rust 和 Flutter 包分别由 `Cargo.lock`、`app/pubspec.lock` 锁定。下载及原生构建缓存放在 `.native/`，Flutter SDK 和包缓存放在 `.tools/`。

## 在 Mac 上编译与打包

以下命令均从仓库根目录执行，以 Apple Silicon Mac 为例。应用与原生库须配套构建、完整打包。

### macOS

在 Mac 上执行，脚本会自动准备 Flutter 并生成应用和 ZIP：

```bash
rustup toolchain install 1.96.1
bash scripts/build-macos.sh
```

Apple Silicon 默认产物为 `app/build/macos/Build/Products/Release/VHDX Reader.app` 和 `artifacts/vhdx-reader-macos-arm64-release.zip`，部署目标为 macOS 12.0。可添加 `--skip-native` 复用原生库，或添加 `--debug` 构建调试包。

当前使用本地 ad-hoc 签名，公开分发需另行完成正式签名和公证。

### iOS / iPadOS

在 Mac 上执行，先准备项目 Flutter SDK，再构建设备和模拟器包：

```bash
rustup toolchain install 1.96.1
bash scripts/install-flutter-macos.sh
bash scripts/build-ios.sh
```

部署目标为 iOS 15.0，输出：

- `artifacts/vhdx-reader-ios-simulator-arm64.zip`：ARM64 模拟器包。
- `artifacts/vhdx-reader-ios-device-arm64-unsigned.zip`：ARM64 未签名真机包。

真机安装需在 `app/ios/Runner.xcworkspace` 中配置 Signing Team 并签名。原生库已构建时，可添加 `--skip-native`。

### 输出目录与检查

产物默认放在 `artifacts/`，可通过 `VHDX_ARTIFACT_DIR` 指定输出目录，例如：

```bash
VHDX_ARTIFACT_DIR="$PWD/artifacts/macos" bash scripts/build-macos.sh
```

基础源码检查：

```bash
cargo +1.96.1 test --workspace --locked
cargo +1.96.1 clippy --workspace --all-targets --locked -- -D warnings
cargo +1.96.1 fmt --all -- --check
```

Flutter 检查使用与构建脚本相同的 SDK 和包缓存：

```bash
export PUB_CACHE="$PWD/.tools/pub-cache-macos"
cd app
../.tools/flutter-macos/bin/flutter analyze
../.tools/flutter-macos/bin/flutter test
```

原生集成测试另需构建库和测试样本，相关脚本位于 `scripts/`，测试位于各 crate 的 `tests/` 和 `app/integration_test/`。

实现细节见 [实现记录](docs/implementation.md)、[读取性能记录](docs/read-performance.md) 和 [凭据存储说明](docs/credential-vault.md)。自有代码采用 MIT，第三方依赖说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

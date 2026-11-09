# Third-party components

本项目自有代码采用 MIT，不改变任何依赖的许可。磁盘库版本及归档 SHA-256 固定在 `scripts/native-sources.json`，PDFium 则在 `scripts/pdfium-windows.json`；Rust 依赖由 `Cargo.lock` 固定。

| Native library | Pinned release | Upstream license / status |
| --- | --- | --- |
| [libbfio](https://github.com/libyal/libbfio) | 20260623 | LGPL-3.0-or-later / alpha |
| [libvhdi](https://github.com/libyal/libvhdi) | 20260901 | LGPL-3.0-or-later / alpha |
| [libbde](https://github.com/libyal/libbde) | 20260916 | LGPL-3.0-or-later / alpha |
| [libfsntfs](https://github.com/libyal/libfsntfs) | 20260827 | LGPL-3.0-or-later / experimental |

Windows 从 0.6.19 起将 OpenSSL 3.5.9 的静态 libcrypto 链接到 libbde，使用上游 EVP 无填充接口及 CPU 指令分派；无需安装额外的 OpenSSL DLL。官方归档与 SHA-256 固定在 `scripts/openssl-source.json`，构建入口为 `scripts/build-openssl-windows.ps1`，采用 Apache-2.0 许可证，原始 LICENSE.txt 和 AUTHORS.md 随包保存在 `licenses/openssl/`。`licenses/native-build.json` 记录实际后端；构建时可通过 `-NativeCryptoBackend builtin` 使用原后端作对照。本次没有切换 Android/Apple 的解密后端。

这些发行归档内含其他 libyal 支持库及各自的版权声明。Windows 脚本将它们编译进相应 DLL，保留原始源码，不对上游实现打补丁；`libbfio` 以独立 DLL 供其他库使用。Linux 使用上游 configure/make。

便携目录复制各库的 COPYING* 和 AUTHORS。分享二进制前，还需要按所用许可证提供相应源码、构建脚本和通知；仅附许可证或上游网址不等同于已经完成所有发布义务。保留 `.native/downloads` 中的确切原始归档用于准备源码包，不把其中的构建缓存、测试镜像或密钥混入公开源码。

桌面版使用 Flutter SDK 3.47.9（BSD-3-Clause）、`ffi`（BSD-3-Clause）、`file_selector` 及其 Windows 实现（BSD-3-Clause）；实际包版本由 `app/pubspec.lock` 固定，Flutter 将依赖通知编入应用资源。本项目没有修改这些依赖。

本阶段采用手写 C ABI + `dart:ffi` 桥接，还未引入原计划的 `flutter_rust_bridge` 代码生成器。磁盘核心、工作线程和 UI 协议彼此独立，后续可以替换桥接实现。已引入 `pdfrx` 2.11.0、`pdfrx_engine` 0.9.0、`pdfium_dart` / `pdfium_flutter` 0.4.1（MIT）。Windows PDFium 使用 bblanchon/pdfium-binaries 的 chromium/8125 发行包，归档 SHA-256 已与 GitHub release asset digest 对照。PDFium 采用 BSD 风格许可，其 FreeType、ICU、JPEG 等依赖各有许可证；便携包 `licenses/pdfium/` 保留归档随附的 LICENSE、licenses、VERSION 和构建参数。当前二进制关闭 V8 和 XFA，未修改上游实现。

视频使用 `media_kit` 1.2.6、`media_kit_video` 2.0.1、`media_kit_libs_windows_video` 1.0.11（Dart/插件包装层 MIT）。原生二进制不属于这些 MIT 声明的覆盖范围。固定归档见 `scripts/media-windows.json`：libmpv 2023-09-24 / git-652a1dd，以及 ANGLE v1.0.1。SHA-256 为下载归档的本地固定值，下载时另外核对了包装包内的 MD5；不声称已取得独立上游 SHA-256 签名。

libmpv 的 LGPL/GPL 文本和 Copyright 来自对应 mpv 提交，保存在 `third_party/media/` 并随便携包复制。构建仓库为 https://github.com/media-kit/libmpv-win32-video-build 和 https://github.com/media-kit/libmpv-win32-video-cmake；ANGLE 归档来自 https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES 。这些预编译归档未随附完整的传递依赖通知与对应源码清单；本地开发包不应视为已完成公开二进制发布审核。公开发布前仍需核对 libmpv 内含 FFmpeg/编码库、ANGLE/SwiftShader/Vulkan 等的具体构建配置、版本、许可证、通知和源码义务，并更新较旧的原生发行包。

生成测试视频所用的 FFmpeg 命令行工具仅放在本地 `.tools/`，不捆绑到应用。测试镜像和视频不进入便携包。许可证信息以固定版本自带文件为准。

Android ARM64 使用相同的 libyal 源码，NDK 27.3.13750724 / configure 构建独立 `.so`；禁用外部 pthread/OpenSSL 链接，使用随附的加密实现，并去掉构建主机 RUNPATH。PDFium Android 同为 chromium/8125，固定归档哈希见 `scripts/prepare-pdfium-android.ps1`，许可证和构建参数随 APK 保存。Android Flutter 包的通知由 Flutter 纳入资产。

Android 视频包装层 `media_kit_libs_android_video` 1.3.8 为 MIT，使用 `media-kit/libmpv-android-video-build` **v1.1.7** 原生归档，固定 SHA-256 / 包内 MD5 见 `scripts/media-android.json`。APK 只打包 ARM64。与 Windows 原生媒体包一样，包装层 MIT 不覆盖 libmpv/FFmpeg 等传递依赖；原生归档缺少完整对应源码与通知，公开二进制发布前仍需核对该版本的构建配置及许可义务。当前 APK 为本地开发测试产物。

macOS 使用相同固定版本的 libyal 源码，构建独立 dylib，通过 `@loader_path` 加载同包的 libbfio。Flutter macOS SDK 固定为 3.47.9，原始归档哈希来自官方发布索引，见 `scripts/flutter-sdk-macos.json`。macOS 使用 CocoaPods 集成当前媒体依赖。

Apple PDFium 使用 `pdfium_flutter` 0.4.1 指定的 `espresso3389/pdfium-xcframework` v158.0.8125.0-20261029-150241。macOS 视频包装层为 `media_kit_libs_macos_video` 1.1.4（MIT），原生包为 `media-kit/libmpv-darwin-build` v0.6.0。归档 URL 和与上游插件逐项核对的 SHA-256 固定在 `scripts/apple-dependencies.json`。媒体归档包含 Mpv、FFmpeg、Ass、Dav1d、FreeType 等独立框架；包装层 MIT 不覆盖这些传递依赖。当前 Apple 原生归档未随附完整许可/对应源码清单，开发测试包仅附已有通知，公开二进制发布前仍需补全核对与源码提供。macOS 当前使用 ad-hoc 开发签名，尚未进行 Developer ID 签名和公证。


iOS/iPadOS 使用同一份 libyal 源码，分别为设备 ARM64 和模拟器 ARM64 编译，并将五个独立动态库包装为 XCFramework，由 CocoaPods 嵌入应用。Apple PDFium 共用上述固定发行包；视频包装层为 `media_kit_libs_ios_video` 1.1.4，原生 iOS 归档及 SHA-256 见 `scripts/apple-dependencies.json` 的 `media_ios`。该归档的模拟器切片禁用了全部音频输出驱动，设备切片启用了 AudioUnit；模拟器使用 null 音频输出并在界面说明，设备版本正常申请 AVAudioSession。开发包不包含测试镜像或密码。上述传递依赖通知与源码清单的发布核对同样适用于 iOS。

设备安全存储直接使用 Apple Security.framework / CoreFoundation、Windows DPAPI 和 Android Keystore，不使用自定义加密算法。Android Rust/JVM 桥接新增 jni 0.21.1（MIT OR Apache-2.0），具体传递依赖由 Cargo.lock 固定；随 Android 包附带 third_party/rust 中的新增桥接依赖许可证。

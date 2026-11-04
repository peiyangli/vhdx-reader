# Implementation decisions

## Current milestone

Windows x64, Android ARM64 and macOS ARM64 Flutter browser, plus Windows/Linux CLI. Pure read-only local access to an independent VHDX stored on external SSD. The initial UI is integrated with the real reader.

The data path is `LocalFile -> libvhdi -> partition Slice -> optional libbde -> CachedReader -> libfsntfs -> File`. Each native layer consumes a `libbfio` callback handle. File access does not require a mounted disk, administrator rights, whole-image conversion, or plaintext intermediate volumes.

The Flutter shell now uses a small versioned C ABI (version 6) (`crates/vhdx-app/include/vhdx_app.h`) through `dart:ffi`. This is a deliberate first integration instead of introducing flutter_rust_bridge code generation. An auxiliary Dart isolate makes blocking ABI calls; a dedicated Rust worker owns a map of independent native contexts. Every image tab has its own context ID, native image, unlocked volume, cache and generation. The UI retains tab widgets and their browsing/preview state; closing one disposes only that context. Reopening the same normalized path focuses the existing tab. The shared eight-slot queue rejects overflow; native execution remains serialized. Cancellation targets the active operation only if its context ID matches. Lock/close increment that context’s session generation and stale requests are rejected. Typed secrets and imported credential files use the same credential parser as the CLI; only paths, not password values, are passed as process arguments.

The UI implements image/partition selection, password and recovery unlock, paginated directory browsing, hiding system entries, loaded-entry filtering, bounded text/image previews, random-access PDF viewing, export and cancellation. Plaintext preview bytes use Base64 over this small JSON ABI. PDF adds file_open/file_read/file_close tokens, a serialized 64 KiB page reader and a 1 MiB Dart LRU cache. PdfDocumentRefCustom disables whole-file caching and reads through the same bounded ABI; no plaintext PDF is staged on disk. Viewer state is retained across image tabs and hidden viewers pause rendering. The 32 MiB render cache target is separate from the Rust/Dart byte caches and is not a process memory limit. This path is for bounded preview requests; video streaming uses the separate binary adapter described below.

The media_open/media_close/media_status commands expose a single-file loopback HTTP stream protected by a random 256-bit URL token. Each stream accepts at most four clients, bounded headers, exact Host/path checks and GET/HEAD only; Origin and request bodies are rejected. It supports single byte ranges (206/416), suffix ranges and full responses. Socket threads ask the native worker for at most 256 KiB per read using the same bounded queue, then write with backpressure. Lock/close invalidates the generation and shuts down sockets; a disconnected seek stops further work after the current chunk. No media payload traverses Dart JSON. The player uses an 8 MiB forward and 2 MiB backward packet cache, not a total process limit. Disk caching is disabled and checked before loading; loadfile avoids media_kit open’s temporary playlist. Automatic external references/subtitles/audio files are disabled. Switching tabs pauses playback, returning preserves position without automatically resuming.

## Android storage and packaging

The Kotlin activity uses ACTION_OPEN_DOCUMENT for images/credentials and ACTION_CREATE_DOCUMENT for exports. Only descriptor numbers and metadata cross the method channel; no image payload crosses Kotlin. Saved credentials use a separate JNI-only byte-array bridge to Android Keystore; they never cross the Flutter method channel. Read descriptors are checked for seekability. Rust duplicates each descriptor with F_DUPFD_CLOEXEC before creating a LocalFile, verifies regular-file metadata and probes random access. Offsets remain 64-bit; a sparse-file regression reads beyond 4 GiB and detects truncation. Dart releases the original descriptor after the ABI reply. Export writes only to a newly created document, with best-effort removal after failure/cancellation.

Engine teardown/restart can skip Dart dispose. Kotlin captures a context-ID watermark, asks the Rust worker to retire older contexts (closing file handles and loopback streams), then releases its remaining descriptors. The worker rejects queued late commands for retired contexts; newer engine contexts remain separate. Native libraries load only from the APK's extracted nativeLibraryDir. Sources are not staged into app cache, and backup is disabled.

The first package is ARM64 only, minSdk 24 / targetSdk 36. NDK 27.3 plus explicit 16 KiB linker alignment is used for Rust, libyal and JNI dependencies; the media/PDF native packages are pinned separately. Native libraries are extracted on installation for absolute-path loading. Network security allows cleartext only for loopback media; storage access uses URI grants rather than broad storage permission. Debug fixtures/provider are excluded from release builds. The release build currently uses a development signing key.

## macOS packaging

The sandboxed Cocoa host uses the existing file_selector panels. User-selected read/write access permits picking source files and creating exports; the Rust image handles remain read-only. Both incoming and outgoing network entitlements are present for the loopback media adapter. The five reader dylibs live under Contents/Frameworks/vhdx, resolved relative to the executable by Dart and Rust. Staged libraries use @loader_path sibling references, reject unbundled host dependencies, and are signed before Xcode signs the containing app.

The builder defaults to the native host CPU with an explicit NativeBuild.xcconfig, rather than NATIVE_ARCH_ACTUAL (arm64e on the tested new Mac). It uses macOS 12.0 as the deployment target and ad-hoc development signatures. Rust 1.96's stripping step produced dylibs with a misaligned LINKEDIT string pool rejected by macOS 27; the Mac builder keeps release and host build-override symbols intact, and the package verifier actually dlopens every reader dylib. Pinned CocoaPods media/PDF binaries are verified against the checksums in their upstream packages. iOS/iPadOS require a separate host, scoped file-lifetime management and native linkage; no mobile Apple implementation is claimed by this macOS build.

## Ownership and FFI

- `Runtime` owns loaded library modules. Objects keep their respective module alive; callback handles keep the source layer alive. NTFS entries retain the volume.
- Each callback clone owns a separate cursor and shares its source. Free callbacks consume their Rust `Box` exactly once. C callbacks catch Rust unwinding; source failures propagate as read errors rather than zero-filled success.
- `Rc` makes sessions and native handles neither Send nor Sync. Flutter integration must construct and use them inside one dedicated worker. Never mark the native wrappers `Send`/`Sync` merely to satisfy a bridge generator.
- File and volume offsets remain 64-bit. The C boundary rejects offsets exceeding signed 64-bit and bounds each request.
- Session `File` objects own their volume lifetime, so they remain valid after the outer image/volume facade is dropped. The desktop worker owns preview file handles in a per-context map. File IDs never repeat within that context, and unlock/lock/close discard all of its preview handles. Ordinary read/export still scope file handles to the request.

## Storage and validation

- Preflight checks both VHDX header CRC32C values, active log identifier and both region tables. The pinned libvhdi header reader does not enforce CRC32C; degraded copies are conservatively rejected instead of relying on its sequence selection.
- GPT header and entry-array CRC32 are checked, as are partition bounds and overlaps. The implementation rejects malformed primary tables; recovery from backup GPT is not implemented.
- Source files open read-only. On Windows only FILE_SHARE_READ is allowed, preventing concurrent writers/deletion. Unix currently relies on an immutable-image usage contract.
- Rust caches decrypted 64 KiB pages with a bounded page count. Evicted buffers are zeroized. This does not bound the entire process, prevent OS paging, or guarantee erasure of copies held inside native libraries.

## Remaining milestones

1. Independent Windows native filesystem comparison (requires an elevated, read-only attachment), additional 4Kn/fixed/compressed/sparse/Unicode/deep-directory fixtures, fuzzing and measured benchmarks.
2. Extend the implemented bounded FIFO worker with preview priorities, progress events, source-removal detection and reconnection. Cancellation is cooperative between native calls/chunks.
3. Extend the implemented PDF viewer with search, outlines and independent PDF passwords; test complex fonts/scanned documents. Add GBK/GB18030 text decoding and image improvements. The C ABI remains separate from domain logic.
4. Broaden video validation beyond the generated 32-second H.264/AAC fixture: HEVC/4K/HDR, real external SSD throughput and unplug behavior, encrypted video fixtures, audio-only UI, subtitles and track selection. Update/audit the old upstream native playback binaries before a public release.
5. Android external SSD provider compatibility, unplug/reconnect behavior, lifecycle stress tests and broader device/API coverage. The ARM64 build and SAF descriptor bridge are implemented.
6. Broader macOS device/version and external-SSD verification; iOS/iPadOS external-SSD verification, hardware media/audio validation and optional system file-provider integration. The iOS scoped descriptor bridge and XCFramework builds are implemented; development signing, installation and launch have been validated on an iPhone SE (3rd generation).

No speed or broad media-format compatibility claim is established by the tiny examples. Current tests establish the implemented reading path and several error boundaries.


## iOS/iPadOS 移植与验证

- `DocumentStorage.swift` 通过系统 document picker 返回不可伪造的会话内 URI；实际 URL 仅存于原生侧。只读 FD 通过平台通道交给 Rust 并复制，Flutter 不搬运整个镜像内容。
- Swift 的 security-scoped 访问和文件协调在后台队列持有；Dart 的 `NativeBackend` 在 `open` 后保留镜像 lease，在成功 `close`/`dispose` 后释放。密码/导出 lease 只持续对应请求。导出以 `O_EXCL` 创建，失败清理检查所创建文件的设备号和 inode。
- 引擎销毁时先按上下文编号边界退休 Rust 会话，完成后释放描述符与授权；迟到请求不能重新创建旧上下文。退休超时保留权限，避免仍在运行的读取失去授权。
- `build-native-ios.sh` 交叉构建两套 libyal 共享库；`package-native-ios.py` 包装为单独 XCFramework，保留原有库之间的隔离及 LGPL 动态链接方式。`VhdxNative.podspec` 负责嵌入签名。`verify-ios.py` 检查平台、架构、依赖闭包和样本泄漏。
- 新增 2 个 XCTest 文件访问场景和 iOS Flutter 整合入口；仅 Debug 模拟器编译测试文档注册方法，Release 和物理设备不包含该入口。测试数据仍由外部脚本注入，未添加为 Flutter assets。
- 已在 Apple Silicon Mac 完成设备 ARM64 Release 和模拟器 ARM64 Debug 编译；iPhone、iPad 各通过 6 项整合测试和 2 项 XCTest 文件访问测试。截图验证了文本和两页 PDF 预览以及视频跳转后的帧。Flutter 静态检查与 6 项本地测试通过，并补充了横屏文件预览回归。
- 上游 libmpv 模拟器切片的 `audiounit/coreaudio` 均禁用，设备切片 `audiounit` 启用。仅模拟器使用 `ao=null`，明确显示无声音提示；真机管理 AVAudioSession 的引用计数，播放器释放后归还会话。真机声音仍需实际设备验证。
- XCTest 曾在未正确签名/构建目录不一致时于启动阶段报告找不到 `Ass.framework`；测试脚本现使用统一 BUILD_DIR 和 ad-hoc 签名。包验证扩展到所有嵌入框架和应用 loader 的依赖闭包，模拟器包额外检查 deep/strict 签名。
- 测试主机不能固定记录 iOS 数据容器路径：Flutter 安装测试应用会迁移容器，退出时会卸载应用。测试运行时获取目录，并在 tearDownAll 与主机脚本握手后收集截图；样本和密码不进入应用包。
- 2026-11-04：沿用用户在 Xcode 配置的 Personal Team 完成 Release 签名，并通过完整框架依赖和 deep/strict 签名检查。已安装到 iOS 27.2 的 iPhone SE（第 3 代）；用户完成开发者信任后启动成功，截图和进程检查正常。普通/BitLocker/PDF/视频镜像与密码文件另行复制到应用 Documents/vhdx-validation。当前开发描述文件到期时间为 2026-11-11 07:54 UTC；IPA 仅供已登记设备使用。真机文件选择、解锁、媒体声音和 USB SSD 仍待交互验收，不能用启动成功替代功能验收。

## BitLocker 凭据库（v0.6）

见 [credential-vault.md](credential-vault.md)。ABI 6 的保存、读取和解锁都在 Rust 工作线程中执行，Flutter 仅接收非秘密元数据。系统适配分别为 Apple Security.framework、Windows DPAPI 和 Android Keystore/JNI；Linux 禁用记住，无明文回退。

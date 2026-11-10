# Implementation decisions

## 新会话交接：HTTP 与缩略图优化（2026-11-09，两项代码与回归完成）

原交接要求按以下顺序处理。2026-11-09 已完成 HTTP/native 对照原型及 Windows 播放实测，以及缩略图预算、取消、队列和重试修复。按用户最后确认，0.6.21+28 的普通播放与视频缩略图均默认使用原生回调，HTTP 仅保留为显式对照选项。已完成各平台重新打包及 Windows/Android 真机/Mac/iPhone 与 iPad 模拟器补测，产物在 `artifacts/0.6.21/`；真实数 GB 视频的具体慢因仍未复现。

基线：0.6.20+27；平台 OpenSSL EVP 切换提交 `adfc133`，测试修正提交 `9e8c208`。各平台包、校验和和实际验证范围在 `artifacts/0.6.20/manifest.json`；目录按版本平铺，不增加多层 artifacts 子目录。

### 本轮执行结果（2026-11-09）

- 新增 `crates/vhdx-app/src/native_media.rs` 与 `app/lib/native_media.dart`，通过 `mpv_stream_cb_add_ro` 接入只读 `vhdx://` 回调。Rust 原生句柄仍由同一工作线程独占，不添加 Send/Sync；每次最多 256 KiB，复制到 mpv 缓冲区后清零，不经过 HTTP、Dart JSON 或明文临时文件。
- `media_open.transport` 默认 `http`，可指定 `native`；Rust 旧 `media_open` API 缺省 HTTP 保持兼容，Flutter 普通播放与缩略图均显式默认选择 native，`--dart-define=VHDX_MEDIA_TRANSPORT=http` 可用于诊断对照。ABI 7 新增可选回调导出，运行时核对 libmpv API；Windows 实际为 2.1。各已发布平台包的符号已核对，首轮运行对照仅 Windows；新默认路径已补测 Windows、Android 真机、Mac 及 iPhone/iPad 模拟器。
- 注册表用随机 token 和弱引用，独立 cookie 持有 Arc 状态，取消只写原子标志；工作线程关闭/锁卷/异常时撤销，cookie 等待 mpv close 释放。特别处理 media_kit dispose 后延迟 5 秒销毁 mpv 的生命周期。等待读取可取消，但不能中断单次原生阻塞 I/O。
- 7 轮传输基准、36 次 Windows 播放对照已完成。纯传输明显减少等待；实际 AVI 首帧中位数 382.536 → 295.150 ms，普通 MP4 seek 32.673 → 16.819 ms；部分格式首帧、CPU 没有收益，首轮因此保留 HTTP 默认；后按用户明确要求将 0.6.21 默认改为 native 并补测。详细方法、数据和限制见 [read-performance.md](read-performance.md#http-与-libmpv-原生回调对照2026-11-09)，原始结果在 `.native/http-native/`。
- 验证：Windows 37 项 Rust 测试、Linux 回调/存储故障回归、Flutter analyze、102 项单元/界面测试、36 次播放对照及 5 项 native 播放回归通过。修复取消后 `media_close` 被 Dart 拦截的问题，清理请求可继续撤销流。
- 缩略图新增 `thumbnail_begin/cancel/finish` 元数据控制，以及 Rust 每任务 32 MiB 文件逻辑读取、64 MiB 镜像源读取预算和 8 秒截止时间；在读取前预留额度，打开阶段、重复偏移、多 Range、关闭后重新打开、HTTP/native 共用额度。正常播放没有这些限制。
- 打开之前登记取消；元数据控制绕过阻塞的 Dart 读取 isolate 与 Rust I/O 队列，迟到文件句柄仍关闭。超时任务释放生成槽位，至多保留 2 个尚未结束的生成/清理任务，避免无限堆积；缓存查询保持独立。无法解码、超时或超预算的图片/视频记录为不可用，停止自动重复读取；临时队列/设备/会话错误仍可重试。过期流会在后续打开时回收，避免关闭请求因队列满而遗漏后占满文件槽位。
- 可选诊断提供排队、打开、首帧事件、截图、关闭耗时，以及文件/镜像源累计字节、偏移/长度（每任务最多 256 条）；不记录媒体内容，默认不采集详细轨迹。用户明确不提供私密问题文件，按代码机制修复，并使用自行生成的 8 GiB 稀疏 MP4 验证，两路径均成功出图且后续普通视频正常完成。它不是数 GB 编码内容，不能据此断定用户文件的根因或加速倍率。
- 后续补充：失败标记按镜像身份/源版本、分区、路径、大小与修改时间复用，跨 scope 重开仍生效；启用对应磁盘缓存时写入仅含 `unavailable: true` 的记录，应用重启后也跳过原文件读取/解码。BitLocker 默认仍只存内存，开启专属磁盘缓存后才持久化；关闭该开关会清除对应标记。文件元数据变化或清空缓存允许重新尝试，取消/锁卷/设备故障不持久标记为不可用。
- 缩略图轮次验证：Windows 44 / Linux 45 项 Rust 测试及两端 Clippy、Flutter analyze、111 项单元/界面测试、4 项 Windows 缩略图集成回归及 5 项普通播放回归通过。详细预算口径、结果、复现步骤和限制见 [read-performance.md](read-performance.md#缩略图读取预算取消与队列修复2026-11-09)。
- 后续重点是不同真实大视频格式/索引、移动端/Apple 与外置存储运行验证。单次原生阻塞 I/O 不能被强制中断，8 秒是停止继续工作和释放前端生成槽位的边界，不保证原生清理在 8 秒内完成。

### 0.6.21+28 打包交付

六个包平铺在 `artifacts/0.6.21/`，`manifest.json`、`SHA256SUMS` 与逐包 `.sha256` 已生成。包括 Windows x64、Android ARM64、macOS ARM64、iOS ARM64 未签名真机包、iOS ARM64 模拟器包及 Linux x64 CLI。普通播放和视频缩略图均默认 native，HTTP 只用于显式对照；旧 Rust 请求 API 缺省 HTTP 保持兼容，GUI 始终显式指定传输。Linux CLI 不涉及播放器传输。

本次补测：Windows 9 项集成、Android 真机 4 项通过/1 项跳过、Mac 7 项通过/1 项跳过；iPhone 与 iPad 模拟器各 8 项 Flutter 通过/1 项跳过、3 项 Swift 通过/1 项跳过。跳过项仅系统凭据交互/独立宿主缺少凭据夹具，不包含媒体用例。Windows/Mac 各 111 项单元/界面测试通过；Mac 46 项 Rust 回归通过，Windows 44/Linux 45 与 Clippy 沿用同一未改变 Rust 源码的本轮结果。Mac 首次测试遇到临时缓存目录删除早于失败标记写入的测试清理竞态，已等待缓存任务结束再删除，复测通过；不涉及生产代码变更。

Windows 文件与打包目录逐项一致，Android 验证 v2 签名、16 KiB ELF、Rust 输入/Gradle 合并/剥离输出与 APK 对应关系，Apple 验证框架依赖闭包、平台及签名。六包版本、归档完整性、许可证、私有测试文件排除和 SHA-256 均通过。Apple 取回后的哈希与构建主机一致。签名沿用开发方式：Android 开发签名、Mac ad-hoc；iOS 真机包需另行 Apple 签名，未进行本轮物理 iPhone/iPad 运行测试。

构建来自当前未提交工作区，基线 `adfc133`；打包源码快照和日志在 `.native/release-0.6.21/`。未自动提交代码或上传外部发布服务。

### 1. 先验证去掉视频本机 HTTP 中转的效果

- 当前路径：libmpv → 本机 HTTP → Rust 读取工作线程 → VHDX/BitLocker/NTFS。视频负载不经过 Dart JSON；Rust 通道转移缓冲区所有权，不代表逐块复制整份数据。HTTP 内部每块最多 256 KiB，不等于每块独立发起 HTTP 请求。
- 在保留 Flutter、media_kit/libmpv 和现有读取工作线程的前提下，验证 libmpv 自定义只读流回调（`mpv_stream_cb_add_ro`，open/read/seek/size/close）接入。项目已有 libmpv 头文件包含接口；各平台实际导出、ABI、播放器句柄接入和生命周期仍须核对。官方说明：https://github.com/mpv-player/mpv/blob/master/include/mpv/stream_cb.h 。
- 先做 HTTP 与原生回调可对照的原型，以同一批文件、相同缓存条件测首帧、seek、CPU、吞吐和读取量，再决定是否替换。没有测得收益前，不宣称加速比例。
- 原生句柄及缓存使用 Rc/RefCell，不能直接跨线程，也不能通过随意添加 Send/Sync 绕过所有权约束。第一步保留读取工作线程，只移除 HTTP/socket；是否重构线程归属另行评估。
- 覆盖关闭预览、切换文件、锁定卷、取消、存储断开及播放器销毁；保证回调与缓冲区存活期正确，无死锁/悬空访问。维持禁止明文媒体落盘的既有策略。
- 入口：`crates/vhdx-app/src/media.rs`，`crates/vhdx-app/src/lib.rs` 的 `MediaRead` / `read_media`，`app/lib/media_preview.dart`。已有基准见 `docs/read-performance.md` 与 `media_benchmark`。

### 2. 再处理整个缩略图链路，重点排查数 GB 视频变慢

用户反馈：进入视频列表目录时，几个 GB 的视频缩略图很久才显示，感觉读取了整个文件。尚未取得这个大文件的读取轨迹，不能把“整文件扫描”写成已证实根因。用户已明确这些是私密文件，当前不提供资源，授权从理论和代码机制上优化修改。旧的 `examples/bitlockervhdx.vhdx` 中的小视频及新生成的稀疏文件都不能替代该问题样本。

修复前确认的代码现状（保留作为问题基线；本轮实现见上方结果）：

- `app/lib/thumbnails.dart` 取第一张可解码帧，没有主动 seek 到视频中间；缓存键使用路径、大小、修改时间等元数据，不计算视频内容全文件哈希。
- 缩略图播放器已禁用普通预读及磁盘缓存，但打开时的格式/流信息/索引探测仍可能读取数据。读取尾部索引不等于从头扫到尾。
- 32 MiB 是 Dart 截图循环里检查的 HTTP 已发送字节数，属于事后软限制；不约束打开阶段全部读取，也不等于底层磁盘读取量。Rust 层尚无缩略图专用累计读取硬预算。
- 8 秒计时器发出协作取消，不能保证 8 秒内原生操作及清理结束。`MediaPreviewSource.open` 返回后才登记任务清理回调，打开期间存在取消覆盖缺口。
- 视频缩略图生成并发为 1，慢文件会拖住后面未缓存任务；失败重试可能放大等待。缓存查询已独立排队，应保留这点。

原处理方向（1–3 已实现并回归；第 4 项的大视频覆盖仍需后续扩展）：

1. 分别记录排队、打开、首帧、截图、关闭耗时；记录请求偏移/长度、累计返回字节、底层读取量及重试次数，区分随机探测、顺序扫描、重复读取和纯解码等待。
2. 将缩略图专用累计读取预算、截止时间和取消检查下沉至 Rust，覆盖打开到关闭全过程；多 HTTP 请求或重新打开不能轻易绕过预算。正常视频播放不套用缩略图预算。原生单次阻塞读的可中断边界要据实说明。
3. 慢文件超预算及时让出生成队列，先显示类型占位；避免连续自动重试拖住目录。保留缓存命中快速显示、BitLocker 缓存设置和锁定撤销语义。
4. 大文件样本覆盖常见 MP4/MKV、索引位置/缺失、不同编码和普通/BitLocker 卷；同一组样本对照 HTTP 与原生回调，不能假设移除 HTTP 会消除解复用器的不必要扫描。

补充：PDF 当前使用随机读取回调，不走 HTTP，但经过 JSON/Base64；这是独立优化点，不抢占上述两项优先顺序。


## Current milestone

Windows x64, Android ARM64 and macOS ARM64 Flutter browser, plus Windows/Linux CLI. Pure read-only local access to an independent VHDX stored on external SSD. The initial UI is integrated with the real reader.

The data path is `LocalFile -> libvhdi -> partition Slice -> optional libbde -> CachedReader -> libfsntfs -> File`. Each native layer consumes a `libbfio` callback handle. File access does not require a mounted disk, administrator rights, whole-image conversion, or plaintext intermediate volumes.

The Flutter shell now uses a small versioned C ABI (version 9) (`crates/vhdx-app/include/vhdx_app.h`) through `dart:ffi`. This is a deliberate first integration instead of introducing flutter_rust_bridge code generation. An auxiliary Dart isolate makes blocking ABI calls; a dedicated Rust worker owns a map of independent native contexts. Every image tab has its own context ID, native image, unlocked volume, cache and generation. The UI retains tab widgets and their browsing/preview state; closing one disposes only that context. Reopening the same normalized path focuses the existing tab. The shared eight-slot queue rejects overflow; native execution remains serialized. Cancellation targets the matching active operation and the context’s queued or running export. Exports yield after each 256 KiB native read; foreground requests have priority with an export turn after at most four foreground items. Up to four exports (one per context) hand one reusable buffer each to target writer threads for write/sync/close. Native image and filesystem handles remain on the reader thread. Lock/reunlock/dispose revoke exports, and engine retirement acknowledges only after affected targets have closed. See the PERF-01 section in [read-performance.md](read-performance.md). Lock/close increment that context’s session generation and stale requests are rejected. Typed secrets and imported credential files use the same credential parser as the CLI; only paths, not password values, are passed as process arguments.

The UI implements image/partition selection, password and recovery unlock, paginated directory browsing, hiding system entries, loaded-entry filtering, bounded text/image previews, random-access PDF viewing, export and cancellation. Plaintext preview bytes use Base64 over this small JSON ABI. PDF adds file_open/file_read/file_close tokens, a serialized 64 KiB page reader and a 1 MiB Dart LRU cache. PdfDocumentRefCustom disables whole-file caching and reads through the same bounded ABI; no whole PDF is staged on disk; the optional shared file disk cache can persist accessed plaintext pages. Viewer state is retained across image tabs and hidden viewers pause rendering. The 32 MiB render cache target is separate from the Rust/Dart byte caches and is not a process memory limit. This path is for bounded preview requests; video streaming uses the separate binary adapter described below.

The media_open/media_close/media_status commands expose a single-file loopback HTTP stream protected by a random 256-bit URL token. Each stream accepts at most four clients, bounded headers, exact Host/path checks and GET/HEAD only; Origin and request bodies are rejected. It supports single byte ranges (206/416), suffix ranges and full responses. Socket threads ask the native worker for at most 256 KiB per read using the same bounded queue, then write with backpressure. Lock/close invalidates the generation and shuts down sockets; a disconnected seek stops further work after the current chunk. No media payload traverses Dart JSON. By default, the player uses a 64 MiB forward and 2 MiB backward packet cache with up to 30 seconds of readahead, independently of the volume read-cache setting; these are not total process limits. Initial playback, seek restarts and underruns buffer up to 3 seconds before resuming (mpv may resume earlier at EOF or the byte limit). The settings page exposes forward capacity (8–256 MiB), readahead (5–120 seconds) and resume buffering (1/3/5 seconds); preferences are persisted under `cache.playback` and passed to each newly opened video without changing an active player. Thumbnail players retain their separate 1 MiB budget with readahead disabled. mpv disk caching is disabled and checked before loading (independent of the optional native file disk cache); loadfile avoids media_kit open’s temporary playlist. Automatic external references/subtitles/audio files are disabled. Switching tabs pauses playback, returning preserves position without automatically resuming.

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
- Rust caches decrypted pages with configurable page size and capacity (64 KiB pages by default). The optional shared plaintext disk cache has its own quota. Evicted buffers are zeroized. This does not bound the entire process, prevent OS paging, or guarantee erasure of copies held inside native libraries.

## Remaining milestones

1. Independent Windows native filesystem comparison (requires an elevated, read-only attachment), additional 4Kn/fixed/compressed/sparse/Unicode/deep-directory fixtures, fuzzing and measured benchmarks.
2. Extend the bounded worker with priorities among foreground previews, progress events, source-removal detection and reconnection; cooperative export scheduling is implemented. Cancellation is cooperative between native calls/chunks.
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


## Configurable volume cache layout (ABI 8)

Unlock JSON `cache` now accepts `plaintext_page_kib` (64, 128, 256, 512, 1024, 2048, 4096; default 64). `plaintext_mib` accepts powers of two from 16 through 16384. The native worker validates the whitelist and checked MiB-to-byte conversion before touching the existing volume; unsupported 32-bit budgets are rejected instead of wrapping. Defaults for omitted fields remain backward compatible. This layout required ABI 8; disk-cache controls below introduced ABI 9; the current frontend expects ABI 10 for binary preview reads.

The core keeps `unlock` and `unlock_with_caches` with their existing 64 KiB defaults, and adds `unlock_with_cache_layout` for explicit plaintext page sizing. Each unlocked volume owns a lazy LRU page cache under NTFS; page keys are offsets in that volume, shared across file and metadata reads. Ciphertext coalescing remains independently budgeted with 64 KiB pages. The frontend persists layout changes for the next unlock/open and displays maximum page count. Neither capacity selection nor opening a volume preallocates the full budget.


## Optional shared disk cache (ABI 9)

`disk_cache_configure` takes `cache_enabled` (master file-cache switch), `enabled` (disk only), an absolute app-owned `directory`, `max_gib` (1–128 powers of two), and `retention_days` (0/1/7/30, with 0 meaning no time expiry). `disk_cache_status` and `disk_cache_clear` are session-independent worker commands. A single `Rc<RefCell<DiskCache>>` is shared across image contexts; commands and reads are serialized on the existing native worker. The OS directory lock prevents competing processes from keeping inconsistent quota indexes. Configuration errors are not treated as source I/O errors and do not lock healthy volumes.

The read path is memory plaintext pages → disk plaintext pages → decrypted/source data. BitLocker credential validation and NTFS signature checks precede attaching the disk layer. Cache namespace includes the opened source path/URI, its metadata revision (or a unique per-open identity when unavailable), partition offsets, page size and page offset. It does not hash the whole image and cannot detect deliberately preserved source metadata. Blocks carry a format magic and SHA-256 payload checksum; partial or corrupt blocks are discarded and read from source. Writes use a temporary file and rename. Successful data reads remain successful if cache writes fail; source errors are never cached. Cache length counts block payload and headers, not filesystem allocation metadata.

The master control is shared by plaintext memory caches, ciphertext memory caches and disk readers, including existing volumes. Disabled memory readers drop their retained pages on their next read and bypass the cache; disk reads and writes are bypassed immediately. Player/decoder buffering and thumbnail caches remain separate. Toggling disk use or master use does not delete persistent blocks. Manual clear removes only managed files and reports deletion failures. Existing memory/player data is not cleared by the disk-only clear command.

Disk LRU index loads once per configured directory, uses an ordered access index for eviction, and persists last use in file timestamps. Expiry is checked at initialization/configuration/status, on expired hits, and at most once per minute during writes; no background daemon or scheduling is installed. Capacity shrink trims immediately. Permanent retention still obeys quota and manual clear; OS cache-folder eviction remains possible. UI saves preference changes atomically and rolls native configuration back if saving fails. Existing volumes retain their page size until re-unlock.


## PERF-02 大目录渐进加载（2026-11-09，源码变更）

目录首批立即展示，后续按约 32 ms 合并更新；自然名称及元数据排序键按当前目录缓存，新增批次排序后合并，列表/网格和视频邻居共享不可变快照。增量插入保持可见条目的纵向位置，主动换排序回到顶部。分页捕获固定过滤条件，过滤变更取消旧轮并重读；打开部分目录中的条目先取消并等待当前请求结束，已接收的有效数据保留，迟到响应丢弃。

Windows profile 模拟分页对照中，1 万项首屏 873.847 → 20.948 ms、5 万项首屏 4529.783 → 18.342 ms。缓存带来额外内存，主动切换五万项目录排序仍有同步开销；性能场景、测试、原始结果及边界见 [PERF-02 性能记录](read-performance.md#perf-02-大目录渐进展示与排序缓存2026-11-09)。本轮不更新发布包。


## PERF-03 磁盘缓存规模与维护（2026-11-10，源码变更）

磁盘缓存加入 65,536 个块的独立上限，和现有字节配额共同生效。扫描边读取边控制索引规模，不先收集所有文件。扫描、过期、缩容及清空由原生读取线程按最多 64 条记录/约 2 ms 的批次推进，与前台请求和 PERF-01 导出调度共存；单次系统调用仍不可抢占。维护期间绕过磁盘缓存，显式维护全局最多一个，支持排队/批次间取消、上下文释放与引擎退休。状态返回新增 limit_entries 和 maintenance_pending，状态查询不再同步清理全部过期项。

保留 v1 布局、目录锁、块校验和临时文件恢复；换目录扫描成功后才替换旧管理器，删除失败不虚报释放空间。Linux 73 项、Windows 66 项原生回归及双端 Clippy 通过。Windows release 对照、容量代价、内存及尾延迟边界见 [PERF-03 性能记录](read-performance.md#perf-03-磁盘缓存条目上限与协作维护2026-11-10)。本轮不更新发布包。


## PERF-04 磁盘缓存读写开销（2026-11-10，源码变更）

命中时以只读句柄校验，访问时间每块最多每 60 秒尝试持久化，保留逐次内存 LRU；完整页直接填入调用方缓冲，失败清零当前页，部分页继续使用 Zeroizing 临时缓冲。应用工作线程启用最多 32 页/8 MiB 的协作写回，约每四个前台工作项及空闲时推进，每批按约 2 ms 检查预算。队列满丢弃可选缓存写入，清空/配置变更撤销待写数据，读取器关闭清理所属队列，弱引用阻止过期任务落盘。独立核心调用者默认同步写入，仅在能够持续推进队列时显式启用写回。

Linux 78 项、Windows 72 项原生回归及双端 Clippy 通过。Windows NTFS/BitLocker 四状态顺序/随机对照显示热磁盘路径开销降低，冷随机路径并非全面提速；详情与复现见 [PERF-04 性能记录](read-performance.md#perf-04-磁盘缓存读取与写回开销2026-11-10)。本轮未重新打包发布。


## PERF-05 PDF 与图片二进制读取（2026-11-10，源码变更）

新增 `vhdx_file_read`（ABI 10）。每次最多 1 MiB，调用方拥有输出缓冲并负责清零/释放；Rust worker 用 Zeroizing 缓冲读取、返回后复制到调用方，JSON 只携带会话、错误和实际长度。队列和执行中的二进制请求共最多 8 个，按上下文取消；所有原生句柄继续留在原工作线程，错误沿用旧 JSON 路径的会话失效语义。原 JSON file_read/read 保留，便于兼容非原生后端和作对照。

Dart 辅助 isolate 调用二进制 ABI，以 TransferableTypedData 发送数据，UI isolate 不再解析 Base64 载荷。BackendRangeReader 仅合并当前请求所需的连续缺页，到缓存命中或 1 MiB 上限停止，仍保留 64 KiB × 16 页 LRU；不跨请求投机预读。取消、会话代次变化、锁卷、关闭或读取失败均拒绝迟到结果并清零可控缓冲。图片预览与图片缩略图使用同一最多 16 MiB 的 readAll，逐批检查撤销，失败清零部分结果；关闭预览清零其编码字节。

Windows 真实 NTFS/BitLocker 二进制传输、大图显示与关闭、PDF 翻页/缩放/损坏文件、视频缩略图共 6 项集成回归通过；Flutter 135 项测试及 analyze 通过。Linux 82 项、Windows 75 项原生回归与双端 Clippy 通过，包含 Linux 源故障清零专项。性能方法、复现和并非全面改善的指标见 [PERF-05 性能记录](read-performance.md#perf-05-pdf-与图片二进制读取2026-11-10)。本轮未重新打包或验证移动真机。


## PERF-07 缩略图持久化与缓存重开（2026-11-10，源码变更）

缩略图发布后立即归还生成槽位，独立 worker 完成 PNG 编码、磁盘索引、写入及淘汰；最多 64 个任务，只为执行中的一张图持有独立句柄（上限 4 MiB），排队任务复用现有内存缓存。缓存查找并发 2，独立于写入，显式清空时通过屏障等待删除完成。初始索引排序一次，后续通过有序 Map 增量维护 LRU，保留 256 MiB / 10,000 条双配额及 v1 文件兼容。

请求捕获缓存代次，配置、清空、锁卷/暂停和释放撤销迟到写入；rename 返回及 PNG 解码结束后复核有效性。队满、待写图片已被内存淘汰时跳过可选落盘，不阻塞显示；失败标记也使用有界队列。查找与持久化 trace 区分命中、禁用、未命中、失败和后台排队。

Flutter 165 项测试和 analyze 通过，真实 Windows 缩略图集成 3 项通过。在文件磁盘缓存与 BitLocker 缩略图缓存都开启的条件下，真实镜像重开为 5 次缩略图命中、1 次失败标记命中、零重新解码。Windows profile 三轮对照、后台落盘延迟及内存边界见 [PERF-07 性能记录](read-performance.md#perf-07-缩略图持久化与重开命中2026-11-10)。未更新发布包或测试移动真机，PERF-06 继续暂缓。

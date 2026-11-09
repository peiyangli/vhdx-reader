# 读取性能记录

首轮优化位于各平台共用的 Rust 读取核心，随后加入了共用 Flutter 设置页面中的缓存大小配置，接口版本升级为 ABI 7。这些修改已纳入 0.6.10+17 的 Windows、Android、macOS、iPhone/iPad 构建；具体安装包、签名限制及验证结果以 `artifacts/cache-settings-release-validation.json` 为准。设备上原有安装不会因生成安装包自动更新。

## 缓存大小设置

设置 → 文件读取缓存：16 / 32 / 64 / 128 / 256 MiB，默认 16 MiB；设置 → BitLocker 密文缓存：1 / 2 / 4 / 8 / 16 MiB，默认 1 MiB。前者作用于普通 NTFS 和解密后的文件数据，后者仅用于 BitLocker。两者均按每个已解锁卷分别限制，按需填充，不会在选中选项时立刻分配全部容量。原生库和播放器内存另计。

选择保存后，下次重新解锁或重新打开镜像生效；已有卷继续用原预算。普通卷打开、手动解锁、已保存凭据自动解锁三条路径均传递配置。设置失败保留原值并提示。数值偏好保存在各平台应用支持目录的 `read-cache-settings.json`，使用临时文件完成写入后替换；不包含凭据或文件内容。损坏、未知版本或超范围配置回退到默认值，Rust 端也独立检查允许的容量，拒绝在分配前接收任意大数值。

内存充裕时可先选 64 MiB 文件缓存、1 MiB 密文缓存。扩大文件缓存主要改善工作集超过 16 MiB 时的重复访问和视频往返拖动，不保证首次读取或持续播放加速；扩大密文缓存也有收益递减。若同时打开四个卷并都填满 64 MiB 文件缓存，仅这部分就约 256 MiB。

同一 32 MiB 生成文件先顺序读完，再执行 2000 次 4 KiB 随机访问，Linux release 各 5 次中位数：

| 缓存 | 首次顺序读取 | 后续随机读取 | 随机读取阶段底层调用 |
| --- | ---: | ---: | ---: |
| 16 MiB | 8.776 ms | 15.324 ms | 1574 |
| 64 MiB | 11.011 ms | 1.638 ms | 0 |

64 MiB 在此场景可以容纳已读的整个工作集，因此后续命中缓存；首次读取反而稍慢，不能将命中缓存的倍率套用到首次读取、超大视频或手机。原始数据位于 `artifacts/cache-settings/plaintext-{16,64}.csv`。benchmark 支持 `VHDX_BENCH_PLAINTEXT_MIB`、`VHDX_BENCH_CIPHERTEXT_MIB` 环境变量，默认仍是 16 和 1。

设置相关验证：Flutter analyze 和 55 项单元/界面测试通过；Windows 与 Linux 各 26 项 Rust 测试通过（Linux 本地 HTTP 测试仍受端口权限限制，由 Windows 覆盖）。测试包括偏好替换保存与损坏回退、64 MiB 在三条打开/解锁路径中的传递、横屏设置操作、保存失败与已有卷不重开，以及真实 BitLocker 64+4 MiB 配置读取、无效预算不破坏当前卷。Windows 实际应用集成测试也通过：从文件加载 64+4 MiB 偏好后打开真实 NTFS 镜像，在设置中改为 128 MiB 并验证持久保存，返回文件后仍可预览。0.6.10+17 打包时已补充 Windows/macOS 各 7 项实际应用集成测试，iPhone/iPad 模拟器各 8 项集成测试，以及 Android 真机普通卷/BitLocker 文件哈希验证；iPad 另有 2 项原生文件测试通过，独立原生钥匙串用例因缺少该测试宿主的夹具跳过（整合钥匙串用例通过）。Android 未重跑本轮完整界面测试，Apple 真机未进行本轮安装验证。

## 已实现

1. **BitLocker 密文读取合并**：在分区与 libbde 解密器之间增加 64 KiB 页、默认最多 1 MiB 的内存缓存，容量可按上面的设置调整。libbde 连续读取 512 字节扇区时，优先命中已读取的密文页，减少穿过 VHDX 和文件提供器的读取调用。明文缓存独立配置，默认 16 MiB。无明文落盘，无后台无限预读；最末页按分区长度截断。
2. **分页目录句柄复用**：保留一个正在分页读取的目录及条目总数，避免每页重新解析目录。起始索引为 0 时重新打开，换目录时替换，读完最后一页即释放。未引入随浏览路径数量增长的目录缓存。
3. **缓存淘汰与内存复用**：将每次淘汰扫描全部缓存页改为常数时间的 LRU 链接操作，复用被淘汰页的缓冲区。复用前清零全部旧内容，填充失败不加入缓存，未填满的临时缓冲区销毁时清零。

## 实测

全部使用 release 构建，每组执行 5 次，以下为中位数。计时覆盖 Rust/native 读取，不包括界面布局、播放器解码、首次打开镜像和密码解锁。每次重建会话，操作系统文件缓存未清空。两个版本使用相同样本、原生库和读取序列。

Windows x64 原生进程、本机 D: 文件：

| 场景 | 修改前 | 修改后 | 说明 |
| --- | ---: | ---: | --- |
| BitLocker 中 2 MiB 文件顺序读取 | 12.303 ms | 8.255 ms | 耗时约减少 33%；底层读取从 4224 次降到 33 次 |
| 约 2000 项目录，每页 200 项 | 19.521 ms | 11.579 ms | 耗时约减少 41%；与界面每页条目数一致 |
| 普通 NTFS 32 MiB 文件顺序读取 | 12.451 ms | 12.023 ms | 改善较小，接近测量波动范围 |
| 普通 NTFS 文件内 2000 次 4 KiB 随机定位 | 23.882 ms | 22.624 ms | 改善较小，约 5% |

WSL/Linux release 交叉检查：目录读取 12.537 → 6.439 ms（生成样本在 `/tmp`）；BitLocker 顺序读取 318.037 → 16.833 ms（私有样本在 `/mnt/d`）。后者经过 WSL 挂载路径，原先大量小读取的额外开销很高，**不能把这个约 19 倍的倍率用于宣称 Windows、手机或 SSD 都会同样加速**。

BitLocker 两个环境的 2 MiB 顺序读取，底层返回字节数均为 2,162,688，变化的是读取调用数量。加密样本的后续随机读取完全命中明文缓存，修改前后都是 0 次底层读取。大目录读取的底层字节数也未变化，优化主要减少重复解析。

纯内存缓存压力基准（Linux，无磁盘/解密）：512 MiB 顺序读取 95.796 → 84.408 ms，10000 次随机读取 102.401 → 90.900 ms。它用于观察缓存管理开销，不代表设备吞吐率。

原始 CSV、测试日志和中位数汇总保存在 `artifacts/read-performance/`，汇总为 `summary.json`。`file_seek_4k` 的 logical_bytes_or_entries 列记录请求字节数，接近 EOF 时实际返回可以较少；source_bytes 为底层实际返回字节数。

## 复现

生成测试镜像需要 `mkntfs`、`ntfscp`。脚本新建独立目录，拒绝复用已有目录，不编辑私有 examples。镜像为 64 MiB NTFS 卷，含 2000 个小文件、一个 32 MiB 确定性内容文件，以及 NTFS 自身的元数据条目。

```bash
python3 scripts/create-read-fixture.py --output /tmp/vhdx-read-fixture
cargo build --offline --release -p vhdx-core --example read_benchmark

# 无参数：纯缓存压力基准
target/release/examples/read_benchmark

export VHDX_NATIVE_DIR=/path/to/native/libs
export LD_LIBRARY_PATH="$VHDX_NATIVE_DIR"
target/release/examples/read_benchmark /tmp/vhdx-read-fixture/read-performance.vhdx /payload.bin

# 可选：私有 BitLocker 样本。仅传密码文件路径，不输出凭据或文件内容。
VHDX_BENCH_PASSWORD_FILE="$PWD/examples/password.txt" \
  target/release/examples/read_benchmark examples/bitlockervhdx.vhdx '/$LogFile'
```

`VHDX_BENCH_PAGE_SIZE` 可指定目录分页大小，默认 200。Windows 使用同一 Cargo example，设置对应的 `VHDX_NATIVE_DIR` 后执行生成的 `.exe`；不需要 `LD_LIBRARY_PATH`。本轮修改前的基准使用修改前 `source.rs`、`session.rs` 的隔离副本和相同 benchmark 源码构建。

## 验证与范围

- Windows：24 项 Rust 测试全部通过，含本地 HTTP Range、BitLocker 密码/恢复密钥、私有样本哈希与源文件未修改、跨页/跨块读取、会话隔离和句柄失效。
- Linux：24 项测试通过；本地 HTTP Range 因执行环境禁止绑定监听端口而跳过，此项已在 Windows 通过。首次 Linux 全量尝试的端口限制失败日志亦保留。
- 新增缓存测试覆盖容量 1～5 页的随机 LRU 序列、短尾页、部分读取后故障、失败后的恢复；生成镜像测试逐字节验证 32 MiB 文件、分页结果一致性及刷新/错误行为。
- 新增 BitLocker 回归断言：2 MiB 顺序读取的底层调用必须少于 128 次，后续缓存内随机读取必须为 0 次，并验证返回字节一致。
- `cargo clippy --offline --workspace --all-targets -- -D warnings` 通过。

已生成 0.6.10+17 各图形平台构建，并补测 Android 真机核心读取；尚未测外置 USB SSD、网络文件提供器、4K 视频或大容量加密视频的真实性能。下一轮应优先测这些真实存储路径的首次读取、连续吞吐和拖动延迟；同时记录底层调用次数与字节数。固定 64 KiB 读页可能使稀疏的小范围请求额外读取数据，需要结合设备延迟与流量再判断是否采用自适应读页。本轮没有增加多线程访问原生会话，继续遵守原生库的单线程归属。


## 0.6.19：Windows 加密后端对照（2026-11-06）

本轮只切换 Windows x64 的 libbde AES 后端：使用固定的 OpenSSL 3.5.9 静态 libcrypto 和上游 OpenSSL 3 EVP 无填充接口，由 OpenSSL 根据 CPU 能力选择实现。没有更改上游源文件，没有新增预读或并发访问原生会话，也没有调整 64 KiB 页、16 MiB 明文缓存、1 MiB 密文缓存。Android/Apple 后端尚未切换，不能将此结果套用到 ARM 或外接 SSD。

主机为 Intel Core i7-13700F，Windows release 构建。完整路径样本是私有 `bitlockervhdx.vhdx` 中的 `/video/avi.avi`，1,642,344 字节，XTS-AES-128（0x8004）。每次重新创建卷和读取缓存；镜像打开、密码推导、文件定位、输出缓冲区分配及 SHA-256 不计入顺序读取时间。每个后端/来源先预热一次，再交替顺序运行 5 次取中位数。RAM 模式先将整个加密镜像加载到内存，排除存储读取；file 模式使用本机 D 盘，**没有清除 OS 文件缓存**。

| 完整读取路径 | 原后端 | OpenSSL 后端 | 耗时变化 |
| --- | ---: | ---: | ---: |
| RAM 镜像，应用数据缓存首次读取 | 6.778 ms | 3.258 ms | −51.9% |
| 本机文件，应用数据缓存首次读取 | 6.873 ms | 3.416 ms | −50.3% |
| RAM 镜像，后续缓存命中读取 | 0.071 ms | 0.078 ms | 微小绝对差异，无改善 |
| RAM 镜像，后续 2000 次 4 KiB 随机读取 | 2.191 ms | 2.259 ms | 无改善，全部命中明文缓存 |

RAM 首次读取 5 次范围分别为 6.494–6.881 ms 和 3.127–3.417 ms，区间未重叠。两后端首次读取底层均为 26 次、1,703,936 字节；改善来自处理速度，不是减少读取量。缓存命中时间很短，不应把微小波动视为有意义的加速/退化。样本只有约 1.57 MiB；此处约 2 倍的是这一软件路径的读取吞吐，不是播放帧率、启动时间或 USB 吞吐。

独立加密基准使用与应用相同的 libcaes 接口，含逐扇区上下文设置成本；每个组合读取 32 MiB，重复 5 次，中位数如下（MiB/s）：

| 算法 | 扇区 | 原后端 | OpenSSL |
| --- | ---: | ---: | ---: |
| AES-CBC-128 | 512 B | 439 | 1,583 |
| AES-CBC-128 | 4096 B | 445 | 7,452 |
| AES-XTS-128 | 512 B | 350 | 1,473 |
| AES-XTS-128 | 4096 B | 363 | 6,600 |

不能用 4096 B 的纯加密吞吐代替 512 B BitLocker 扇区的解密速度，也不能用纯加密倍率代替完整读取倍率。CBC/XTS 的 128/256 位密钥、512/4096 B 扇区、不同 IV/tweak 的往返与跨后端密文一致性均通过；CBC 还核对 NIST SP 800-38A F.2.1 的独立已知向量。完整读取的 SHA-256 在后端、来源、轮次之间一致，随机读取逐字节对照顺序结果并核对 EOF。

媒体缓冲区复用另行制作了独立候选版本。两版本使用同一加速后端，4 轮交替运行；每轮 7 组，每组 16 次完整 HTTP 请求。加密小视频的各轮中位数为原实现 326.549 / 328.614 / 328.185 / 328.630 ms，复用版本 327.315 / 336.763 / 328.214 / 327.612 ms；32 MiB 普通 NTFS 文件分别为 650.091 / 650.186 / 648.696 / 649.268 ms 与 646.291 / 629.603 / 649.795 / 649.650 ms。未出现稳定收益，**不纳入本版**。当前连接接收的 20 ms 轮询等待会影响频繁创建 HTTP 请求的场景；可作为后续独立优化对象，但这些数据还不能证明整个播放器受其主导。

### 新基准复现

先保留原后端 DLL 目录，再构建候选后端；凭据只从文件读取，不输出内容。日志放 `.native/release-<version>/`，更新包平铺到 `artifacts/<version>/`。

```powershell
$env:CARGO_TARGET_DIR = "$PWD\target\windows"
cargo build --release --locked --offline -p vhdx-core --example pipeline_benchmark
cargo build --release --locked --offline -p vhdx-app --example media_benchmark
powershell -ExecutionPolicy Bypass -File scripts/build-openssl-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts/prepare-native-windows.ps1
cmake -S .native -B .native/build-windows-crypto -A x64 -DVHDX_OPENSSL=ON -DVHDX_CRYPTO_BENCHMARK=ON
cmake --build .native/build-windows-crypto --config Release --parallel 6
powershell -ExecutionPolicy Bypass -File scripts/benchmark-crypto-windows.ps1 `
  -Image "$PWD\examples\bitlockervhdx.vhdx" -File /video/avi.avi `
  -PasswordFile "$PWD\examples\password.txt" `
  -BaselineNative "$PWD\.native\release-0.6.19\builtin" `
  -CandidateNative "$PWD\.native\build-windows-crypto\bin\Release" `
  -OutputDirectory "$PWD\.native\release-0.6.19\crypto-results"
```

`pipeline_benchmark` 也可用于其他平台原生库，参数为镜像、镜像内文件、`ram`/`file`；默认 5 轮，可通过 `VHDX_BENCH_ROUNDS` 指定 1–100。为了在计时外核对结果，会在内存保留不超过 256 MiB 的完整明文参考，退出时清零；这是开发基准专用行为，不是应用读取缓存策略。CSV 中 `source_ms` 只计来源读取，不包含解密，也不应直接当作外置设备吞吐。`media_benchmark` 测量工作线程、原生读取与本地 HTTP 传输，不包含视频解码和渲染。

原始对照数据、未采纳的缓冲区实验、构建与回归日志保存在 `.native/release-0.6.19/`；私有镜像、凭据和测试工具不随应用打包。


本版交付验证：Windows 31 项 Rust 测试（含全部私有样本集成测试）通过；Linux 22 项基础测试通过，需原生样本的测试在 Windows 执行。两端 `cargo clippy --workspace --all-targets --offline -- -D warnings` 通过。Windows Flutter 原生集成测试通过：在真实 BitLocker 镜像中依次播放 ASF/AVI/FLV/MKV/MP4，检查鼠标切换、暂停/继续、快进及窗口生命周期；该测试使用 Debug 界面与同一组 Release 原生 DLL。未连接 iPad 或外置 SSD 测性能。


### Apple M2 对照与移动端判断（2026-11-06）

按后续要求，在 macOS 27.0.1 / Apple M2 上重新从同一 libbde 归档分别构建原后端和 OpenSSL 3.5.9 后端。两者均为 ARM64、`-O2`；Rust 1.96.1 release，同一读取代码、同一加密视频、相同缓存预算。使用隔离目录 `.native/crypto-benchmark-macos-arm64/`，没有替换 Mac 已安装应用或移动端的默认后端。测试方法、预热与交替轮次和 Windows 一致。

| Mac 完整读取路径 | 原后端 | OpenSSL 后端 | 耗时变化 |
| --- | ---: | ---: | ---: |
| RAM 镜像，应用数据缓存首次读取 | 6.904 ms | 2.934 ms | −57.5%（吞吐约 2.35 倍） |
| 本机文件，应用数据缓存首次读取 | 6.910 ms | 2.887 ms | −58.2%（吞吐约 2.39 倍） |
| RAM 镜像，后续缓存命中读取 | 0.052 ms | 0.049 ms | 微小绝对差异 |
| RAM 镜像，后续 2000 次 4 KiB 随机读取 | 4.173 ms | 4.090 ms | 无明显改善 |

RAM 首次读取范围分别为 6.741–7.280 ms 和 2.804–2.997 ms，区间未重叠。底层均为 26 次、1,703,936 字节。纯扇区 AES-XTS-128 的 512 B 吞吐为 304 → 1,374 MiB/s，4096 B 为 312 → 6,069 MiB/s；AES-CBC-128 分别为 332 → 1,489 MiB/s 和 329 → 7,230 MiB/s。CBC/XTS 128/256 位测试通过，生成密文与 Windows 两套后端逐字节一致；整文件 SHA-256 在平台/后端/来源之间也一致。Mac 加速后端的全部 Rust 原生集成测试通过，包含真实 BitLocker、HTTP Range、锁定撤销、缓存与镜像边界；这是原生库验证，没有宣称 Mac GUI 播放或 iOS/Android 真机验证。

**判断：移动端值得切换到同一 OpenSSL 3 EVP 后端。** ARM64 的完整读取收益已经由 Mac 证明，不只是 x86 AES 指令带来的优势。iOS/iPadOS 与 Android 仍需各自的交叉编译、静态链接/许可打包及读取/播放回归；本轮先完成判断，不直接更换现有移动端安装包。M2 数据不能代替 iOS 文件提供器、USB/exFAT、手机温控或 Android 不同芯片的实测结果，真机外置盘速度按计划后续验证。

Mac 复现（需要现有固定版本 libyal 的 macOS 安装目录、Perl、Xcode 工具链和工作区所需 Rust 依赖）：

```bash
RUSTUP_TOOLCHAIN=1.96.1 bash scripts/benchmark-crypto-macos.sh
# 两套后端已经构建好时，仅重新运行基准：
RUSTUP_TOOLCHAIN=1.96.1 VHDX_BENCH_SKIP_BUILD=1 bash scripts/benchmark-crypto-macos.sh
```

Windows 与 Mac 原始 CSV、测试日志和汇总统一保存于本机 `.native/release-0.6.19/`，包括 `macos-results/` 和 `performance-summary.json`。


## HTTP 与 libmpv 原生回调对照（2026-11-09）

已实现可选 `vhdx://` 只读流原型：libmpv 的 open/read/seek/size/close/cancel 回调直接调用 Rust，再通过原有八槽队列交给同一个读取工作线程。`Rc`/`RefCell` 原生句柄仍只在该线程使用。每次读取最多 256 KiB，工作线程返回的缓冲区复制一次到 mpv 提供的内存后清零；这是移除 HTTP/socket，并非零拷贝，也没有取消读取工作线程。

**首轮对照决定：当时保留 HTTP 默认路径，原生回调用于继续对照。后续按用户确认，0.6.21+28 改为普通播放和缩略图默认 native，并补测各平台。** 纯传输等待明显减少，但实际首帧与 CPU 收益依格式而异，只有 Windows 小视频进行了播放实测；尚不足以替换全平台默认路径。首轮缩略图默认仍使用 HTTP；随后完成的 Rust 预算、取消与队列修复见本文末节。

### 实现与生命周期

- `media_open` 可选 `transport: "native"`；缺省为 `http`。Flutter 正常播放可用 `--dart-define=VHDX_MEDIA_TRANSPORT=native`，也可在 `MediaPreviewSource.open(..., transport: ...)` 中逐个选择。首轮缩略图不随编译开关切换；0.6.21 最终配置改为两者统一默认 native，同样接受显式 HTTP 对照。未增加面向用户的设置项。
- ABI 7 增加可选 `vhdx_mpv_open` 导出，旧 HTTP 请求格式保持兼容。通过 media_kit 实际加载的 `NativeLibrary.path` 查找 `mpv_stream_cb_add_ro`，等待播放器初始化后注册。运行时只接受支持 cancel 字段的 API 1.106+ 或 2.x；当前 Windows 实际返回 2.1。不支持时明确失败，避免对照测试悄悄回退到 HTTP。
- 0.6.20 的 Windows DLL、Android ARM64 ELF 以及 macOS/iOS 真机/iOS 模拟器 ARM64 Mach-O 均已核对两个 mpv API 的定义导出。Android/Apple 这里只验证已有包的符号，不代表回调已在这些平台完成运行验证。
- 每条流使用随机 256 位 URL token；每次成功 open 有独立游标与取消状态，同时最多四个 open。全局注册表只存弱引用，注册时不分配 `user_data`。`media_close`、锁卷、上下文释放及读取 I/O/原生错误撤销流；迟到回调返回错误，实际 cookie 只在 mpv 的 close 回调释放。
- media_kit 1.2.6 在 `dispose()` 后延迟 5 秒才调用 `mpv_terminate_destroy`，所以不能随 Dart dispose 释放回调资源。本实现保持 Rust 动态库加载，cookie 通过 `Arc` 存活，不持有原生文件对象；回调不调用 mpv API。依据项目固定版头文件和[上游 stream_cb 接口约定](https://github.com/mpv-player/mpv/blob/master/include/mpv/stream_cb.h)。
- cancel 回调只写原子取消标志。等待工作线程结果时每 20 ms 检查取消/撤销，超时 10 秒后取消该读取；迟到数据销毁时清零。**这不能中断正在执行的单次 libyal/设备阻塞读取**，工作线程处理锁卷、关闭或下一任务仍可能等到该读取返回；取消等待不等于底层 I/O 已结束。
- `media_status` 增加 `transport`、`worker_read_calls`、`worker_read_bytes`、`worker_read_ns`。`bytes` 为向该传输交付的字节；原生 `ranges` 记录 seek（包括 mpv 打开时探测 seek），`requests` 记录 open，不能直接与 HTTP 请求数等同。worker 字节是文件逻辑读取量，**不是底层磁盘/SSD 实际读取量**。

### Windows 纯传输结果

同一主机、同一 OpenSSL 原生库和默认 16 MiB 明文 / 1 MiB 密文缓存，Rust release；7 轮，交替 HTTP/native 顺序。每条路径每轮重新打开镜像、解锁和创建卷缓存，OS 文件缓存未清空。先测新卷首次完整传输，再在计时外完整读取并核对 SHA-256，最后测 16 次完整传输；没有媒体解码与渲染。32 MiB 文件不能完全放进 16 MiB 缓存，“预热后”并不表示全命中。

| 样本/阶段 | HTTP 中位数 | 原生回调中位数 | 每次试验实际文件字节 |
| --- | ---: | ---: | ---: |
| BitLocker AVI，新卷首次读取 | 25.168 ms | 3.848 ms | 1,642,344 |
| BitLocker AVI，预热后连续 16 次 | 326.417 ms | 10.992 ms | 26,277,504 |
| 普通 NTFS 32 MiB，新卷首次读取 | 46.455 ms | 20.606 ms | 33,554,432 |
| 普通 NTFS 32 MiB，预热后连续 16 次 | 650.764 ms | 282.608 ms | 536,870,912 |

两条路径的工作线程读取次数和返回字节一致，SHA-256 一致。现有 HTTP 接收连接使用 20 ms 轮询；频繁重新连接的基准把这部分等待显著放大，**不能把表中的倍率当作播放加速比例**。32 MiB × 16 的整进程 CPU 中位数为 HTTP 421.875 ms / native 296.875 ms；Windows CPU 计时量化较粗，小文件试验常显示 0，不能据此推算 CPU 利用率。

### Windows 播放结果

真实 Flutter Windows Debug 界面，配套 Rust/读取 DLL 为 release，media_kit 1.2.6，libmpv API 2.1；普通生成的 32 秒 H.264/AAC MP4 和私有 BitLocker 样本 ASF/AVI/FLV/MKV/MP4，共 6 个视频 × 2 路径 × 3 轮。每次重新创建上下文/卷缓存，交替路径顺序，未清 OS 缓存。首帧从发起媒体打开开始，包含播放器与输出初始化；暂停后分别 seek 到 75% 和 25%，以独立弱客户端收到 `PLAYBACK_RESTART` 为结束，5 ms 轮询。它不是屏幕实际呈现时间戳。每次检查解码尺寸、禁用磁盘缓存、两次 seek 位置、内存截图及关闭后撤销。

| 样本 | HTTP 首帧 | 原生首帧 | HTTP seek | 原生 seek |
| --- | ---: | ---: | ---: | ---: |
| 普通 sample.mp4 | 329.166 ms | 317.187 ms | 32.673 ms | 16.819 ms |
| BitLocker AVI | 382.536 ms | 295.150 ms | 48.769 ms | 35.600 ms |
| BitLocker MKV | 294.803 ms | 298.482 ms | 34.058 ms | 20.953 ms |
| BitLocker MP4 | 350.696 ms | 320.219 ms | 64.031 ms | 66.296 ms |
| BitLocker ASF | 299.368 ms | 311.232 ms | 15.743 ms | 16.501 ms |
| BitLocker FLV | 293.771 ms | 307.812 ms | 33.486 ms | 17.625 ms |

表中首帧为 3 次中位数，seek 为两次位置 × 3 轮共 6 次中位数。样本量较小，首帧存在初始化波动，不主张稳定的全格式改善。整段打开/首帧/seek 的进程 CPU 有升有降，例如 AVI 281.25 → 296.875 ms、MKV 406.25 → 375 ms，不能宣称统一降低 CPU。

普通 MP4 完成两次 seek 后，工作线程逻辑读取量中位数为 HTTP 8,650,752 / native 6,422,528 字节；AVI 为 4,622,670 / 2,328,910 字节，ASF/FLV 两路径一致。HTTP 已发送、在途缓冲和中断连接后的当前块会使两路径交付/读取量不同；这不是磁盘实际读量，也不能据此推断多 GB 视频是否整文件扫描。

### 验证范围

Windows 37 项 Rust 测试（含私有样本）和 Clippy 通过；Linux 原有回归及新增回调回归通过，另用独立临时镜像副本截断模拟存储故障，确认错误不会被报告为 EOF，并撤销其他已打开游标。覆盖独立游标、超过 4 GiB 的 seek、EOF/负偏移、四路 open 上限、token 精确匹配、取消、锁卷、关闭上下文后迟到回调，以及取消等待不依赖原生 I/O 完成。

Flutter analyze 和 102 项单元/界面测试通过；36 次播放对照通过，另有 5 项启用 native 的真实播放回归通过，覆盖滑动切换、暂停/继续、快进、托盘暂停、损坏视频、误报诊断与取消后关闭。复查修复了 `NativeBackend` 在操作取消后也拦截 `media_close` 的缺口：清理撤销请求现在仍可送达 Rust，而普通读取仍被取消。Windows 多个 integration_test 入口连续启动曾碰到单实例宿主的启动冲突，现使用 `media_transport_regression_test.dart` 单入口执行这些回归。

以上存储故障是临时副本截断测试，不是实际 USB 拔盘；移动端/Apple 的运行生命周期和真实设备断开仍未验证。

### 复现与后续边界

已准备好 `.native/read-performance.vhdx`、`.native/media-fixture/media-preview.vhdx`、私有 examples 和对应原生库后：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/benchmark-media-windows.ps1
python scripts/summarize-media-benchmark.py .native/http-native --output .native/http-native/summary.json

# 单独验证启用原生回调的播放/切换/失败路径：
cd app
..\.tools\flutter\bin\flutter.bat test integration_test/media_transport_regression_test.dart -d windows --no-pub --dart-define=VHDX_MEDIA_TRANSPORT=native
```

`benchmark-media-windows.ps1` 的 `-Rounds`、`-Repeats`、`-PlaybackRounds` 控制次数，`-SkipTests`/`-SkipPlayback` 可缩小复测范围。通用 `media_benchmark <image> <file>` 接受 `VHDX_BENCH_ROUNDS`、`VHDX_BENCH_REPEATS`、`VHDX_BENCH_PASSWORD_FILE`，密码仅从文件读取；其他平台 CPU 列为 NaN。原始 CSV、播放日志、汇总保存在 `.native/http-native/`，不进入发布包。

仍待大 MP4/MKV、索引位置/缺失、真实外置 SSD/断开，以及 Android/macOS/iOS 运行对照；本轮未发布新包，也没有更改默认传输。现有小样本结果不能替代这些验证；缩略图机制修复另见下节，真实大视频慢因仍未确认。


## 缩略图读取预算、取消与队列修复（2026-11-09）

用户当前不提供私密问题文件，授权按代码机制优化。已确认并修复原有预算事后检查、打开阶段取消缺口、慢任务占住生成队列及视频自动重试的问题；没有将“整文件扫描”认定为用户问题的根因。

### 预算和取消语义

`thumbnail_begin` 在 `media_open` 之前创建任务。每次尝试共享 **32 MiB 文件逻辑读取预算、64 MiB 镜像源读取预算和 8 秒截止时间**，HTTP 与原生回调均使用同一实现。预算在调用读取前预留，短读/失败不退回；重复偏移也累计。多连接、Range、关闭流后重新打开都不会重置同一任务的预算。文件打开引发的 NTFS/镜像源读取也在任务范围内；普通浏览和完整播放不受缩略图预算约束。

镜像源指 `LocalFile`/文件描述符读取层：统计进入 libvhdi 前的源数据量，包含可能的元数据/加密数据读取，**不等于 SSD 物理读量**，OS 缓存和设备预读不在本计数范围。应用层命中缓存可能不产生源读取。预留量是硬边界；已返回字节和预留量分别报告。

`thumbnail_begin/cancel/finish` 只操作有界元数据，在 Dart 端直接调用 ABI，绕过可能阻塞的读取 isolate 和 Rust 工作队列；原生卷/文件仍只归属原读取工作线程。任务绑定 context/session，每上下文最多 4 个活跃任务，全局注册表最多 128 项。取消钩子在开始打开前安装；迟到的 `media_open` 结果仍关闭，迟到的图片仍销毁。锁卷、上下文关闭和引擎退休撤销对应任务。即使 `media_close` 被满队列拒绝，后续文件/媒体打开也会回收已取消或过期的缩略图流。

每次文件/镜像源读取前后检查取消与截止时间，传输等待读取结果时每 20 ms 检查。预算停止造成的 libyal 回调错误转成缩略图限制，不把正常卷误判为损坏并锁定。**单次已进入原生库或设备的阻塞 I/O 不能强制中断**；8 秒不承诺原生操作、关闭或底层设备在该时刻全部结束。共享读取线程仍可能等这次 I/O 返回。

### 队列、重试和诊断

视频正常生成并发仍为 1，总生成并发为 2。超时/取消会结束等待并释放生成槽位，后台迟到结果丢弃；至多保留 2 个尚未结束的生成/清理任务，达到上限时暂缓新生成，待清理返回后继续。这样既允许后续任务推进，也不会在设备一直阻塞时无限创建播放器。已有缓存查询保持独立，不受生成等待阻塞。

无法解码、没有可用缩略图、超时或超预算的图片/视频标记为不可用，不再按 1/3 秒间隔自动重试。内存失败键与磁盘缓存键一致，基于镜像身份/源版本、分区、路径、文件大小及修改时间，不读取内容计算哈希；重新打开同一镜像会复用。内存仍最多保留 256 个失败键。启用该类磁盘缓存时，写入仅含 `{"unavailable":true}` 的 `.thumb` 记录，重启应用后先查标记，跳过媒体读取和解码；缓存命中只读取这份小标记。所有磁盘条目共用原 256 MiB 默认预算，并增加最多 10,000 条的 LRU 上限，避免大量小标记造成条目无限增长。标记被缓存淘汰后可能重新尝试。

失败标记遵循普通卷/BitLocker 各自的磁盘缓存开关：BitLocker 默认仅内存记录，应用重启后可以再次尝试；明确开启后才跨重启保存，关闭时同步清除。文件身份/元数据变化会产生新键，清空缩略图缓存会清除失败标记并允许重试；若升级解码器后希望重试旧文件，可清空缓存。主动取消、切换/锁定卷以及报告的设备/会话/队列故障不持久标记为不可用，瞬时错误保留有界重试。超时可能包含设备变慢的情况，仍按本次生成不可用处理。预算可能让需要较多探测数据的视频只显示类型占位，这是有意限制后台工作量，不影响用户主动完整播放。

`ThumbnailCache(onTrace: ...)` 可启用诊断：排队、打开、首帧事件、截图累计、关闭耗时，生成 `outcome`，以及任务累计读取/预留字节、调用数、重新打开次数和停止原因。每任务最多记录 256 条文件/源偏移、长度、返回字节及耗时，另有丢弃条数；默认不采集详细轨迹、不自动写日志，也不记录视频内容。首帧字段使用播放器事件或首次成功截图，不能解释为屏幕实际呈现时间。成功取帧后也会取消后台读取，因此读取任务 `reason=cancelled` 不代表生成失败，应结合生成 `outcome` 判断；清理返回前仍在途的源读取由 `source_in_flight` 表示，结束快照未必包含迟到工作。

### 验证结果与样本边界

Windows 44 项、Linux 45 项 Rust 测试（含可用原生/样本测试）和两端 Clippy 通过。新增覆盖重复 Range/重新打开共用 32 MiB 预算、两种传输、源读取预算、截止时间、取消、未送达关闭的槽位回收，以及限制失败后正常卷仍可读。Flutter analyze 与 111 项单元/界面测试通过；新增覆盖超时让出队列、不自动重试、迟到图片销毁、打开期间取消、任务创建期间取消和待清理任务上限。失败标记补充 5 项测试，覆盖重开/重启跳过、文件变化和清空后重试、真实损坏图片、BitLocker 缓存开关、临时错误/取消不持久标记，以及超时任务尚未清理时的标记写入。

5 项 Windows 原生回调普通播放回归也通过，覆盖播放/快进/切换、BitLocker AVI/MKV、损坏视频和取消后关闭。

4 项 Windows 缩略图集成测试通过，包括已有普通文件、真实 BitLocker 视频与缓存重开、空闲界面出图，以及生成的 8 GiB 稀疏 MP4。生成样本将约 12.1 MiB 的 32 秒 H.264/AAC MP4 数据属性扩展至 8 GiB，尾部稀疏；同时保留一个未扩展的视频排在后面。实际分配量和编码内容没有变成 8 GiB，**它只验证大逻辑大小、随机访问及后续队列，不代表真实数 GB 编码视频**。

同一次 Windows Debug 界面测试、release 原生库，未清空 OS 缓存，两个视频均成功出图：

| 路径 | 8 GiB 文件逻辑返回量 | 镜像源返回量 | 两个缩略图合计完成时间 |
| --- | ---: | ---: | ---: |
| HTTP | 2,359,296 B | 1,114,128 B | 302 ms |
| 原生回调 | 524,288 B | 327,688 B | 294 ms |

以上是单次功能验证，不是性能基准，也不用于宣称加速比例。数据仅表明该生成样本未发生全文件读取，两路径均远低于预算，后续视频能够完成。

### 复现

生成普通视频的方法沿用 `scripts/create-media-fixture.py`。Linux/WSL 上准备好 `mkntfs`、`ntfscp`、`ntfsinfo`、`ntfstruncate` 后，使用自行生成的测试视频（不使用私密内容），输出目录必须不存在：

```bash
python3 scripts/create-thumbnail-fixture.py \
  --video .native/media-fixture/sample.mp4 \
  --output .native/thumbnail-limits/large-fixture
```

Windows 准备既有原生库、`examples` 测试镜像、普通媒体 fixture 后，在仓库根目录执行：

```powershell
$env:CARGO_TARGET_DIR = "$PWD\target\windows"
$env:PUB_CACHE = "$PWD\.tools\pub-cache"
$env:VHDX_NATIVE_DIR = "$PWD\.native\build-windows\bin\Release"
$env:VHDX_SAMPLE_DIR = "$PWD\examples"
$env:VHDX_READ_FIXTURE = "$PWD\.native\read-performance.vhdx"
$env:VHDX_MEDIA_FIXTURE = "$PWD\.native\media-fixture\media-preview.vhdx"
$env:VHDX_THUMBNAIL_FIXTURE = "$PWD\.native\thumbnail-limits\large-fixture\thumbnail-preview.vhdx"
cargo test --locked --offline --workspace -- --include-ignored
cd app
..\.tools\flutter\bin\flutter.bat test integration_test/thumbnail_limits_test.dart -d windows --no-pub
```

日志保存在本机 `.native/thumbnail-limits/`，生成脚本与回归代码进入仓库，媒体样本不进入发布包。随后已完成 0.6.21+28 各平台打包，产物及验证清单在 `artifacts/0.6.21/`。真实大 MP4/MKV、不同索引布局/缺失、外置 SSD 断开以及 Android/Apple 运行验证仍是后续覆盖项；0.6.21 最终发布配置按用户要求统一默认原生回调，HTTP 仅供显式对照。


### 0.6.21 原生默认路径的平台补测

用户最终明确要求普通播放与缩略图均默认去掉 HTTP 中转，因此发布配置统一使用原生 `vhdx://` 回调，未添加自动 HTTP 回退。测试以实际媒体状态及缩略图 `media_open` 请求验证 native 默认值，显式 HTTP 仅用于诊断对照。Linux CLI 不使用播放器传输。

Windows 9 项媒体/缩略图集成通过；Android 真机 4 项、Mac 7 项、iPhone/iPad 模拟器各 8 项 Flutter 集成通过，另各 3 项 Swift 测试通过。平台套件的系统凭据交互用例各跳过 1 项，Swift 独立凭据夹具用例各跳过 1 项；媒体用例未跳过。Windows 和 Mac 各 111 项单元/界面测试通过，Mac 46 项 Rust 测试通过。构建与运行日志在 `.native/release-0.6.21/`，签名与验证范围见交付 `manifest.json`。iOS 真机包仅编译/包验证，不将模拟器结果表述为物理 iPhone/iPad 验证；这些功能回归也不是跨平台性能基准。


## 外接加密盘播放缓冲调整（2026-11-09，源码变更）

针对外接 BitLocker 存储中约 500 MB 视频、文件读取缓存已设为 256 MiB、跳转后反复缓冲的反馈，调整普通播放器的独立包缓存：前向预算从 8 MiB 提高到 64 MiB，预读时间从 5 秒提高到 30 秒，后向预算仍为 2 MiB；字节与时间共同限制预读量。开启初始/跳转后缓冲，并把缓冲恢复目标明确设为 3 秒；达到 EOF 或字节上限时播放器可提前恢复，不要求每次实际等待 3 秒墙钟时间。缩略图仍使用 1 MiB、关闭预读的原策略。

该调整用于吸收读取延迟与码率波动，会增加按需使用的播放器内存，并可能增加首次出画面或跳转后的等待时间。文件读取缓存仍独立、按卷计量，磁盘明文缓存仍关闭。未改动解密算法、读取线程归属或精确跳转语义；持续读取吞吐不足时不能靠加大缓存解决。小样本回归不能替代用户外接盘上真实问题视频的验证，不宣称已消除该设备上的卡顿。

设置页新增“播放器缓冲容量”（8 / 16 / 32 / 64 / 128 / 256 MiB）、“播放预读时长”（5 / 15 / 30 / 60 / 120 秒）和“恢复播放缓冲时长”（1 / 3 / 5 秒），默认 64 MiB / 30 秒 / 3 秒。三项保存到本机 `read-cache-settings.json` 的独立 `playback` 字段，下次打开视频生效，不重建当前播放器或已解锁卷；旧配置缺失字段时采用新默认值，非法值回退，保存时拒绝超范围参数。每个打开的视频独立占用播放器缓冲内存，另计后向缓存与解码器内存。调整播放参数不再清空缩略图内存缓存。

本次验证：Flutter analyze 通过，114 项单元/界面测试通过，包含播放设置持久化、旧配置兼容、非法值回退、保存失败保留原值及 Windows/Android 横屏操作。Windows 9 项真实媒体/缩略图集成测试通过；播放用例从临时配置文件加载非默认的 32 MiB / 15 秒 / 1 秒设置，核对 libmpv 实际参数并执行播放中跳转、暂停跳转和关闭撤销。默认策略也通过真实 BitLocker 多格式播放回归，缩略图预算回归通过。运行日志为 `.native/playback-buffer-windows.log`。本轮未生成新的正式发布包，也未对用户的 500 MB 外接盘视频或 Android/Apple 真机进行性能验证。


## 可配置文件缓存分块与 16 GiB 上限（2026-11-09，源码变更）

根据后续要求，将文件读取缓存总容量扩展到最高 16 GiB（保留 16～512 MiB，新增 1 / 2 / 4 / 8 / 16 GiB），分块大小可选 64～512 KiB、1 / 2 / 4 MiB。默认保持 16 MiB 总容量、64 KiB 分块，不自动放大已有用户配置。总容量按每个已解锁卷计算，所有文件和元数据共享；按需填充，LRU 淘汰，分块不要求连续。1 MiB 分块下，8 GiB 可保留最多 8192 块，16 GiB 可保留最多 16384 块。

大分块会增加冷缓存小读取的额外数据量与解密量，不保证跳转更快；大容量在设备内存不足时也可能适得其反。应用设置显示内存计量和生效范围，不新增确认弹窗。BitLocker 密文缓存和播放器缓存独立。新参数经三条解锁路径传至 Rust，原生端独立校验容量、页大小与整数溢出；ABI 升为 8，需配套重建各平台读取组件。旧 JSON 缺少分块字段时采用 64 KiB，损坏或非法值回退，保存非法值会拒绝并保留原设置。

本次验证：Flutter analyze、116 项单元/界面测试、Windows 10 项实际应用集成测试通过；集成测试从本机配置加载 16 GiB + 1 MiB 分块，完成原生解锁、设置修改和文件预览。Windows 原生回归及全工作区 Clippy 通过，新增普通 NTFS/BitLocker 的 1 MiB、4 MiB 分块与默认读取逐字节对照。Linux 12 项核心测试通过。虚拟源测试覆盖全部可选分块大小、8 GiB 处跨块读取、短尾页、缓存命中和淘汰，并检查 16 GiB 预算在首次读取前没有分配缓存页，读取两页后仅保留两页数据；没有分配或压测满 16 GiB 内存。

日志：`.native/cache-layout-flutter-tests.log`、`.native/cache-layout-rust-windows.log`、`.native/cache-layout-core-windows.log`（新读取对照用例修正测试读取长度后重跑）、`.native/cache-layout-clippy-windows.log`、`.native/cache-layout-integration-windows.log`。本轮未重新打包正式安装包，未宣称在用户外接盘或移动设备上验证大容量满载性能。


## 可选磁盘缓存、128 GiB 上限和文件缓存总开关（源码变更）

文件缓存总开关默认开启，统一控制文件明文内存缓存、BitLocker 密文内存缓存和新增磁盘缓存；播放器缓冲与缩略图缓存独立。磁盘缓存默认关闭，默认容量 8 GiB、7 天未使用清理。容量可选 1 / 2 / 4 / 8 / 16 / 32 / 64 / 128 GiB，所有镜像共用；保留时间可选永久（不按时间清理）、1 / 7 / 30 天。永久仍受容量上限约束，也可手动清空。

磁盘缓存按文件缓存页保存到应用内部缓存目录，以明文存储已解密的数据。不预分配最大容量。按最近使用淘汰，容量降低立即清理；过期在启动、缓存访问、状态查询及策略变更时检查。关闭开关保留已有磁盘文件。清空磁盘缓存不清空已进入内存或播放器的数据。旧配置默认磁盘关闭；配置和手动清理通过读取工作线程执行，总开关与磁盘策略对已有卷生效，页大小变化仍在重新解锁后生效。

缓存文件包含校验和并通过临时文件替换；文件损坏、磁盘写入失败回退到原始读取，源读取错误仍按原逻辑处理。缓存身份依赖来源路径/URI、来源元数据版本和分区；来源缺少可靠版本时仅在本次打开期间复用命名空间，不保证跨重启命中。未引入加密、不预读整个视频、不把新增缓存的功能验证当作用户外接盘上的加速实测。接口升为 ABI 9，正式安装包需重新构建。


### 本轮验证（2026-11-09）

- Flutter analyze 无问题；118 项 Flutter 单元/界面测试通过，覆盖总开关、128 GiB、永久保留、设置持久化、保存失败回滚和清理失败提示。
- Windows `cargo test --locked --offline --workspace -- --include-ignored` 全部通过；Windows workspace/all-targets Clippy 零警告。真实 BitLocker 样本验证重新解锁后磁盘命中、跨镜像上下文共用策略、总开关即时生效、密码错误不绕过认证、清理及非法参数处理。
- Linux 核心/应用库测试 36 项通过、1 项依赖原生 fixture 的用例跳过（该路径在 Windows 验证）。核心覆盖磁盘块校验、损坏/写入失败回源、短尾块、LRU、永久及过期、目录锁和删除失败；Windows 的同时间戳访问使用单调序号保持淘汰顺序。
- Windows `release_media_test.dart` 11 项真实集成测试通过，包括实际播放/拖动、缩略图、缓存设置、视频两次打开后的磁盘复用，以及从设置关闭总开关后手动清空。

日志：`.native/disk-cache-flutter-tests-fixed.log`、`.native/disk-cache-rust-windows.log`、`.native/disk-cache-clippy-windows.log`、`.native/disk-cache-integration-windows.log`。仅构建测试应用，未重新生成正式安装包，未测试用户外接盘上的 2 GiB 视频或填满 128 GiB 缓存的性能。

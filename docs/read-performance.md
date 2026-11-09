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

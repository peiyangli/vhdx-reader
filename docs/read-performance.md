# 读取性能记录（2026-11-05）

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

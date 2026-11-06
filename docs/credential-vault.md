# BitLocker 自动解锁（v0.6 / ABI 6）

解锁页的“在此设备记住，下次自动解锁”默认关闭。只有成功打开解密后的 NTFS 卷才保存本次密码或恢复密钥；密码文件由 Rust 解析并保存有效凭据，不保存对该文件的依赖。保存失败仍可继续本次浏览，并显示未保存提示。

重新打开同一卷会自动尝试一次；失败回到手动输入，不删除原记录、不循环重试。主动锁定后，在当前镜像会话内切换分区也不会重新自动解开；可显式点击“使用已保存信息解锁”。顶部钥匙按钮管理单条删除和全部清除。删除凭据不会撤销已经打开的解密会话，要停止访问需另行锁定或关闭镜像。

## 卷身份

Rust 通过 libbde 读取未解锁卷的 Volume GUID 和密钥保护器 GUID 列表（排序，最多 128 项），连同分区偏移与长度做 SHA-256，使用 `v1-` 版本前缀。路径、文件名、盘符、VHDX 可变写入 GUID 不参与识别；移动或改名不影响匹配。完全复制且保留相同卷身份的镜像使用同一记录。重建卷、改变保护器或调整分区边界可能需要重新记住，旧记录可在管理页删除。无法可靠识别时禁用记住；不会扫描整个镜像计算哈希。

## 系统存储

- iOS/iPadOS：Security.framework Generic Password，`WhenUnlockedThisDeviceOnly`，`Synchronizable=false`。只在设备解锁时访问，不通过 iCloud Keychain 同步、不迁移到其他设备。
- macOS：当前用户 Keychain Generic Password，关闭同步，访问受钥匙串和应用签名身份限制。macOS 钥匙串锁定与屏幕锁定并不等价。更换签名身份可能需要重新授权/重新保存。
- Windows：当前用户范围 DPAPI，禁止弹出加密交互窗口。密文位于 `%LOCALAPPDATA%/VHDX Reader/credentials-v1.dpapi`，先写入独占创建的临时文件并同步，再原子替换；不使用机器范围加密。
- Android：Android Keystore 的 AES-256-GCM 密钥，固定用途 AAD、每次写入新随机 IV；密文通过 AtomicFile 保存到 `noBackupFilesDir`。每次操作检查 Keyguard，API 35+ 同时启用 `setUnlockedDeviceRequired`；旧系统因官方记录的失效问题只使用应用侧锁屏检查。不承诺所有设备均提供硬件级密钥保护。
- Linux 尚未接入 Secret Service；相关选项禁用，没有明文降级。

安全存储保存一个版本化加密记录，内含卷指纹、凭据类型、有效凭据、展示名称和更新时间；最多 256 条、序列化上限 4 MiB。损坏或不可读取的记录不会被当作空库覆盖。读取/修改在同一个 Rust 工作线程中串行处理，保障同一应用多标签之间一致；不提供多个独立应用进程并发编辑凭据库的协调保证。

保存与读取直接由 Rust 调用系统接口，Android 通过 JNI 调用 Keystore；Flutter 只接收状态和列表元数据。保存的密码不会回填到 Dart 文本框，也不放入 VHDX、外置 SSD、普通配置、日志或应用包。Rust 的凭据和序列化缓冲区用 Zeroizing 清理，Android 临时明文字节数组用后清零。系统 API、运行时及手动输入的 Dart 字符串仍可能产生短暂内存副本，不承诺完全消除所有明文副本。

## 协议和生命周期

新增 `vault_status`、`vault_list`、`vault_remove`、`vault_clear`、`unlock_saved`；`unlock` 新增 `remember` 和 `label`。自动解锁会对当前上下文/会话重新计算指纹，再读取匹配凭据，不接受 UI 传入任意卷的凭据 ID。会话代际校验和取消检查复用现有工作线程。`unlock` 返回 `remembered: true/false/null`；保存失败与解锁失败分开处理，`remember_error` 仅返回不含凭据的诊断代码。安全存储不可用、暂时锁定、记录不存在、格式损坏分别返回不包含秘密的错误。

“清除全部”清除本应用凭据库；不会删除系统中其他应用的凭据。系统卸载行为不作为删除保证，尤其 Apple Keychain 可能保留记录；需要删除时应使用管理功能。Apple Team / bundle 身份改变后不承诺读取旧记录。自动解锁不替代系统文件授权，外置 SSD 重新接入后仍可能需要再次选择文件。

## 移动端身份验证

Android 和 iOS/iPadOS 每次使用已保存信息解锁（包括打开镜像时的自动尝试）均先调用系统身份验证。现有记录同样受保护，无需删除后重存。取消、超时、设备未设置锁屏凭据或认证服务不可用时不执行已保存密码解锁、不删除记录、不自动循环弹窗；仍可手动输入 BitLocker 密码。主动锁定后再次使用保存信息必须重新验证。

- iOS/iPadOS：每次创建新的 LocalAuthentication LAContext，使用 deviceOwnerAuthentication，支持 Face ID、Touch ID 或设备密码；不复用上次认证。声明 Face ID 用途。
- Android 11/API 30 及以上：系统 BiometricPrompt，允许强生物识别（设备支持的指纹/人脸）或设备 PIN/密码/图案；不满足强生物识别要求的人脸可改用设备凭据。
- Android 7–10/API 24–29：使用系统锁屏 PIN/密码/图案确认界面。
- Windows/macOS 保持原有自动解锁行为。

验证在 Rust 获取可用于解锁的保存凭据入口强制执行，由原生系统回调返回结果，不接受 Flutter 传入“已认证”标记。跨镜像同时请求时仅允许一个验证流程；认证等待最多 120 秒。iOS 未注册原生验证器时拒绝已保存密码解锁。移动端 UI 检查原生组件的认证能力声明，旧组件不支持时禁用保存与自动解锁，避免仅更新界面后绕过验证。

这层保护控制本应用使用已保存密码的操作；现有 Keychain/Keystore 加密格式不变，未改为需要生物认证才能解密的独立密钥。状态查询和管理列表仍由原生层读取加密库后只返回元数据。它不替代系统存储保护，也不自动锁定已经打开的浏览会话；需要停止访问时仍需主动锁定或关闭镜像。应用、Android JNI 库与 iOS 原生库需一起更新。

系统 API 依据：[Android 生物识别](https://developer.android.com/identity/sign-in/biometric-auth)、[Apple 设备所有者认证](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication)。

## 验证入口

- `app/test/reader_test.dart`：默认不记住、自动尝试一次、主动锁定、删除管理、失败回退及保存失败仍可浏览。
- 移动端真实安全存储回归现在需要在设备上完成系统身份验证；不能将无人值守测试停在认证弹窗视为通过。
- `app/integration_test/vault_test.dart`：真实系统安全存储、成功后保存、错误密码不覆盖、重建读取实例、改名副本、多个镜像、删除后无法再自动解锁。
- `app/integration_test/android_test.dart`：真实 Keystore + 文档描述符路径。
- `app/ios/RunnerTests/RunnerTests.swift` 的 `testSavedCredentialSurvivesContextRecreation`：真机钥匙串回归，仅操作测试新建的记录，不卸载应用；若样本已被用户记住则跳过。
- macOS 钥匙串集成测试应从已登录的桌面会话运行；SSH 会话可能被系统拒绝访问钥匙串，此时程序返回 `vault_locked`，不会降级存储。
- `vault_test.dart` 会清除自己创建的样本记录，不清除已有用户记录；若样本已经被记住则明确停止该测试，要求使用隔离测试环境。

本次 iPhone SE 真机用例在 XCTest 控制台报告执行 1 项、0 失败。测试后的 Xcode 清理阶段停滞，已停止该测试进程并恢复 Release 包；该项依据控制台用例结果记录，未将未完成的 xcresult 或单纯的进程返回码当作通过证据。

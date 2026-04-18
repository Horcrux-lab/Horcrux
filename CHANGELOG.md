# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0-dev.48] - 2026-04-18

### Changed

- **iOS**: 残留 i18n 扫尾批次 —— `SigningView` + `SigningViewModel`（费率 Picker 4 段、原生代币后缀、Gas 价 gwei label、ENS 解析失败提示、生物识别失败 icon、TRC-20/SPL/ERC-20 代币转账 label、TRX 能量费用格式化、广播失败前缀格式化），`ContentView` 初次启动 3 张教学卡（无需助记词 / 多设备阈值 / 多链一套分片）+ "继续" 按钮，`ShardsViewModel`（PIN 错误 2 条、iCloud RK 不可用 fallback、导出摘要 + 复数格式化），`PortableBackupCrypto` 备份错误 3 条，`ColdSigningCoordinator` 冷签名错误 3 条，`ReceiveView` 请求金额 + 可选占位符，`CopyFeedback` + `SecureClipboard` 默认 toast 文案改为 `L10n.Common.copied`，`CustomTokensView` Solana mint 地址占位符。共替换 37 处；新增 `L10n.SigningExtra`（14 键）/`OnboardingCards`（7 键）/`ShardsVM`（5 键 + 2 复数 formatter）/`BackupCrypto`（3 键，2 formatter）/`ColdSignErr`（3 键，1 formatter）/`ReceiveExtra`（2 键）/`CustomTokensExtra`（1 键）。

## [0.3.0-dev.47] - 2026-04-18

### Changed

- **iOS**: `TransactionHistoryView` + `WalletHomeView` RBF 说明 Sheet / 空钱包 CTA / 总资产卡片 + `SettingsView` 语言 / 设备昵称 / 硬件钱包 Alert / PIN 强度 Label / ReplaceDeviceInfoView 全部文案本地化 —— `L10n.TxHistory` 扩展 11 条（4 段状态过滤、状态 Picker、搜索占位、刷新 / 导出 CSV、加速 RBF Label/Body、已是最新、已同步 N 条格式化），新增 `L10n.RBFSheet` 9 条（加速被卡住的交易标题 / 解释 / 3 条可用操作 / 丢弃重签按钮 / 导航标题 / 关闭），新增 `L10n.WalletEmpty` 10 条（开始使用 / 接收提示 symbol 格式化 / 已复制 / 复制地址 / QR / 自定义代币 / 总资产 / 单多账户 summary 格式化 / 删除确认 message），新增 `L10n.SettingsResidual` 24 条（语言 Section / 行 / 设备昵称 + hint / 硬件钱包 Alert + 副标题 / 简体中文值 / PIN 强度 4 档 / 替换设备 5 段步骤 + 即将推出 + 刷新说明）。共替换 50 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.46] - 2026-04-18

### Changed

- **iOS**: `AddressBookView` + `CustomTokensView` 全部文案本地化 —— 新增 `L10n.AddressBook`（20 条：空态 / 新建编辑 / 导出导入 / 选择联系人）与 `L10n.CustomTokens`（15 条：空态 / 添加代币表单 / 元数据占位符 / 自动查询错误）。替换 37 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.45] - 2026-04-18

### Changed

- **iOS**: `ShardsListView` + 账户详情 / 备份 / 导入 / 删除 Sheet 全部文案本地化 —— `L10n.Shards` 追加 ~20 条（派生地址、删除不可逆 Alert、删除双重确认 Toggle、删除链清单模板、PIN 错误），`L10n.ShardBackup` 补 8 条（导出介绍模板、iCloud RK 提示、PIN Header/Footer 分支），`L10n.ShardImport` 补 14 条（账户/链/派生钱包 Label、加密方式分支、旧格式值、RK 信息横幅、恢复/解析错误）。替换 39 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.44] - 2026-04-18

### Changed

- **iOS**: `CreateShardFlow` + `CreateShardViewModel` 全部文案本地化 —— 向 `L10n.CreateShard` 追加 ~40 条键（角色选择器、价值前言、链类型、高级设置、房间码输入、MPC 解释器 4 组图文、N-of-N 风险 Alert），`L10n.Discovery` 补 9 条（秒后超时、在场设备计数、等待发起人），`L10n.DKG` 补 ~15 条（收尾 / 已用时 / 预计剩余、未备份退出 Alert、保存失败、VM 错误文案），新增 `L10n.Backup` 枚举覆盖强制备份 Gate 的 9 条文本。替换共 63 + 7 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.43] - 2026-04-18

### Changed

- **iOS**: `SigningView` 全部文案本地化 —— 向 `L10n.Signing` 追加 ~27 条静态键 + 4 个带参格式化（`ensResolving` / `tokenTransferDescContract` / `tokenTransferDesc` / `feeWarnPct`），覆盖地址簿按钮 a11y、资产 / 费用优先级 Picker、自定义 gas 与 sat/vB 占位、共同签名方列表、缓慢 / 等待提示、生物识别 reason、交易预览（操作 / 资产 / 金额 / 合约 / 网络费）、收款地址分段提示、复制 / 浏览器 a11y、余额变化、ENS 解析进度、费率警告等 29 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.42] - 2026-04-18

### Changed

- **Build**: 修复 `ios/build-rust.sh` 每次都重新编译 `gmp-mpfr-sys` / `rug` / `cggmp21`（约 30 秒）的问题 —— 删除 `third_party/gmp-mpfr-sys/src/C.rs`（该模块仅用于 rustdoc 内联 GMP/MPFR 的 HTML 手册，`doc-c/` 已从 vendored copy 中剥离），以及 `lib.rs` 的 `#[cfg(doc)] pub mod C;` 声明。cargo 的 fingerprint 不再因 49 个 `include_str!` 目标缺失而反复失效；重复运行降至 ~3 秒
- **iOS**: `NodeErrorMapper` + `ShardHealthView` 全部文案本地化 —— 新增 `L10n.NodeErr`（16 条，含广播失败前缀）与 `L10n.ShardHealth`（13 条静态 + `lastCheck` / `resOK` / `resUnreadable` 带参），同步 en + zh-Hans .strings

## [0.3.0-dev.41] - 2026-04-18

### Changed

- **iOS**: `ColdSigningView` 全部文案本地化 — 新增 `L10n.ColdSign` 命名空间（24 条 + 带参 `sigLength`），同步 en + zh-Hans .strings，为 dev.39 的冷签名实验特性提供完整双语支持

## [0.3.0-dev.40] - 2026-04-18

### Added

- **iOS**: 应用内语言切换（设置 → 语言 / Language）— 跟随系统 / 简体中文 / English 三选一，写入 `AppleLanguages` UserDefault，切换后提示重启生效（`LanguageSettingsView`）
- **iOS**: `Info.plist` 声明 `CFBundleLocalizations = [zh-Hans, en]`，使 iOS 系统设置 → Horcrux → 首选语言页面出现语言选项

### Changed

- **iOS**: 抽取 ~30 条高曝光硬编码中文到 L10n + `zh-Hans` / `en` .strings（设置页各分组标题、钱包行为菜单、批量重命名/删除弹窗等）

## [0.3.0-dev.39] - 2026-04-18

### Added

- **iOS**: 冷签名模式（**实验性**）— `ColdSigningCoordinator` + `ColdSigningView`，在两台设备间轮流扫描 QR 完成 FROST 签名，不依赖中继 / 不发网络请求。当前版本仅实装 **2-of-2 钱包的发起方（initiator）** 状态机；对端（cosigner）状态机计划于 dev.40 发布
- **iOS**: `ColdPacket` 编码格式定义 —— invite（会话参数 + 第 1 轮消息）+ round（任一轮消息批）两类包，base64 JSON 承载，单个 QR 容纳 2-of-2 FROST 全部消息

### Notes

- **iCloud 分片备份**：v5 备份格式已使用 iCloud-synced Recovery Key 加密（`AccountBackup` version 5 + `RecoveryKeyManager`），用户在"分片"页导出后可存入 iCloud Drive，于任一登录同 Apple ID 的设备免密码还原 —— 此能力此前已在 dev.13 前落地
- **i18n 全面翻译**：现有 L10n 目录已覆盖 ~80 键值（中 / 英），剩余 352 处硬编码中文将分批在后续 dev tag 抽取

## [0.3.0-dev.38] - 2026-04-18

### Added

- **iOS**: App Intents / Siri Shortcuts — "复制地址" / "收款二维码" 两个意图，支持 Shortcuts app 与语音调用（无需 WalletConnect）
- **Core**: shard crypto 新增 5 个单元测试（错误设备密钥拒绝、nonce/salt 唯一性、密文篡改检测、HKDF 派生稳定性 / salt 发散性）

### Fixed

- **Build**: `third_party/gmp-mpfr-sys` 的 `pub mod C` 增加 `#[cfg(doc)]` gate，避免本地 `cargo test` 因 vendored 副本精简掉 `doc-c/` HTML 而失败

## [0.3.0-dev.37] - 2026-04-18

### Added

- **iOS**: 分片健康自检（设置 → 诊断 → 分片健康自检）；检查每个账户的 keychain 分片是否可读取，提前发现丢失 / 损坏
- **iOS**: 空钱包详情页 CTA 卡片（零余额时引导复制地址、显示 QR、添加代币）

## [0.3.0-dev.36] - 2026-04-18

### Added

- **iOS**: 交易历史导出 CSV（菜单里的"导出 CSV"，遵循当前筛选条件，UTF-8 带 BOM 兼容 Excel）
- **iOS**: 交易历史顶部改为菜单（刷新 / 导出）

## [0.3.0-dev.35] - 2026-04-18

### Added

- **iOS**: 交易确认后自动推送本地通知（接入已有的 `TransactionConfirmationPoller`）
- **iOS**: 交易详情页显示 USD 金额（基于 `PriceService` 已缓存行情）

## [0.3.0-dev.34] - 2026-04-18

### Added

- **iOS**: BTC / LTC 真实 RBF 加速——在待确认交易详情页一键发起替换交易，自动预填收款人/金额并跳到 Fast 费率档；广播成功后原交易在本地历史中标记为已被替换

### Fixed

- **iOS**: `TransactionStore.withUpdatedHash` 在更新哈希时丢失 `confirmedAt` 的潜在 bug

## [0.3.0-dev.32] - 2026-04-18

### Added

- **iOS**: ERC-20 交易历史同步（Etherscan V2 `tokentx`，所有 EVM 链）
- **iOS**: 自定义代币添加 / 删除 UI；支持手动填写或链上 `name()` / `symbol()` / `decimals()` 自动查询
- **iOS**: 签名前生物识别门禁开关（可选，设置里切换）

## [0.3.0-dev.31] - 2026-04-18

### Added

- **iOS**: 钱包重命名 / 本机删除菜单（保留分片）
- **iOS**: 交易历史分状态分段筛选（全部 / 待确认 / 已确认 / 失败）+ 地址/哈希/金额搜索
- **iOS**: 收款 QR 支持请求金额（BIP-21 / EIP-681 / Solana Pay）

## [0.3.0-dev.30] - 2026-04-18

### Added

- **iOS**: BTC / LTC 自定义 sat/vB 费率
- **iOS**: TRC-20 代币交易历史同步

### Changed

- **iOS**: `ExternalTx.deltaSmallest` / `feeSmallest` 由 `Int64`/`UInt64` 迁移至 `Decimal`，避免 >18 ETH 溢出

## [0.3.0-dev.29] - 2026-04-18

### Added

- **iOS**: EVM（Etherscan V2 多链）与 Solana（getSignaturesForAddress + getTransaction）交易历史同步
- **iOS**: Settings 新增 Etherscan API key 配置（Keychain 持久化）

## [0.3.0-dev.28] - 2026-04-18

### Added

- **iOS**: BTC / LTC / TRON 交易历史同步（通过 keyless 公共 explorer API）
- **iOS**: TransactionHistoryView 下拉刷新 + 手动同步按钮 + 结果提示

## [0.2.0] - 2026-04-16

### Added

- **MPC**: CGGMP21 threshold ECDSA for Secp256k1 (Kudelski-audited library)
- **MPC**: IETF FROST (RFC 9591) for Ed25519
- **Relay**: WebSocket relay server with per-IP rate limiting and room management
- **Relay**: `/health`, `/metrics` (Prometheus), `/admin/rooms` endpoints
- **Relay**: Room capacity limits (`max_rooms`) to prevent OOM DoS
- **Relay**: Structured tracing with `#[instrument]` spans
- **Relay**: Config env var clamping with warning logs
- **Core**: Noise Protocol XX E2E encryption for peer communication
- **Core**: AES-256-GCM shard encryption with HKDF key derivation
- **Core**: Session token generation with HKDF (returns `Result`)
- **Core**: Session TTL tracking with automatic cleanup
- **Core**: Bitcoin (BIP-143), EVM (EIP-1559), Solana transaction building
- **Core**: Constant-time comparisons via `subtle` crate
- **iOS**: Full SwiftUI app with MVVM architecture
- **iOS**: Secure Enclave device key + PBKDF2 PIN verification
- **iOS**: Certificate pinning (TOFU + pre-registered SPKI hashes)
- **iOS**: Anti-debug / jailbreak detection
- **iOS**: BLE, Wi-Fi LAN, Wi-Fi Direct, QR, and Relay transport layers
- **iOS**: Shard backup/restore with QR export
- **iOS**: Multi-chain wallet management (ETH, SOL, BTC)
- **iOS**: Transaction signing with threshold co-signing ceremony
- **iOS**: Accessibility support (`@ScaledMetric`, Dynamic Type, VoiceOver labels)
- **iOS**: Localization framework (L10n) with i18n-ready strings
- **iOS**: Background state cleanup (zeroes sensitive memory)
- **iOS**: `PrivacyInfo.xcprivacy` for App Store compliance
- **Infra**: Dockerfile with multi-stage build, non-root user, health check
- **Infra**: CI pipeline (tests, clippy, fmt, cargo-audit, coverage, iOS build)
- **Docs**: Architecture, MPC protocol, security model, deployment guide (803 lines)

### Security

- Replaced custom constant-time comparisons with `subtle::ConstantTimeEq`
- HKDF `expect()` calls converted to proper `Result` error propagation
- `decrypt_shard()` returns `Zeroizing<Vec<u8>>` for automatic memory zeroing
- Mutex poison recovery changed to fatal `expect()` (fail-fast on corruption)
- Config `validate()` returns `Result<(), ConfigError>` instead of panicking
- LAContext explicitly invalidated after biometric operations
- TOFU pins stored with `AfterFirstUnlockThisDeviceOnly` Keychain protection
- NetworkConfig RPC validation uses pinned URLSession
- Room join uses atomic CAS for participant count (no TOCTOU race)
- Relay enforces `from == device_id` (prevents sender spoofing)
- Per-connection token-bucket rate limiting + per-IP connection throttling
- WebSocket origin validation (CSWSH protection)
- Replay protection via per-device sequence number tracking

### Fixed

- Eliminated all `fatalError`, `try!`, `as!` from iOS production code
- ECDSA public key serialization failure now logs error instead of silent empty string
- Config ping/pong timing validation (prevents mass disconnection)
- RPC retry with exponential backoff (3 attempts, 500ms→2s + jitter)

## [0.1.0] - 2026-03-01

### Added

- Initial project structure with workspace (horcrux-core, horcrux-relay, uniffi-bindgen)
- Basic MPC keygen and signing (Feldman VSS Schnorr)
- UniFFI bindings for iOS
- Skeleton iOS app

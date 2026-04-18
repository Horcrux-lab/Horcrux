# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

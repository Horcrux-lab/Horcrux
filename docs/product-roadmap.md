# Horcrux Product Roadmap

基于 PM 产品评审的改进路线图。P2 不实现，按 P0 → P1 → P3 顺序执行。

> **状态复核 2026-07-29（v0.5.0 发布时）** — 本文件原先声称
> 「全部完成 10/10」，那是 2026-04-17 的快照，此后代码已经走远。
> 逐项对照当前代码后，实际是 **8 项达成、1 项部分达成、1 项未实现**。
> 三处失真见下表备注，详情在各自小节。本文件记录的是产品意图，不是
> 发布计划；`0.6.0-dev` 周期尚无产品方向文档。

## 状态一览（8 达成 / 1 部分 / 1 未实现）

| 优先级 | 项目 | 原始提交 | 当前状态 |
|---|---|---|---|
| P0.1 | 默认 2-of-3 | `30041ea` | ✅ 达成 |
| P0.2 | 钱包恢复流程 | `c544ca6` | ✅ 达成（原 v2 `ShardBackup` 已降级为 legacy 导入路径） |
| P0.3 | 内置中继配置 | `e6563c6` | ✅ 达成 |
| P0.4 | ERC-20 代币支持 | `56ffc86` | ✅ 达成 |
| P1.1 | BIP39 3 词房间码 | `6fa44aa` | ✅ 达成 |
| P1.2 | 价值主张引导 | `3ccf574` | ✅ 达成 |
| P1.3 | 交易预览/模拟 | `06e6d24` | ✅ 达成 |
| P3.1 | 云备份（加密分片） | `96f6c2d` → 已被取代 | ✅ 达成，**但实现已换代**（见 P3.1） |
| P3.2 | 多账户 | `96f6c2d` | ⚠️ **部分**：交付的是多链分组，非 HD 派生（见 P3.2） |
| P3.3 | 硬件钱包联动 | `96f6c2d` | ❌ **未实现**（见 P3.3） |

## P0 — 安全与基础功能（已完成）

### P0.1 默认推广 2-of-3 配置
- **问题**：2-of-2 任一设备损毁即资产永久丢失
- **方案**：
  - 创建流程默认 2-of-3
  - UI 引导用户配置 3 台设备（主手机 + 平板 + 备份设备）
  - 当前 2-of-2 仍可用，但需用户主动降级

### P0.2 钱包恢复流程
- **问题**：手机丢失后如何在新设备上恢复钱包
- **方案**：
  - 导入分片时，自动匹配已知 `groupPublicKey`，若找到则提示"此分片属于钱包 XXX，是否恢复？"
  - 新增 Recovery 流程入口（Shards 页顶部）
  - MPC Share Refresh：剩余 t 台设备可重签，让旧分片失效

### P0.3 内置 Relay 服务器
- **问题**：Settings 默认 `ws://localhost:3210`，普通用户无法连接
- **方案**：
  - 内置官方 relay URL（production），可切换自定义
  - 首次启动自动使用内置 relay
  - 显示 relay 连接状态指示灯

### P0.4 ERC-20 代币支持
- **问题**：只显示原生 ETH/BTC/SOL，缺失稳定币等代币
- **方案**：
  - 钱包详情页代币列表（USDT/USDC 默认显示）
  - 发送流程支持选择代币
  - 签名时 decode ERC-20 transfer 调用

## P1 — 用户体验与信任

### P1.1 Room Code 用单词短语
- **问题**：`my-wallet-123` 用户易输错
- **方案**：`apple-river-moon` 风格 BIP39 词表三词短语

### P1.2 价值主张引导
- **问题**：用户不懂为何用 Horcrux 而非 MetaMask
- **方案**：Onboarding 新增三屏说明（无单点私钥 / 多设备签名 / 丢设备不丢钱）

### P1.3 交易 Simulation
- **问题**：Co-signer 看不到交易的可读描述
- **方案**：签名前显示"你将失去 X ETH 获得 Y USDC"、目标合约是否已验证

## P3 — 长期增强

### P3.1 云备份（加密分片）
- iCloud 加密备份一个分片
- 或导出加密 QR 打印纸备份

**已实现，但实现已换代两次。** 目标达成了，路径变了：

1. `96f6c2d`（2026-04）最初的做法是 `ShardBackupView` 里一个
   「Save to iCloud Drive」按钮，直接写 ubiquity container。
2. 该文件与整条 iCloud Drive 路径**已被删除**，代码库里现在没有
   任何 `ubiquity` / `iCloud Drive` 字样。

   取而代之的是可携带备份信封（`Security/PortableBackupCrypto.swift`
   + `Security/RecoveryKeyManager.swift`），按账户导出，两种格式：

   - **v5（首选）** — 用 iCloud Keychain 同步的 Recovery Key 包裹，
     HKDF-SHA256 派生 → AES-GCM。同一 Apple ID 的任意设备可直接恢复，
     无需 PIN 或密码。
   - **v4（回退）** — PBKDF2-HMAC-SHA256、600 000 次迭代、16 字节随机
     salt → AES-256-GCM。用于用户没有 iCloud Keychain / 未配置 RK 的情况。

   这是实质性的安全升级，不只是重构：**iCloud Keychain 由 Apple 端到端
   加密**（密钥源自用户的 iCloud 安全码，Apple 无法读取），而 iCloud
   Drive 默认不是。威胁模型写在 `RecoveryKeyManager.swift` 头部注释。

- 「加密 QR 打印纸备份」这一条仍未实现。

### P3.2 多账户
- 一个分片管理多个 HD 派生账户

**部分达成——交付的功能与这条描述并不是一回事。**

`96f6c2d` 实现的是 `ShardsListView` 里的 `ShardAccount.group(_:)`：把
`accountId`（即 `groupPublicKey` 的十六进制）相同的钱包归并展示，于是
一次 DKG 产生的多条链（ETH + BTC + SOL）显示为单个「账户 N · X 条链」。
它们本来就共用同一份加密 key share 和同一个 party index，所以这是**展示
层的归并**。

而本条写的「HD 派生账户」需要 BIP32/44 派生能力——代码库里完全不存在：
Swift 侧和 `horcrux-core` 的 Rust 侧都搜不到任何 `m/44`、`derivationPath`、
`accountIndex` 或 bip32 相关实现。也就是说，用户无法从一份分片派生出
account 0 / 1 / 2 这样的多个独立账户。

若仍需要该能力，应作为独立事项重新立项，不要因为表格里打了勾而略过。

### P3.3 硬件钱包联动
- Ledger/Trezor 作为其中一个签名方

**未实现。** 这一项当初就不该计入「完成」：`96f6c2d` 交付的是 Settings
里一个带 "Coming soon" 徽章的条目加一段说明弹窗，没有任何签名能力。

而且那个占位入口现在**也已从 UI 移除**。残留的只有无人引用的死代码：

- `Utilities/L10n.swift` 的 `SettingsResidual.hwWalletTitle` /
  `hwWalletBody` / `hwWalletSubtitle` 与 `Settings.hardwareWallet`，
  没有任何 View 引用它们。
- `Resources/{en,zh-Hans}.lproj/Localizable.strings` 中对应的
  `settingsR.hwWallet*` / `settings.hardwareWallet` 条目。

其中 `settingsR.hwWalletBody` 的文案还在告诉用户「把第三个分片保存到
iCloud Drive 作为备份方案」——那条路径在 P3.1 换代时已经删除。因为这段
文案不再被渲染，用户看不到，所以不是线上问题；但它一旦被重新接上就会
误导人，清理时应连同上述死条目一并删除。

## P2 — 不实施
- WalletConnect、NFT、DApp 浏览器暂不纳入。

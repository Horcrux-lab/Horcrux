# Horcrux iOS App

SwiftUI-based iOS client for the Horcrux MPC threshold wallet.

## Prerequisites

- Xcode 16+ (Swift 6.0)
- Rust toolchain with iOS targets:
  ```bash
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim
  ```
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (for project regeneration)

## Build Steps

### 1. Build the Rust Core Library

```bash
cd ios
./build-rust.sh
```

This cross-compiles `horcrux-core` for iOS device and simulator, generates
Swift bindings via UniFFI, and creates an XCFramework.

### 2. Open in Xcode

```bash
open Horcrux.xcodeproj
```

Or regenerate the project from `project.yml`:
```bash
xcodegen generate
open Horcrux.xcodeproj
```

### 3. Build & Run

Select an iOS 17+ device or simulator and press ⌘R.

### 4. Run Tests

```bash
xcodebuild test \
  -project Horcrux.xcodeproj \
  -scheme Horcrux \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

## Relay Server

The app communicates with peers via a relay server for remote signing.

### Local development:
```bash
cd ../horcrux-relay
cargo run -- --port 8765
```
Then in the app, go to **Settings → Relay** and set the URL to `ws://localhost:8765`.

### Production:
Deploy `horcrux-relay` behind TLS (e.g., via nginx). The app defaults to `wss://` and will warn about `ws://` connections to non-localhost.

## Project Structure

```
ios/
├── build-rust.sh              # Cross-compile Rust → XCFramework
├── project.yml                # xcodegen project definition
├── Horcrux.xcodeproj/         # Generated Xcode project
├── Horcrux/
│   ├── App/                   # @main entry, app state, root navigation
│   ├── Core/
│   │   ├── Generated/         # UniFFI Swift bindings (auto-generated)
│   │   ├── HorcruxBridge.swift    # High-level Swift wrapper for Rust FFI
│   │   ├── BlockchainService.swift # On-chain RPC queries (ETH/BTC/SOL)
│   │   ├── WalletStore.swift      # Persistent wallet storage (JSON + Keychain)
│   │   ├── NetworkConfig.swift    # RPC endpoint config + mainnet/testnet presets
│   │   ├── TransactionStore.swift # TX history persistence
│   │   ├── TokenModels.swift      # ERC-20/SPL token definitions
│   │   ├── CeremonyStateManager.swift # MPC session resume after disconnect
│   │   ├── PendingBroadcastQueue.swift # Offline signing queue
│   │   ├── TransactionConfirmationPoller.swift # On-chain TX confirmation
│   │   ├── NotificationManager.swift # Local push notifications
│   │   └── DeepLinkRouter.swift   # horcrux:// URL scheme handler
│   ├── Features/
│   │   ├── Wallet/            # Wallet home, detail, balances, receive QR
│   │   ├── CreateShard/       # DKG ceremony flow (configure → discover → generate)
│   │   ├── Signing/           # Transaction signing + QR scanner
│   │   ├── Shards/            # Shard list, detail, backup/restore/import
│   │   └── Settings/          # PIN, biometric, relay, blockchain nodes
│   ├── Transport/             # Communication layer
│   │   ├── PeerManager        # Coordinates transports + Noise E2E + padding
│   │   ├── RelayTransport     # WebSocket to horcrux-relay (wss://)
│   │   ├── BLETransport       # CoreBluetooth
│   │   ├── WiFiDirectTransport # MultipeerConnectivity
│   │   ├── WiFiLANTransport   # Network.framework + Bonjour
│   │   └── QRTransport        # QR code exchange
│   ├── Security/              # Keychain, Secure Enclave, cert pinning, anti-debug
│   └── UI/                    # Reusable components, theme
└── HorcruxTests/              # Unit tests
```

## Architecture

The app follows MVVM with `@Observable` / `ObservableObject` patterns:

1. **HorcruxBridge** wraps the UniFFI-generated Rust bindings with Swift-native APIs
2. **PeerManager** abstracts transport (BLE/WiFi/Relay) + handles Noise E2E handshakes
3. **ViewModels** orchestrate MPC protocol rounds by sending/receiving via PeerManager
4. **Views** are pure SwiftUI with no direct FFI or transport access

All MPC computations happen in the Rust core — Swift only handles UI, transport I/O,
and message routing.

## Security

The app implements multiple layers of security:

- **Secure Enclave**: Device key sealed via ECIES (P-256 ECDH → AES-256-GCM)
- **PBKDF2 PIN**: 100k iterations HMAC-SHA256 with random salt
- **Brute-force protection**: Exponential backoff + wipe after 10 failed attempts
- **Noise Protocol**: E2E encrypted peer communication with stable identity
- **Certificate pinning**: SPKI SHA-256 + TOFU for custom endpoints
- **Anti-debug**: ptrace denial + sysctl + DYLD checks (release builds only)
- **Traffic padding**: Message bucket sizes + timing jitter to resist analysis
- **Auto-lock**: Configurable timeout + biometric unlock
- **Secure clipboard**: Auto-clears after 60 seconds

## Deep Linking

The app registers the `horcrux://` URL scheme:

```
horcrux://sign?session=<SESSION_ID>    # Join a signing session
horcrux://join?session=<SESSION_ID>    # Join a signing session
horcrux://tx?hash=<TX_HASH>            # View transaction details
horcrux://receive?address=<ADDR>&chain=ETH  # Show receive QR
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Build fails with "library not found" | Run `./build-rust.sh` first to compile Rust → XCFramework |
| Simulator crashes on Secure Enclave | Expected — SE is device-only, falls back to software Keychain |
| "No module named horcrux_core" | Ensure `SWIFT_INCLUDE_PATHS` includes `Core/Generated/` |
| Relay connection fails | Check relay URL in Settings; use `ws://` for localhost |
| Tests won't run | Regenerate project: `xcodegen generate` |

# Horcrux iOS App

SwiftUI-based iOS client for the Horcrux MPC wallet.

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

## Project Structure

```
ios/
├── build-rust.sh              # Cross-compile Rust → XCFramework
├── project.yml                # xcodegen project definition
├── Horcrux.xcodeproj/         # Generated Xcode project
└── Horcrux/
    ├── App/                   # @main entry, app state, root navigation
    ├── Core/
    │   ├── Generated/         # UniFFI Swift bindings (auto-generated)
    │   │   ├── horcrux_core.swift
    │   │   ├── horcrux_coreFFI.h
    │   │   └── horcrux_coreFFI.modulemap
    │   └── HorcruxBridge.swift  # High-level Swift wrapper
    ├── Features/
    │   ├── Wallet/            # Wallet home, detail, balances
    │   ├── CreateShard/       # DKG ceremony flow (configure → discover → generate)
    │   ├── Signing/           # Transaction signing flow
    │   ├── Shards/            # Shard list, detail, backup/restore
    │   └── Settings/          # PIN, biometric, relay config
    ├── Transport/             # Communication layer
    │   ├── TransportProtocol  # Abstract channel interface
    │   ├── BLETransport       # CoreBluetooth (BLE central + peripheral)
    │   ├── WiFiDirectTransport # MultipeerConnectivity (P2P)
    │   ├── WiFiLANTransport   # Network.framework + Bonjour
    │   ├── RelayTransport     # WebSocket to horcrux-relay
    │   ├── QRTransport        # QR code generation/scanning
    │   └── PeerManager        # Coordinates all transports + Noise E2E
    ├── Security/              # Keychain, biometrics
    └── UI/                    # Reusable components, theme
```

## Architecture

The app follows MVVM with `@Observable` / `ObservableObject` patterns:

1. **HorcruxBridge** wraps the UniFFI-generated Rust bindings with Swift-native APIs
2. **PeerManager** abstracts transport (BLE/WiFi/Relay) + handles Noise E2E handshakes
3. **ViewModels** orchestrate MPC protocol rounds by sending/receiving via PeerManager
4. **Views** are pure SwiftUI with no direct FFI or transport access

All MPC computations happen in the Rust core — Swift only handles UI, transport I/O,
and message routing.

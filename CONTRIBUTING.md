# Contributing to Horcrux

Thank you for your interest in contributing to Horcrux!

## Development Setup

### Prerequisites

- **Rust** 1.80+ (`rustup update stable`)
- **Xcode** 16+ (Swift 6.0) for iOS development
- **cargo-clippy** and **rustfmt** (included with Rust toolchain)

### Building

```bash
# Build the full workspace
cargo build --workspace

# Run all tests (expect 173+ passing)
cargo test --workspace

# Run clippy (expect 0 warnings)
cargo clippy --workspace --all-targets

# Format check
cargo fmt --check
```

### iOS App

```bash
cd ios
./build-rust.sh          # Cross-compile Rust → XCFramework
xcodegen generate        # Generate Xcode project
open Horcrux.xcodeproj   # Build & run (⌘R)
```

## Pull Request Process

1. **Fork** the repo and create a feature branch from `main`.
2. **Write tests** for any new functionality.
3. **Run the full test suite** before submitting:
   ```bash
   cargo test --workspace && cargo clippy --workspace --all-targets
   ```
4. **Keep commits atomic** — one logical change per commit.
5. **Write clear commit messages** following [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat(ios):` — new iOS feature
   - `fix(relay):` — relay bug fix
   - `security(rust):` — security hardening
   - `test(core):` — new tests
   - `docs:` — documentation changes

## Code Style

- **Rust**: Follow `rustfmt` defaults. Run `cargo fmt` before committing.
- **Swift**: Follow standard SwiftLint rules. Use `@MainActor` for UI state.
- **No force unwraps** (`!`) in production code — use `guard let` or `if let`.
- **Zero secrets** — any `Data` or `Vec<u8>` holding key material must be zeroed on drop.

## Security

If you discover a security vulnerability, please **do not** open a public issue.
Instead, email the maintainers directly. See [docs/security-model.md](docs/security-model.md).

## Architecture

See [docs/architecture.md](docs/architecture.md) for module layout and data flow.
Key crates:

| Crate | Purpose |
|-------|---------|
| `horcrux-core` | MPC protocols, chain tx builders, shard crypto, FFI bindings |
| `horcrux-relay` | WebSocket relay server (rooms, rate limiting, CORS) |
| `uniffi-bindgen` | Mobile binding generator |

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).

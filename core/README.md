# Portable core

`rust/` contains portable clock and lifecycle rules, transaction order, domain lists, encrypted state, website policy, active rule composition, and iOS timing and target limits. The Apple apps link its static library through Swift adapters in `ios/Shared/CoreBridge/` and `macos/Core/ProtectedPolicy.swift`. Native code supplies clocks, keys, storage, schedules, Family Controls tokens, and enforcement.

Run `cargo test --manifest-path core/rust/Cargo.toml --locked`. The lifecycle fixtures cover current macOS and iOS behavior, including their different handling of a full-unlock wait during a break.

State envelope v1 is JSON with `format`, `purpose`, and base64 `nonce`, `ciphertext`, and `tag`. Derive the 32-byte AES key from a 32-byte master key using HKDF-SHA256, salt `HardPause/state-key/v1`, and info `AES-256-GCM`. Use a 12-byte nonce, a 16-byte tag, and UTF-8 associated data `HardPause/state/v1/<purpose>`. Keys and rollback anchors stay outside the envelope.

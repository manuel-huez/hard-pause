# Shared Apple core

This Swift package contains deterministic policy decisions used by both Apple apps.

- `PauseCoreClock` advances a logical timeline only from a valid, same-boot elapsed-clock reading.
- `PauseCoreLifecycle` owns pending timeout, full-unlock, break, fixed-end, and natural-end precedence.
- `PauseCoreLifecycleProfile` keeps the existing platform difference: macOS leaves an open break in place during a full-unlock wait; iOS restores blocking.
- `PauseCoreTransactionPlan` defines schedule, durable intent, tightening, commit, cleanup, and relaxation order. Native runtimes execute these stages.
- `PortableDomainList` validates counted domain-only sources and the reviewed repository supplement.
- `PauseCoreEncryptedState` writes an AES-256-GCM state envelope. Mac storage uses it now; other systems can implement the same format with their own protected key store.

The macOS and iOS adapters keep their existing saved schemas. Storage, scheduling, Family Controls, Managed Settings, the macOS service, and enforcement stay native.

Run the shared fixtures with:

```sh
swift test --package-path core
```

This package serves the Apple apps. Windows and Android need separate portability work; this Swift package does not provide cross-platform binary reuse.

State envelope v1 is JSON with `format`, `purpose`, and base64 `nonce`, `ciphertext`, and `tag`. Derive the 32-byte AES key from a 32-byte master key using HKDF-SHA256, salt `HardPause/state-key/v1`, and info `AES-256-GCM`. Use a 12-byte nonce, a 16-byte tag, and UTF-8 associated data `HardPause/state/v1/<purpose>`. Keys and rollback anchors stay outside the envelope.

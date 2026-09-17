# Shared Apple core

This Swift package contains deterministic policy decisions used by both Apple apps.

- `PauseCoreClock` advances a logical timeline only from a valid, same-boot elapsed-clock reading.
- `PauseCoreLifecycle` owns pending timeout, full-unlock, break, fixed-end, and natural-end precedence.
- `PauseCoreLifecycleProfile` keeps the existing platform difference: macOS leaves an open break in place during a full-unlock wait; iOS restores blocking.
- `PauseCoreTransactionPlan` defines schedule, durable intent, tightening, commit, cleanup, and relaxation order. Native runtimes execute these stages.
- `PortableDomainList` validates counted domain-only sources and the reviewed repository supplement.

The macOS and iOS adapters keep their existing saved schemas. Storage, scheduling, Family Controls, Managed Settings, the macOS service, and enforcement stay native.

Run the shared fixtures with:

```sh
swift test --package-path core
```

This is the Apple implementation phase. A future Windows or Android port still needs the planned Rust core and bindings; this Swift package does not claim cross-platform binary reuse.

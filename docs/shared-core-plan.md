# Shared blocking core plan

Status: proposed implementation plan, 2026-09-14. This document does not change installed protection.

## Decision

Use Rust for the common block engine, transaction and recovery decisions, rule parsing, and portable data formats. Keep native interfaces: SwiftUI on Apple platforms, Kotlin on Android, and C#/WinUI on Windows. Windows is a proposed new target; its service will use Rust directly.

Use platform-specific Rust modules where practical, and small Swift/Kotlin adapters where the system APIs require them. Rust supports target-specific compilation through `cfg` and target-specific dependencies. Keep these conditions at adapter boundaries; do not create four versions of the block engine. [Rust reference](https://doc.rust-lang.org/reference/conditional-compilation.html).

Preserve the local-only product, native controls, existing mascot, and current prohibition on browser extensions, TLS interception, installed certificates, global proxies, accounts, and remote classification. No cross-device state sync is included. Each device owns its blocks. See [product and security decisions](../DESIGN.md).

Rust is the target because this plan includes four operating systems. A Swift package remains simpler for Apple-only work. Kotlin Multiplatform would still require Apple and Windows enforcement adapters; C++ would also need language bindings. Prove the Rust integration before replacing working Swift code. No percentage of shared code is promised.

## What moves, and what stays native

| Responsibility  | Common implementation                                                                          | Platform responsibility                                                                                |
| --------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Block lifecycle | One Rust state machine for activation, pending requests, breaks, natural end, and immutability | Present controls and submit commands                                                                   |
| Time            | Elapsed-time accounting, remaining durations, restart policy, next required transition         | Supply a sleep-inclusive monotonic reading and boot identity with a validity flag                      |
| Rules           | Validation, exact domains, IPs, URL patterns, immutable rule-set versions, overlap decisions   | Supply supported target types and implement their actual coverage                                      |
| Transactions    | Revisions, durable intent, tightening/commit/relaxation ordering, retry and recovery decisions | Execute bounded storage, scheduling, and enforcement operations                                        |
| Storage         | Versioned envelope, limits, consistency checks, migration validation                           | File ownership, access control, atomic replacement, durable flush, process locks, Apple token encoding |
| Scheduling      | Decide when work is due and when a break needs a reliable relock schedule                      | DeviceActivity, Android lifecycle services, or desktop service timers                                  |
| Enforcement     | Produce the required restrictions and track partial failures                                   | Screen Time, hosts/PF, WFP, process controls, VPN, and browser access                                  |
| Status          | Common phase/status/error codes and capability requirements                                    | Localized text, OS permission prompts, accessibility, and display formatting                           |
| Assets          | Existing mascot/fonts; common rule data where semantics match                                  | Native views and packaging                                                                             |

The existing Apple blocking engines are separate. `ios/Shared` currently serves the iOS app and extensions; macOS shares selected UI files and artwork only. Keep the current folder split, with a new Rust workspace:

```text
core/
  Cargo.toml
  crates/
    policy/          # deterministic types, rules, time, transitions
    runtime/         # transaction/recovery machine and effect protocol
    bindings/        # thin UniFFI facade for Swift and Kotlin
  fixtures/          # shared command traces and migration examples
ios/                 # SwiftUI, Screen Time adapters and extensions
macos/               # SwiftUI, XPC, existing service and enforcers
windows/             # Rust service, Windows adapters, native GUI and IPC
android/             # Kotlin UI, VPN/lifecycle/permission adapters
web/                 # static product site and existing shared artwork
```

Start with modules inside these crates. Add a crate only when it has a distinct dependency or build boundary. Share desktop file or rule-application helpers when both ports demonstrate the same contract; do not build a general platform framework first.

## Core contract

The policy engine has no filesystem, network, OS framework, ambient clock, or UI dependency. Given the same state, command, clock reading, and capability profile, it returns the same decision. Hosts supply identifiers and time; arithmetic uses checked integer durations. Legacy floating-point durations require an explicit conversion rule that never shortens a remaining wait.

The common types are:

- `BlockDraft`, immutable `Activation`, `PendingRequest`, and `BlockPhase`.
- `TargetRef`: a typed exact host, literal IP, URL pattern, or opaque platform target reference. An Apple selection is never converted into a guessed bundle identifier.
- `ClockReading`: monotonic elapsed units, boot identity, wall time for display/schedule projection, and trust/availability information.
- `CapabilityProfile`: target types, matching coverage, active-block/target limits, schedule support, and protection settings. Separate compiled support from current authorization/readiness.
- `Command`: create, update, delete, activate, request break, request full unlock, reconcile. Include an expected revision and an idempotency identifier for mutations.
- `Snapshot`: committed policy state, required restrictions, observed adapter status, pending work, and bounded errors. Required protection is not proof that protection is operating.

Opaque platform selections remain immutable, versioned native payloads. The saved transaction must bind their references and integrity metadata to the common state. A missing or invalid payload is a recovery error, never an empty selection. iOS may enforce a union through multiple named stores rather than flattening opaque tokens in Rust.

Keep unsupported targets distinct from malformed input. For example, a valid macOS URL path rule must not silently become a whole-domain iOS restriction. Adult filtering is also different: Apple's automatic filter and the Mac starter list are separate capabilities, not equivalent implementations of one Boolean.

## One transaction and recovery implementation

The Rust runtime is a resumable transaction machine. It issues bounded effects, and the trusted host executes them and returns typed outcomes. Platform code does not decide whether access may open. Use this separation instead of calling back into Swift/Kotlin while Rust holds a lock.

The normal sequence is:

1. Acquire the authoritative writer/process lock; load and validate state and unfinished intent. Reconcile elapsed time before evaluating a command.
2. Validate the command, immutable targets, revision, capabilities, and output limits. Calculate the candidate and conservative union of old/new restrictions.
3. Save durable intent before a new user-requested activation can be acknowledged. Establish any required schedule prerequisites; preserve or restore the prior schedules if preparation fails.
4. Apply added restrictions before committing any state that depends on them. Track each adapter outcome; one adapter succeeding does not mean the whole operation succeeded.
5. Save the candidate state durably. Only then remove restrictions that the committed state no longer requires, and only if required relock prerequisites still hold.
6. Record completion and clean up intent safely. Release the lock and return committed state plus any remaining enforcement failure.

Relocking an expired break is safety work: a storage failure must not prevent an available enforcer from restoring restrictions. A failed schedule restoration must close affected open breaks through the common recovery decision. Pin these cases with tests before choosing the final journal sequence; the two existing engines use different ordering details.

Every effect has an operation ID, transaction generation, and bounded result. Retries are idempotent. Stale receipts cannot complete a newer transition. On restart, re-read durable state and re-evaluate time before retrying; never replay an expired break-opening projection. Maintain recovery information until a crash can no longer cause stale intent to reopen access.

Only the authority executing adapters can supply outcomes. GUI IPC never accepts arbitrary snapshots, effect receipts, clock readings, or capability claims. Desktop services authenticate clients as they do today. iOS app and monitor extension each load the same library but serialize through one cross-process storage lock and journal; they are not independent in-memory authorities. A reported adapter success records the API outcome, not proof of complete OS enforcement.

Do not retry forever while holding a process lock. Bound work, persist retry state, and arrange the next wakeup. Preserve existing restrictions on unavailable storage or scheduling and report the failure. A core library cannot manufacture an OS wakeup or guarantee enforcement after permissions are revoked.

## Platform integration

| Platform | Integration and retained code                                                                                                                                                                                                                                       | Required proof                                                                                                                                                                                |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS    | Link Rust through Swift bindings inside the existing root service. Retain XPC authentication, native hosts/PF/process adapters and GUI browser monitoring initially. GUI and CLI remain clients. Share URL parsing with the GUI without giving it policy authority. | Current service and browser tests still pass; signed client rejection, owned-rule preservation, sleep/restart and crash recovery work on a test Mac.                                          |
| iOS      | Link the same Rust library into app and monitor extension. Keep FamilyControls selection, ManagedSettings, DeviceActivity, native token storage and file coordination. Shield extensions only link the core if they need its decisions.                             | Signed-device background transitions, schedule failure, concurrent app/extension activity, opaque-token round trips and extension resource use.                                               |
| Windows  | Rust service links policy/runtime directly. Use a native C#/WinUI client over bounded, versioned, authenticated local IPC with protected endpoints and caller checks. Windows network and app adapters stay separate.                                               | Prototype WFP filters, ownership/cleanup, service recovery and client authorization on a disposable machine. Choose app-close versus launch-prevention behavior before offering app blocking. |
| Android  | Kotlin calls Rust through bindings. A native service owns reconciliation; UI and background callbacks enter the same serialized runtime. A local VPN is the proposed consumer network route.                                                                        | Real-device VPN consent/revocation, restart, force-stop, battery/background behavior, existing VPN conflicts and network coverage. App blocking requires a separate capability gate.          |

Use UniFFI for Swift and Kotlin; these are officially supported languages. Pin generator and runtime versions together. Windows does not need unofficial C# UniFFI bindings: its GUI uses service IPC. Share the IPC schema and generated data types where useful, not service authority. [UniFFI guide](https://mozilla.github.io/uniffi-rs/).

FFI contracts use bounded records, explicit errors, stable ownership, and version checks. No borrowed pointers across calls or Rust panics unwinding into native code. Test error conversion, cancellation, object lifetime, Unicode, large inputs, and resource limits. Package an Apple XCFramework/Swift wrapper and Android ABI libraries/AAR from reproducible builds. Device and simulator builds must both be exercised.

Windows Filtering Platform provides network filtering by application/user/connection; it does not itself provide the complete app-launch policy. Evaluate Windows application-control APIs separately. Keep full browser URL paths unsupported until a permitted native mechanism is proved. [WFP](https://learn.microsoft.com/en-us/windows/win32/fwp/about-windows-filtering-platform), [Windows application control](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/).

Android supports one active VPN service per user/profile. VPN traffic control does not prevent offline app use. Strong package suspension belongs to device/profile management, with that scope and provisioning model. Default this plan to ordinary consumer installation; managed enrollment is a separate product decision. Do not add Accessibility-based interception as an assumed solution; assess actual coverage and distribution rules first. Network filtering must preserve the existing no-interception/no-remote-service boundary. [Android VPN](https://developer.android.com/develop/connectivity/vpn), [managed app restrictions](https://developer.android.com/work/dpc/security).

## Migration rules

Build fixtures from current behavior before porting. Do not choose macOS or iOS wholesale as the reference implementation: product invariants are common, but existing policies have different limits and representations.

| Current source                                                                                                 | Migration work                                                                                                                                                                                                                                                                     |
| -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `macos/Core/ProtectedBlock.swift`, `ios/Shared/LockState.swift`                                                | Extract common phases, immutable activations, overlap and natural-end precedence. macOS keeps a break open when full unlock is requested; iOS immediately resumes blocking. Preserve this through an explicit versioned policy field until a separate product decision unifies it. |
| `macos/Core/ProtectedRules.swift`, `ios/Shared/ElapsedTimeClock.swift`                                         | Common elapsed accounting; retain native clock readers until equivalent Rust readers are proved. Never count unknown reboot time toward unlock.                                                                                                                                    |
| `ios/Shared/LockPolicy.swift`, `macos/Core/ProtectedRules.swift`                                               | Preserve existing normalized target meaning. iOS strips `www.` today; macOS exact-host rules do not. New normalization cannot silently change saved active rules.                                                                                                                  |
| `ios/Shared/LocalLockRuntime.swift`, `macos/Service/ProtectedServiceEngine.swift`                              | Move ordering, recovery and retry decisions into the common runtime; keep OS effects native.                                                                                                                                                                                       |
| `ios/Shared/LockRepository.swift`, `RecoveryPolicyRepository.swift`, `macos/Service/ProtectedStateStore.swift` | Keep legacy decoders initially. Their schema-v2 formats are unrelated, and iOS collection revisions differ from macOS per-block revisions. Import through named source schemas under the authoritative lock; validate backup/intent recovery and native payload references.        |
| Platform tests                                                                                                 | Move common behavioral cases to reusable traces; retain native adapter and installed-device tests.                                                                                                                                                                                 |

Preserve iOS's current minimum waits/break lengths and 16-active-block limit, and macOS's current separate limits, through versioned profiles. Sharing an engine is not permission to change product timing. Existing activations retain their profile and frozen rule data; new policies can converge only through a separate product change.

First integrate the core with an empty test store. For existing installations, the first supported cutover occurs only after all blocks are inactive and old pending work is resolved. If active migration is needed later, require a separate tested importer that preserves IDs, revisions, frozen targets, remaining waits and recovery intent without a protection gap. Retain old files as protected evidence, not a second writable authority. Fence old processes and binaries out of writes after a schema/authority-generation change. Unsupported/corrupt schemas stop migration and keep current enforcement. Rollback is allowed only with a compatible reader and current state; never restore an older snapshot that changes an active commitment.

## Delivery sequence and acceptance gates

| Phase                    | Deliverable                                                                                                                        | Completion check                                                                                                                    |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 1. Contract and fixtures | Record current traces, differences, capabilities, transaction effects and clock contract.                                          | Every product invariant and known recovery case has a trace; differences are named and preserved.                                   |
| 2. Binding/build proof   | Minimal Rust policy call from macOS Swift, iOS app + extension, Android Kotlin and Windows service/IPC client. Fake adapters only. | Reproducible builds, error/ownership tests and measured startup, size and extension memory. Stop and revise bindings if this fails. |
| 3. Shared engine         | Implement policy, parsing, profiles, serialization and runtime effects with fake hosts.                                            | Differential tests against both Swift engines and crash/failure injection pass; no unexplained behavior differences.                |
| 4. macOS integration     | Replace policy/runtime decisions inside the service; preserve enforcers and XPC.                                                   | Existing native tests plus installed test-machine checks pass. Cut over inactive stores only.                                       |
| 5. iOS integration       | Replace duplicate policy/runtime code in app and monitor; preserve Screen Time adapters.                                           | Signed-device lifecycle/schedule/concurrency checks pass. No active-state reset or shortened wait.                                  |
| 6. Windows port          | Service, native UI, authenticated IPC and validated network adapter; app adapter only after its proof.                             | Install/update/restart/uninstall and coverage matrix pass on supported Windows versions.                                            |
| 7. Android port          | Native UI, local VPN and validated lifecycle adapter; advertise only proved target types.                                          | Physical-device background/permission/network tests pass and distribution requirements are reviewed.                                |
| 8. Remove duplication    | Delete superseded Swift decision engines after migration gates; retain importers while their schemas remain supported.             | All four targets call common policy/runtime implementations; native tests retain only platform-specific behavior.                   |

Windows/Android feasibility checks start in phase 2, before investing in complete ports. Phases 6 and 7 can run independently after the core contract is stable. No production service replacement is part of writing this plan.

## Tests and definition of shared

- Use one fixture format: starting state/profile, command/time sequence, injected effect failures, expected state, restriction set and effect order. Run it through Rust and language wrappers; use legacy Swift runners during migration.
- Test every transaction cut point: process death, partial enforcement, failed durable write, stale/duplicate command or receipt, missed wakeup, changed boot identity, corrupted state, missing native payload and unavailable relock schedule. Include overlapping blocks with simultaneous tightening and relaxation, delayed callbacks that skip a whole break, and rejected commands that must still perform due reconciliation.
- Add property tests for immutability, deterministic replay, no early unlock, bounded input and preservation of another block's restrictions. Fuzz decoding and URL/domain parsing. Validate IDN, IPv6, wildcard boundaries and legacy normalization.
- Run core checks on Linux, macOS and Windows. Build/link Android and Apple device/simulator artifacts. Keep signed-device and installed-service release checks separate from unit tests; mocks do not prove OS enforcement.
- Pin the Rust toolchain and dependencies, check formatting/lints/tests, verify generated bindings, and retain bounded failure logs. Measure CPU, memory, binary size, wakeups and state writes against current Apple baselines before choosing limits.
- A common behavior change should require one Rust implementation and one shared fixture change. UI wrappers may format outputs; they may not recalculate unlock eligibility. Review every new OS branch: capability/data difference belongs in profiles, system calls belong in adapters.
- Finish with a source ownership inventory: every remaining duplicate decision must have a platform reason. Do not use generated bindings, artwork size, or lines of code to inflate a reuse percentage.

The first implementation unit is phases 1–2: prove the contract and all four build paths with fake effects. This makes the language choice and integration cost reviewable before any installed enforcement changes.

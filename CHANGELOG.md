# Changelog

All notable changes to `swift-lifetime` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The unreleased redesign below is intentionally source-breaking and requires a
major release. The 1.0.0 entry describes the previous API.

## [Unreleased]

### Changed

- **Breaking:** The only product is now `Lifetime`, exposing five types:
  `Scope`, `LifetimeHandle`, noncopyable `Work<Value>`, passive
  `WorkResult<Value>`, and `ScopeError`.
- `Scope` is no longer a `LifetimeHandle`. Roots and immutable child creation
  define the tree; arbitrary scope adoption and reparenting are unavailable.
- Consuming adoption drains rejected work before throwing `ScopeError.closed`.
  `Scope.start` registers work before execution and rejects without launching.
- Cancellation closes the entire subtree atomically, cancels siblings
  concurrently, and makes every caller await the same completion. Dropping a
  child no longer loses its parent's ability to await cleanup.
- `Work` requests cancellation on deinit. Retaining its result observer does
  not retain cancellation ownership. Work and scope start inherit caller actor
  isolation, including the main actor.
- Known self-await cycles fail a precondition. `requestCancellation()` lets
  work initiate its own subtree's cancellation without awaiting itself.

### Removed

- All previous APIs except the redesigned `Scope` and `LifetimeHandle`,
  including resource/child wrappers and factories, task handles, continuation
  utilities, policies, snapshots, and supervision.
- `LifetimePrimitives`, `LifetimeBoundaries`, `LifetimePolicies`,
  `LifetimeIntent`, `LifetimeResources`, and `LifetimeSwiftUI`, including
  `DetachedOwnedWork`/`DetachedWork`, `ActorOwnedWork`, and `MainActorOwnedWork`.
- The benchmark executable and examples/tests for the removed API.

## 1.0.0 Initial open-source release.

### Added

- `CONTRIBUTING.md`, `SECURITY.md`, and this `CHANGELOG.md`.
- Seven library targets:
  - `Lifetime` — resource trees for Swift Concurrency: `Scope`,
    `Resource`, `Child`, factories, `Continuation`, `LifetimeHandle`,
    `TaskHandle`.
  - `LifetimePrimitives` — async-aware coordination primitives:
    `TokenBucket`, `AsyncSignal`, `AsyncBroadcaster`, `Subject`,
    `AsyncThrowingContinuation`, `DetachedOwnedWork`,
    `MainActorOwnedWork`, `ActorOwnedWork`.
  - `LifetimeBoundaries` — sync-to-async ownership at platform
    callback boundaries: `AsyncTaskRunner`, `MainActorTaskRunner`,
    `ReplacingTaskSlot`, `ScopeOwnedTask`,
    `ScopeOwnedThrowingTask`, `installTerminationHandler`,
    `awaitCancellation`, `deferToMainActor`.
  - `LifetimePolicies` — named, injectable scheduler boundaries:
    `AsyncSleeper`, `TaskSleeper`, `DelayPolicy`, `DebouncePolicy`,
    `PollingPolicy`, `RetryPolicy`, `RetryDelay`, `TimeoutPolicy`,
    `CooperativeYieldPolicy`, `withTimeout`.
  - `LifetimeIntent` — reducer-driven serialized executor:
    `IntentReducerExecutor`.
  - `LifetimeResources` — lazy resources and scope-shaped
    invalidation: `LazyValue`, `LazyResource`, `ResourceObserver`,
    `ResourceIsolation`, `ResourceState`, `ScopeInvalidator`.
  - `LifetimeSwiftUI` — `ComponentMount`, `MountedComponentView`,
    `MountInvalidatableComponent`.
- `LifetimeBenchmarks` executable with regression thresholds for
  five core operations.
- `.spi.yml` declaring all seven library targets for Swift Package
  Index documentation hosting.

### Requirements

- Swift 6.2+ in Swift 6 language mode.
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+.

[Unreleased]: https://github.com/GoodHatsLLC/swift-lifetime/compare/1.0.0...HEAD
[1.0.0]: https://github.com/GoodHatsLLC/swift-lifetime/releases/tag/1.0.0

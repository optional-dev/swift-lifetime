# swift-lifetime

Track asynchronous work in a tree and await cancellation of any subtree.

The package vends one product, `Lifetime`, with five public types:

| Type | Purpose |
| --- | --- |
| `Scope` | A reference to a tree node; creates children and owns leaf registrations. |
| `LifetimeHandle` | The contract `borrowing func cancel() async`: request cancellation and await all represented work and cleanup. |
| `Work<Value>` | A noncopyable, deferred operation consumed when a scope starts it. |
| `WorkResult<Value>` | A copyable result observer that carries no cancellation ownership. |
| `ScopeError` | `.closed`, thrown when a scope cannot admit a child or work. |

This is an intentionally breaking redesign. The previous satellite products and
all other APIs have been removed; see [CHANGELOG.md](CHANGELOG.md).

## Installation

Requires Swift 6.2+, Swift 6 language mode, and macOS 15+, iOS 18+, tvOS 18+,
or watchOS 11+. Linux is supported. There are no package dependencies.

The new API is unreleased. Pin a revision containing it, or track `main` while
evaluating the redesign:

```swift
.package(url: "https://github.com/GoodHatsLLC/swift-lifetime.git", branch: "main")
```

Add `.product(name: "Lifetime", package: "swift-lifetime")` to your target.
The 1.0.0 tag contains the previous API.

## Start tracked work

```swift
import Lifetime

let app = Scope.root(name: "app")
let screen = try app.child(name: "screen")
let greeting = try screen.start(name: "greeting") { "Hello" }
print(try await greeting.value)

await screen.cancel()  // Joins all work and cleanup in this subtree.
await app.cancel()
```

`start` registers the operation before it can execute. A closed scope throws
without invoking the operation. It returns a passive observer; ignoring or
retaining that observer does not affect the work's lifetime. Finished `start`
registrations are released automatically.

Both `Work` construction and inline `Scope.start` preserve the caller's actor
isolation. Call them from a `@MainActor` function for main-actor work, or from
another actor for work on that actor. Task locals and the default priority are
inherited from the caller that starts the work. An explicit `priority:` supplied
at construction is preserved. There is no separate main-actor work type or public
detached-task wrapper.

Operations use Swift's `sending` checks: non-Sendable captures may be transferred
exclusively or shared within one actor, but cannot remain concurrently accessible
from another isolation domain.

Observe errors through `WorkResult.value`. Cancellation waits for completion
without rethrowing an operation's error. Swift cancellation is cooperative:
operations must respond to cancellation and await all their structured children
and asynchronous cleanup before returning.

## Prepare work separately

Construct and pass around work before choosing its scope. Construction stores the
operation without creating or scheduling a task. Starting consumes the value, so
each `Work` can be started only once.

```swift
let scope = Scope.root()
func prepareAnswer() -> Work<Int> {
  Work { 42 }
}

let work = prepareAnswer()  // Nothing is scheduled yet.
let result = try scope.start(consume work, name: "answer")
print(try await result.value)
await scope.cancel()
```

Dropping unstarted work discards its operation and releases its captures without
invoking it. Starting in a closed scope consumes and discards the work, throwing
`.closed` without creating a task. Both forms of `start` register before scheduling
and automatically release finished registrations.

`Work` has no `result` or `cancel()` and does not conform to `LifetimeHandle`.
Obtain the result observer from `scope.start`, and use the scope to cancel running
work. Retaining an observer does not keep the scope alive. Dropping the scope
requests cancellation but cannot await completion; use `await scope.cancel()`
when completion matters.

Deferred work retains its original operation's actor isolation even when another
actor starts it. Task locals, such as tracing context, come from the start call,
not the construction call. Captured values are retained at construction time;
deferring execution does not defer evaluating capture expressions.

## Adopt external work

Use `try await scope.adopt(handle)` to transfer cancellation ownership of an
external `LifetimeHandle`. Adoption does not start or activate the handle. If the
scope is closed, adoption cancels **and drains** the supplied handle before
throwing `.closed`. A rejected registration is not part of the tree; its adopting
caller owns that drain until the call returns.

Unlike `start`, generic adoption retains its handle until scope cancellation,
because `LifetimeHandle` has no independent completion notification. Use
`scope.start(work)` for deferred `Work` values; they cannot be adopted, including
through generic forwarding functions.

## Tree and cancellation rules

- Only `Scope.root` and `scope.child` create nodes. Parentage never changes.
  `Scope` does not conform to `LifetimeHandle`, so `scope.adopt(scope)` does not
  compile. There is no arbitrary scope adoption, detachment, or reparenting.
- Cancelling a scope permanently closes it and all descendants to admission.
  A concurrent registration is either included or rejected. Siblings outside
  the subtree remain open.
- Sibling work is cancelled concurrently. Repeated and concurrent `cancel()`
  calls join the same completion. Cancelling a waiting caller does not make
  that caller return before cleanup completes.
- Keep public scope references for as long as their subtrees should live.
  Dropping the last reference requests subtree cancellation. A parent stores
  a child's internal completion records, not a reference to its public handle.
  Dropping a child therefore requests cancellation, and the parent can still
  await its cleanup. Dropping a root cancels even retained descendants.
- From **inside** a subtree, use `scope.requestCancellation()`. Awaiting
  `scope.cancel()` there would wait for the caller itself. Detected self-await
  cycles fail a precondition instead of hanging. Await `cancel()` from outside
  the target subtree.

For example, this is valid:

```swift
let result = try scope.start {
  scope.requestCancellation()
  return "shutdown requested"
}
// Outside the operation:
await scope.cancel()
```

The operation may be skipped with `CancellationError` if cancellation wins the
startup race.

## Custom leaf work

```swift
public protocol LifetimeHandle: Sendable, ~Copyable {
  borrowing func cancel() async
}
```

A conformer must initiate cancellation when needed and return only when **all**
represented work and cleanup has finished. Concurrent/repeated calls must join
the same completion, even if cancellation started independently. A cancelled
calling task must still wait. Conformers may also cancel themselves or cancel
on deinit; neither changes this contract.

The protocol permits reference types and copyable values as well as noncopyable
values. It cannot prove a custom implementation's semantics or prevent aliases
of the same underlying operation. Register each logical leaf once. Do not use a
custom handle to wrap/reparent a scope or create dependencies that await their
own subtree. `Work` enforces a single transfer into a scope through noncopyability;
custom conformers are responsible for their own ownership rules.

The guarantees cover faithfully represented work. Untracked `Task` instances,
unawaited side effects, dependency cycles between leaves, and operations that
ignore cancellation cannot be repaired by a scope. Likewise, deinit runs only
when the owner is actually released: an operation retaining its own scope can
keep it alive. Use explicit awaited cancellation at lifecycle boundaries.

## Development

```sh
swift build
swift test
swift test -c release
python3 Scripts/check-api.py
swift format lint --recursive --strict Sources Tests Package.swift
```

Tests use deterministic gates for teardown ordering and subprocesses for
self-await preconditions. Compile checks verify consuming ownership and the
absence of scope adoption. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[docs/internals.md](docs/internals.md).

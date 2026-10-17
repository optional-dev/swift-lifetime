# swift-lifetime

Track asynchronous work in a tree and await cancellation of any subtree.

The package vends one product, `Lifetime`, with six public types:

| Type | Purpose |
| --- | --- |
| `Scope` | A reference to a tree node; creates children and owns leaf registrations. |
| `LifetimeHandle` | The contract `borrowing func cancel() async`: request cancellation and await all represented work and cleanup. |
| `CompletingLifetimeHandle` | A `LifetimeHandle` that adds `borrowing func wait() async`: await natural completion without cancelling. |
| `Work<Value>` | A noncopyable, deferred operation consumed when a scope starts it. |
| `WorkResult<Value>` | A copyable result observer that carries no cancellation ownership. |
| `ScopeError` | `.closed`, thrown when a scope cannot admit a child or work. |

This is an intentionally breaking redesign. The previous satellite products and
all other APIs have been removed; see [CHANGELOG.md](CHANGELOG.md).

## Installation

Requires Swift 6.4+, Swift 6 language mode, and macOS 27+, iOS 27+, tvOS 27+,
or watchOS 27+. These minimums support async `defer` and task cancellation
shields. Linux is supported. There are no package dependencies.

Add the package dependency:

```swift
.package(url: "https://github.com/optional-dev/swift-lifetime.git", from: "4.0.0")
```

Add `.product(name: "Lifetime", package: "swift-lifetime")` to your target.
The 3.x releases retain the previous Swift and platform requirements.

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

## Clean up after cancellation

Use async `defer` with `withTaskCancellationShield` for teardown that must run
even when the operation's task has been cancelled. Async `defer` keeps cleanup
inside the operation's lifetime; the shield prevents cancellation-sensitive
cleanup from immediately throwing or returning early because the task is
cancelled. Async `defer` alone does not shield cancellation. These features are
provided by [SE-0493](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0493-defer-async.md)
and [SE-0504](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0504-task-cancellation-shields.md).

Keep resource acquisition, use, and teardown together in a named async function.
For example, assuming the application supplies `openSession()` and the session
has a nonthrowing async `close()`:

```swift
@MainActor
func runSession() async throws {
  let session = try await openSession()
  defer {
    await withTaskCancellationShield {
      await session.close()
    }
  }

  try await session.run()
}

let scope = Scope.root(name: "session")
let result = try scope.start {
  try await runSession()
}

// At the lifecycle boundary, outside the operation:
await scope.cancel()  // Also waits for session.close().
```

Use the actor isolation appropriate for the resource; `@MainActor` is only an
example. The same function can be called from a deferred `Work` operation.

- Cleanup runs on success, error, and cancellation after acquisition succeeds.
  Acquiring inside the operation avoids creating resources if startup is skipped.
- Both `cancel()` and `finish()` wait for the operation's cleanup. Cancellation
  still requires the operation to cooperate and return or throw before its
  `defer` runs.
- Shield only teardown. Shielding the entire operation can prevent it from
  responding to the scope's cancellation request. Keep cleanup awaited; a
  fire-and-forget `Task` in `defer` would outlive the tracked operation.
- `defer` cannot propagate a cleanup error. Handle throwing teardown explicitly
  inside the shield, or use a resource-management function that defines how to
  combine operation and cleanup failures. Observe operation errors through
  `result.value`; `scope.cancel()` does not rethrow them.

Local testing with Apple Swift 6.4 (Xcode 27.0) found an actor-isolation issue
with async `defer` inside actor-isolated closures: an actor assertion could fail
when entering the defer. This also reproduced with plain `Task`, independently
of Lifetime. Moving the defer into a named actor-isolated async function, as
above, avoided the failure. Treat this as a toolchain-specific workaround, not
an intended difference between functions and closures.

The same testing observed an outer cancellation handler being skipped when
cancellation arrived during a shield. Keep teardown independent of cancellation
callbacks; waiting for one to release shielded cleanup can hang.

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

A plain `LifetimeHandle` has no completion notification, so generic adoption
retains it until scope cancellation. Conform to `CompletingLifetimeHandle` to
add `wait()`; the scope then releases the handle as soon as its work finishes
and awaits it, rather than cancelling it, during `finish()`. Use
`scope.start(work)` for deferred `Work` values; they cannot be adopted, including
through generic forwarding functions.

## Tree and cancellation rules

- Only `Scope.root` and `scope.child` create nodes. Parentage never changes.
  `Scope` does not conform to `LifetimeHandle`, so `scope.adopt(scope)` does not
  compile. There is no arbitrary scope adoption, detachment, or reparenting.
- Cancelling or finishing a scope permanently closes it and all descendants to
  admission. A concurrent registration is either included or rejected. Siblings
  outside the subtree remain open.
- Finishing lets admitted work complete on its own. Cancellation escalates a
  finishing subtree; `finish()` and `cancel()` callers await the same completion.
- Sibling work is cancelled concurrently. Repeated and concurrent `cancel()`
  calls join the same completion. Cancelling a waiting caller does not make
  that caller return before cleanup completes.
- Keep public scope references for as long as their subtrees should live.
  Dropping the last reference requests subtree cancellation. A parent stores
  a child's internal completion records, not a reference to its public handle.
  Dropping a child therefore requests cancellation, and the parent can still
  await its cleanup. Dropping a root cancels even retained descendants.
- From **inside** a subtree, use `scope.requestCancellation()` or
  `scope.close()`. Awaiting `scope.cancel()` or `scope.finish()` there would
  wait for the caller itself. Detected self-await cycles fail a precondition
  instead of hanging. Await `cancel()` and `finish()` from outside the target
  subtree.

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

## Structured scopes

`withChild` and `Scope.withRoot` bind a scope to a block. The scope is cancelled
and fully drained before the call returns or rethrows, so work started inside
cannot outlive the block. If the calling task is cancelled, the child's subtree
is requested to cancel while the block keeps running; a task that is already
cancelled receives a closed child.

```swift
try await app.withChild(name: "request") { request in
  let user = try request.start { try await loadUser() }
  let posts = try request.start { try await loadPosts() }
  return try await (user.value, posts.value)
}
// Everything started in `request` has finished here, even on error.
```

`withChild` throws `ScopeError.closed` without running the block when the
parent is closed. `withRoot` rethrows only the block's own error type, so a
non-throwing block needs no `try`. Await `finish()` inside the block to let
started work complete instead of cancelling it on exit.

## Finish without cancelling

`finish()` closes a subtree to new work and awaits what is already running.
`close()` is its synchronous counterpart: it closes admission without waiting,
and is safe to call from inside the subtree.

```swift
let accept = try server.child(name: "accept")
let requests = try server.child(name: "requests")
// ...
await accept.cancel()    // Stop producing new requests.
await requests.finish()  // Let in-flight requests complete.
await server.cancel()
```

Started work and `CompletingLifetimeHandle` leaves finish on their own. Plain
`LifetimeHandle` leaves cannot report completion, so `finish()` cancels them.
A later `cancel()`, `requestCancellation()`, or dropped scope escalates a
finishing subtree to cancellation; every waiting caller then joins the same
completion. `isClosed` reports whether a scope is finishing or cancelling. It is
advisory: admission itself is decided atomically by `child`, `start`, and `adopt`.

## Custom leaf work

```swift
public protocol LifetimeHandle: Sendable, ~Copyable {
  borrowing func cancel() async
}

public protocol CompletingLifetimeHandle: LifetimeHandle, ~Copyable {
  borrowing func wait() async
}
```

A conformer must initiate cancellation when needed and return only when **all**
represented work and cleanup has finished. Concurrent/repeated calls must join
the same completion, even if cancellation started independently. A cancelled
calling task must still wait. Conformers may also cancel themselves or cancel
on deinit; neither changes this contract.

`wait()` has the same completion contract without requesting cancellation. A
scope calls it to observe natural completion and during `finish()`; it may run
more than once and concurrently with `cancel()`. The scope calls `cancel()` at
most once per registration.

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

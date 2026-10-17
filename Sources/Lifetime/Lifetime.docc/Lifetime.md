# ``Lifetime``

Track asynchronous work in a tree and await cancellation of any subtree.

## Overview

Requires Swift 6.4+ and macOS 27+, iOS 27+, tvOS 27+, or watchOS 27+.
Linux is also supported. Async `defer` and task cancellation shields are
available on all supported platforms.

Create a ``Scope`` root and immutable children, or bind one to a block with
``Scope/withRoot(name:_:)`` and ``Scope/withChild(name:_:)``. Register work with
``Scope/start(name:inheriting:priority:operation:)``, start a separately prepared
``Work`` with ``Scope/start(_:name:)``, or transfer an external
``LifetimeHandle`` using ``Scope/adopt(_:name:)``. Scopes are structural nodes;
handles are leaf work. A scope cannot be adopted as a handle.

```swift
let app = Scope.root(name: "app")
let screen = try app.child(name: "screen")
let result = try screen.start { 42 }
print(try await result.value)
await screen.cancel()
await app.cancel()
```

Cancellation permanently closes the subtree and concurrently cancels its work.
Every ``Scope/cancel()`` caller awaits the same completion, including cleanup
already started by a dropped child. Calling-task cancellation does not shorten
that wait. A rejected start never invokes its operation; rejected adoption
cancels and drains its supplied work before throwing ``ScopeError/closed``.

``Scope/finish()`` closes a subtree without cancelling and awaits the work
already running; ``Scope/close()`` closes admission synchronously. Started work
and ``CompletingLifetimeHandle`` leaves complete on their own, while plain
handles are cancelled because their completion cannot be observed. A later
cancellation or dropped scope escalates a finishing subtree, and all callers
join one completion. ``Scope/isClosed`` is an advisory view of that state.

A structured scope is cancelled and drained when its block returns or throws.
Cancellation of the calling task requests cancellation of the block's scope
while the block keeps running.

``Work`` is a noncopyable deferred operation. Construction creates no task;
dropping unstarted work discards it without invocation. Starting consumes the work
and returns a ``WorkResult`` observer. Work has no standalone result or
cancellation method and cannot be adopted as a ``LifetimeHandle``.

The operation preserves the actor isolation of its construction context. Task
locals and default priority come from the caller that starts it; an explicit
priority supplied at construction is preserved. Both forms of start automatically
release completed registrations. Result observers do not keep the scope alive.
Use awaited scope cancellation when completion matters.

Keep public scope handles alive while their subtrees should run. Dropping a scope
requests subtree cancellation, even when descendants retain their own handles.
Finished start registrations and completing handles are released automatically;
plain adoption retains its handle until cancellation because ``LifetimeHandle``
has no completion observer.

Use ``Scope/requestCancellation()`` or ``Scope/close()`` inside a subtree.
Awaiting its cancellation or completion there would wait for the caller itself;
detected cycles fail a precondition. Await ``Scope/cancel()`` and
``Scope/finish()`` from outside the target subtree.

The guarantees require cooperative operations and faithful handle conformers
that await all represented work and cleanup. Custom handles must not register
aliases of the same logical work or wrap scopes into cycles. Untracked tasks,
unawaited effects, arbitrary dependency cycles, and retained ownership cycles
are outside the contract.

## Topics

### Tree ownership

- ``Scope``
- ``ScopeError``

### Leaf work

- ``LifetimeHandle``
- ``CompletingLifetimeHandle``
- ``Work``
- ``WorkResult``

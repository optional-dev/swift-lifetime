# ``Lifetime``

Track asynchronous work in a tree and await cancellation of any subtree.

## Overview

Create a ``Scope`` root and immutable children. Register work with
``Scope/start(name:inheriting:priority:operation:)`` or transfer a
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

``Work`` is a noncopyable owner that requests task cancellation on deinit.
``WorkResult`` observes its result without keeping that owner alive. Deinit
requests cancellation but cannot await cleanup: use awaited cancellation when
completion matters. Work and scope start inherit the caller's actor isolation.

Keep public scope handles alive while their subtrees should run. Dropping a scope
requests subtree cancellation, even when descendants retain their own handles.
Finished start registrations are released automatically; generic adoption retains
its handle until cancellation because the protocol has no completion observer.

Use ``Scope/requestCancellation()`` inside a subtree. Awaiting its cancellation
there would wait for the caller itself; detected cycles fail a precondition.
Await cancellation from outside the target subtree.

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
- ``Work``
- ``WorkResult``

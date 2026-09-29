# ``Lifetime``

Track asynchronous work in a tree and await cancellation of any subtree.

## Overview

Create a ``Scope`` root and immutable children. Register work with
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

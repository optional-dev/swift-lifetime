# Cancellation implementation

The public surface consists of `Scope`, `LifetimeHandle`,
`CompletingLifetimeHandle`, `Work`, `WorkResult`, and `ScopeError`. All
machinery described below is internal.

## Ownership

A public `Scope` holds a `ScopeTree` and its `ScopeNode`. The tree stores internal
nodes and leaf registrations, never public scope handles. Nodes have immutable
ancestry, unique identity tokens, and a one-shot completion cell.

A parent therefore keeps a child's completion awaitable without preventing the
child handle's deinit. Root deinit closes all descendants, including children
whose public handles remain live. Completed nodes are removed from the tree;
a surviving handle keeps its resolved completion cell and remains closed.

`Work` is a noncopyable, Sendable struct holding a deferred operation and optional
priority. It creates no task and has no result or cancellation API. A mutex stores
the transferred, potentially non-Sendable closure until a consuming start takes
it out exactly once. Discarding unstarted work simply releases its captures.

Only after scope admission succeeds does start create an internal `RunningWork`
cancellation owner holding a Swift task and work identity. Its deinit requests
task cancellation synchronously. `WorkResult` holds the task and identity without
holding the owner or public scope, keeping completion observable after scope
destruction without extending cancellation ownership.

Operation parameters use `sending`, `@isolated(any)`, and
`@_inheritActorContext`, following Swift's task entry-point conventions. The
transfer check prevents callers from continuing to access non-Sendable captures
from a different isolation domain. Actor inheritance preserves safe sharing on
the caller's actor. An isolated parameter alone does not enforce that transfer
boundary when its value is nil; compile fixtures cover both safe and unsafe use.
Actor isolation remains attached to the deferred closure. Task creation inherits
task locals and default priority from the start caller, while explicit priority
comes from the deferred work. No task is created merely to wait for attachment.

Adoption captures the consumed handle in one immutable, sendable closure that
dispatches a leaf action: cancel, or wait for completion. The closure borrows
the handle for either. A plain handle has no completion notification, so its
registration maps waiting onto cancellation and the scope retains it until
closure. A `CompletingLifetimeHandle` registration forwards waiting to `wait()`,
and adoption then spawns the same detached completion observer that `start`
uses, releasing the registration while its scope is still open. `RunningWork`
is a completing handle whose `wait()` awaits its task result. `Work` does not
conform to `LifetimeHandle`, preventing direct or generic adoption of an
operation that requires activation.

A registration runs cancellation at most once; later cancel callers join that
completion through a `Once`. Waiting is not memoized, because each waiting
caller must record its own ancestry for cycle detection (see below).

## Admission and closure

One mutex protects every registration and node phase in a tree. Each node is
open, finishing, or cancelling. Closing a subtree iteratively marks every open
descendant finishing or cancelling under that lock. This is the linearization
point: a racing child/work registration is either already in the snapshot or is
rejected. No user callback runs under the lock.

Each newly closed node gets exactly one driver, independent of the requesting
task's cancellation. A cancelling driver concurrently cancels its leaves; a
finishing driver concurrently waits for them. Either driver also waits for every
child's completion, including children already draining. Only after all those
waits finish does it resolve the node's completion and remove its tree entry.
Every public `cancel()` and `finish()` caller waits on that same completion.

A finishing node keeps its leaf registrations in its entry. Cancelling a
subtree that contains finishing nodes escalates them: under the lock each
becomes cancelling and gives up its leaves, and a detached escalation task then
cancels those leaves. The finishing driver's pending waits return as the leaves
finish, so escalation resolves nothing itself and no second completion exists.
A `Scope` deinit requests cancellation, so dropping a finishing scope escalates.

Inline `start` constructs a deferred `Work` and forwards to the consuming overload.
That overload registers a placeholder before creating its task. If closure
races with task creation, the placeholder waits until the handle is installed,
then drives it. Rejection creates no task. A completed registration can be
removed only while its scope is open; closing transfers it to the driver so
completion observation cannot discard a drain in progress.

`withChild` and `withRoot` run their block in the caller's task inside a task
cancellation handler that requests cancellation of the block's scope. After the
block returns or throws, the call awaits `cancel()` on that scope and only then
returns the block's outcome. The block's error type is preserved through a typed
`Result`; `withChild` additionally throws `ScopeError.closed` when child
creation is rejected, so it is untyped.

`AsyncCell` is an internal cancellation-insensitive one-shot rendezvous. It
resumes continuations outside its mutex. Tree removals likewise retain removed
values until outside the lock so handle deinits cannot reenter a locked tree.

## Self-await detection

Each operation runs with a task-local work identity. `Scope.cancel()` and
`Scope.finish()` record which node that work is awaiting. Each driver and
escalation task supplies its node's ancestry as a task local; both
`RunningWork.cancel()` and `RunningWork.wait()` record that ancestry on the work
identity. All updates share a mutex, so a self-await is detected regardless of
which update happens first, including subtree closure before the task handle is
installed. The detached completion observer waits with empty ancestry, which is
why waiting is never memoized across callers.

Handle callbacks directly awaiting their own subtree and work awaiting its own
result also fail preconditions. Work may instead synchronously close or request
cancellation of its subtree. These checks do not attempt to prove arbitrary
custom-handle correctness or detect all dependency cycles between leaves.

## Validation

Tests cover deferred construction and discard, consuming start, scope deinit with
observers retained, subtree closure, teardown already in progress,
cancelled/concurrent callers, reentrant cancellation handlers, preserved actor
isolation, start-time task locals and priority, pending registration, admission
races, structured child cleanup, and release of completed work. Finishing tests
cover natural completion without cancellation, admission races against
`finish()`, escalation by `cancel()` and by deinit, escalation of one child
while its parent finishes, plain handles cancelled by `finish()`, completing
handles awaited and released early, single cancellation per registration, and
mixed `finish()`/`cancel()` callers joining one completion. Structured tests
cover drain on return and throw, rejection without running the block, caller
cancellation propagation, already-cancelled callers, and typed rethrowing. Exit
tests check both orderings of self-await detection for cancellation and
finishing. Compile fixtures reject scope/task/work adoption, pre-start result
observation, duplicate ownership, and reuse of consumed work, while accepting
factories, consuming forwarding functions, completing handles, and non-throwing
structured blocks without `try`.

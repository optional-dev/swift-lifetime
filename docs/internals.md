# Cancellation implementation

The public surface consists of `Scope`, `LifetimeHandle`, `Work`, `WorkResult`,
and `ScopeError`. All machinery described below is internal.

## Ownership

A public `Scope` holds a `ScopeTree` and its `ScopeNode`. The tree stores internal
nodes and leaf registrations, never public scope handles. Nodes have immutable
ancestry, unique identity tokens, and a one-shot completion cell.

A parent therefore keeps a child's completion awaitable without preventing the
child handle's deinit. Root deinit closes all descendants, including children
whose public handles remain live. Completed nodes are removed from the tree;
a surviving handle keeps its resolved completion cell and remains closed.

`Work` is a noncopyable struct holding a Swift task and a work identity. Deinit
requests task cancellation synchronously. `WorkResult` holds the task and
identity without holding the owner. This keeps results observable after adoption
or owner destruction without extending cancellation ownership.

Operation parameters use `sending`, `@isolated(any)`, and
`@_inheritActorContext`, following Swift's task entry-point conventions. The
transfer check prevents callers from continuing to access non-Sendable captures
from a different isolation domain. Actor inheritance preserves safe sharing on
the caller's actor. An isolated parameter alone does not enforce that transfer
boundary when its value is nil; compile fixtures cover both safe and unsafe use.

Generic adoption captures the consumed handle in an immutable, sendable
cancellation closure. The closure borrows the handle when cancelling. A generic
handle has no independent completion notification, so adoption retains it until
cancellation. `start` additionally uses an internal task-completion observer to
release naturally finished registrations while their scope remains open.

## Admission and cancellation

One mutex protects every registration and node phase in a tree. Closing a subtree
iteratively marks every open descendant closed under that lock. This is the
linearization point: a racing child/work registration is either already in the
snapshot or is rejected. No user cancellation callback runs under the lock.

Each newly closed node gets exactly one cancellation driver, independent of the
requesting task's cancellation. The driver concurrently cancels its leaves and
waits for every child's completion, including children already draining. Only
after all those waits finish does it resolve the node's completion and remove
its tree entry. Every public `cancel()` caller waits on that same completion.

`start` registers a placeholder before creating its task. If cancellation races
with task creation, the placeholder waits until the handle is installed, then
cancels and drains it. Rejection creates no task. A completed registration can
be removed only while its scope is open; closing transfers it to the driver so
completion observation cannot discard a drain in progress.

`AsyncCell` is an internal cancellation-insensitive one-shot rendezvous. It
resumes continuations outside its mutex. Tree removals likewise retain removed
values until outside the lock so handle deinits cannot reenter a locked tree.

## Self-await detection

Each operation runs with a task-local work identity. Scope cancellation records
which node that work is awaiting. Each leaf cancellation driver supplies its
node's ancestry as a task local; `Work.cancel()` records that ancestry on the
work identity. Both updates share a mutex, so a self-await is detected regardless
of which update happens first. This also handles `Work` behind a generic custom
wrapper without adding requirements to `LifetimeHandle`.

Cancellation callbacks directly awaiting their own subtree and work awaiting
its own result also fail preconditions. Work may instead synchronously request
its subtree's cancellation. These checks do not attempt to prove arbitrary
custom-handle correctness or detect all dependency cycles between leaves.

## Validation

Tests cover ownership transfer, deinit fallback with observers retained,
subtree closure, teardown already in progress, cancelled/concurrent callers,
reentrant cancellation handlers, actor isolation, pending registration, admission
races, structured child cleanup, and release of completed work. Exit tests check
both orderings of self-await detection. Compile fixtures reject scope/task
adoption, duplicate ownership, and reuse of consumed work.

/// Work whose cancellation can be requested and awaited to completion.
///
/// Conformers must make repeated and concurrent calls join the same teardown.
/// Returning means all represented work has finished, including any asynchronous
/// cleanup. Cancellation of the calling task must not shorten that wait.
///
/// Work may finish or begin cancelling independently. A conformer need not cancel
/// on deinitialization. Both copyable and noncopyable conformers are supported;
/// callers must not register aliases of the same logical work as separate leaves.
///
/// A scope cannot observe when a plain handle finishes on its own. It retains
/// the handle until cancellation and cancels it during ``Scope/finish()``.
/// Conform to ``CompletingLifetimeHandle`` when completion is observable.
public protocol LifetimeHandle: Sendable, ~Copyable {
  /// Requests cancellation if needed and waits until the represented work finishes.
  borrowing func cancel() async
}

/// Work whose natural completion can be awaited without requesting cancellation.
///
/// A scope releases a completing handle as soon as its work finishes, instead
/// of retaining it until cancellation, and awaits it rather than cancelling it
/// during ``Scope/finish()``. Like `cancel()`, `wait()` returns only when all
/// represented work and cleanup has finished, must tolerate repeated and
/// concurrent calls alongside `cancel()`, and must not be shortened by
/// cancellation of the calling task.
public protocol CompletingLifetimeHandle: LifetimeHandle, ~Copyable {
  /// Waits until the represented work finishes, without requesting cancellation.
  borrowing func wait() async
}

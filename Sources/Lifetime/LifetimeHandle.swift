/// Work whose cancellation can be requested and awaited to completion.
///
/// Conformers must make repeated and concurrent calls join the same teardown.
/// Returning means all represented work has finished, including any asynchronous
/// cleanup. Cancellation of the calling task must not shorten that wait.
///
/// Work may finish or begin cancelling independently. A conformer need not cancel
/// on deinitialization. Both copyable and noncopyable conformers are supported;
/// callers must not register aliases of the same logical work as separate leaves.
public protocol LifetimeHandle: Sendable, ~Copyable {
  /// Requests cancellation if needed and waits until the represented work finishes.
  borrowing func cancel() async
}

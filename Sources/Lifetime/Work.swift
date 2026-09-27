/// A unique cancellation owner for an asynchronous operation.
///
/// Dropping this value synchronously requests task cancellation. Use ``cancel()``
/// or adopt it into a ``Scope`` to also await completion. The operation must
/// cooperate with cancellation and await all work and cleanup it starts.
public struct Work<Value: Sendable>: LifetimeHandle, ~Copyable {
  private let task: Task<Value, any Error>
  private let identity: WorkIdentity

  /// Starts an operation, inheriting the caller's actor isolation and task locals.
  ///
  /// The task checks for cancellation before invoking the operation.
  /// The operation's value or error is available through ``result``.
  public init(
    inheriting isolation: isolated (any Actor)? = #isolation,
    priority: TaskPriority? = nil,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Value
  ) {
    let identity = WorkIdentity()
    self.identity = identity
    task = Task(priority: priority) {
      _ = isolation
      return try await CancellationContext.$ancestors.withValue([]) {
        try await CancellationContext.$work.withValue(identity) {
          try Task.checkCancellation()
          return try await operation()
        }
      }
    }
  }

  /// An observer that does not keep this cancellation owner alive.
  public var result: WorkResult<Value> {
    WorkResult(task: task, identity: identity)
  }

  /// Requests cancellation and waits for the operation and its cleanup to finish.
  ///
  /// Concurrent and repeated calls all await task completion. The calling task's
  /// cancellation does not shorten the wait. An operation cannot await its own
  /// completion, directly or through cancellation of an owning scope.
  public borrowing func cancel() async {
    precondition(CancellationContext.work !== identity, "Work cannot await its own cancellation.")
    identity.recordCancellation(in: CancellationContext.ancestors)
    task.cancel()
    _ = await task.result
  }

  deinit {
    task.cancel()
  }
}

/// A copyable, passive observer of a ``Work`` operation's eventual value or error.
///
/// Keeping an observer does not prevent cancellation when the work owner is
/// dropped. Cancelling an observer's awaiting task does not cancel the operation
/// or stop awaiting its result.
public struct WorkResult<Value: Sendable>: Sendable {
  let task: Task<Value, any Error>
  let identity: WorkIdentity

  /// Waits for the operation, returning its value or throwing its error.
  public var value: Value {
    get async throws {
      precondition(CancellationContext.work !== identity, "Work cannot await its own result.")
      return try await task.value
    }
  }
}

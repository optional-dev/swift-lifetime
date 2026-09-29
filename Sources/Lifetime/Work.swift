import Synchronization

/// A deferred, single-use asynchronous operation.
///
/// Construction does not create a task. Pass this value to ``Scope/start(_:name:)``
/// to register and schedule it, or drop it to discard the operation. Work cannot
/// be adopted as a ``LifetimeHandle``. The operation must cooperate with
/// cancellation and await all work and cleanup it starts.
public struct Work<Value: Sendable>: Sendable, ~Copyable {
  // A sending closure need not be Sendable. The mutex permits transferring it
  // into storage, across callers, and finally into exactly one task.
  private let operation: Mutex<(@isolated(any) () async throws -> Value)?>
  private let priority: TaskPriority?
  private let identity: WorkIdentity

  /// Prepares an operation, preserving the caller's actor isolation.
  ///
  /// Task locals and the default priority are inherited when a scope starts the
  /// work, not when it is constructed. An explicit priority is preserved.
  public init(
    inheriting isolation: isolated (any Actor)? = #isolation,
    priority: TaskPriority? = nil,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Value
  ) {
    let identity = WorkIdentity()
    self.identity = identity
    self.priority = priority
    // Preserve isolation for the cancellation check as well as the operation.
    // Only the body is prepared here; launch creates the task after admission.
    self.operation = Mutex {
      _ = isolation
      return try await CancellationContext.$ancestors.withValue([]) {
        try await CancellationContext.$work.withValue(identity) {
          try Task.checkCancellation()
          return try await operation()
        }
      }
    }
  }

  consuming func launch() -> RunningWork<Value> {
    let operation = operation.withLock { stored in
      let operation = stored!
      stored = nil
      return operation
    }
    return RunningWork(priority: priority, identity: identity, operation: operation)
  }
}

/// A copyable, passive observer of a ``Work`` operation's eventual value or error.
///
/// Obtained by starting work in a ``Scope``. Keeping an observer does not keep
/// the scope alive. Cancelling an observer's awaiting task does not cancel the
/// operation or stop awaiting its result.
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

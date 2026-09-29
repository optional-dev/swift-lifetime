// Only Scope.start creates this cancellation owner, after admission succeeds.
struct RunningWork<Value: Sendable>: LifetimeHandle, ~Copyable {
  let task: Task<Value, any Error>
  let identity: WorkIdentity

  init(
    priority: TaskPriority?,
    identity: WorkIdentity,
    operation: sending @escaping @isolated(any) () async throws -> Value
  ) {
    self.identity = identity
    task = Task(priority: priority, operation: operation)
  }

  var result: WorkResult<Value> { WorkResult(task: task, identity: identity) }

  borrowing func cancel() async {
    precondition(CancellationContext.work !== identity, "Work cannot await its own cancellation.")
    identity.recordCancellation(in: CancellationContext.ancestors)
    task.cancel()
    _ = await task.result
  }

  deinit { task.cancel() }
}

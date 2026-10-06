/// An error registering a child or work in a scope.
public enum ScopeError: Error, Equatable {
  /// The scope or one of its ancestors is closed to new children and work
  /// because it is finishing or cancelling.
  case closed
}

/// A node in a tree whose work can be cancelled and awaited as a subtree.
///
/// Create roots with ``root(name:)`` and children with ``child(name:)``. Parentage
/// is immutable; scopes cannot be adopted as work. Dropping the last reference to
/// a scope requests cancellation of its subtree, even if child scopes survive.
/// A parent retains its children's completion records, not their public handles.
public final class Scope: Sendable {
  /// A diagnostic name with no effect on ownership or cancellation.
  public let name: String?

  private let tree: ScopeTree
  private let node: ScopeNode

  private init(name: String?, tree: ScopeTree, node: ScopeNode) {
    self.name = name
    self.tree = tree
    self.node = node
  }

  /// Creates an independent tree root.
  public static func root(name: String? = nil) -> Scope {
    let node = ScopeNode(ancestors: [])
    let tree = ScopeTree(root: node)
    return Scope(name: name, tree: tree, node: node)
  }

  /// Creates a root, runs `body` with it, then cancels and awaits its subtree.
  ///
  /// The root is cancelled and fully drained before this call returns or
  /// rethrows. Cancellation of the calling task requests cancellation of the
  /// root while `body` keeps running. See ``withChild(name:_:)``.
  public static func withRoot<Value, Failure: Error>(
    name: String? = nil,
    _ body: (Scope) async throws(Failure) -> Value
  ) async throws(Failure) -> Value {
    try await root(name: name).enclosing(body)
  }

  /// Whether this subtree is closed to new children and work.
  ///
  /// The answer is advisory: a concurrent closure can follow immediately.
  /// Admission itself is decided atomically by ``child(name:)``,
  /// ``start(name:inheriting:priority:operation:)``, and ``adopt(_:name:)``.
  public var isClosed: Bool { tree.isClosed(node) }

  /// Creates and registers a child, or throws if this subtree is closed.
  ///
  /// Retain the returned scope for as long as it should remain active. Its last
  /// reference being dropped requests cancellation of that child's subtree.
  public func child(name: String? = nil) throws(ScopeError) -> Scope {
    let child = try tree.addChild(to: node)
    return Scope(name: name, tree: tree, node: child)
  }

  /// Creates a child, runs `body` with it, then cancels and awaits its subtree.
  ///
  /// The child is cancelled and fully drained before this call returns or
  /// rethrows, so work started in it cannot outlive `body`. Await
  /// ``finish()`` inside `body` to let that work complete instead. If the
  /// calling task is cancelled, the child's subtree is requested to cancel
  /// while `body` keeps running; a task that is already cancelled receives a
  /// closed child. Throws ``ScopeError/closed`` without running `body` if this
  /// scope is closed.
  public func withChild<Value>(
    name: String? = nil,
    _ body: (Scope) async throws -> Value
  ) async throws -> Value {
    try await child(name: name).enclosing(body)
  }

  /// Transfers a leaf's cancellation ownership into this scope.
  ///
  /// The scope retains the handle until cancellation. If admission is closed,
  /// this call cancels and fully drains the supplied work before throwing.
  /// Copyable conformers must not be aliased into multiple registrations.
  /// Use ``start(_:name:)`` for deferred ``Work`` values.
  public func adopt<Handle: LifetimeHandle & ~Copyable>(
    _ handle: consuming Handle,
    name: String? = nil
  ) async throws(ScopeError) {
    let registration = WorkRegistration(name: name)
    registration.install(consume handle)
    try await admit(registration)
  }

  /// Transfers a completing leaf's cancellation ownership into this scope.
  ///
  /// The scope releases the handle once its work finishes, and ``finish()``
  /// awaits it instead of cancelling it. If admission is closed, this call
  /// cancels and fully drains the supplied work before throwing.
  public func adopt<Handle: CompletingLifetimeHandle & ~Copyable>(
    _ handle: consuming Handle,
    name: String? = nil
  ) async throws(ScopeError) {
    let registration = WorkRegistration(name: name)
    registration.install(consume handle)
    try await admit(registration)
    releaseOnCompletion(registration)
  }

  /// Registers and starts work, returning a passive result observer.
  ///
  /// Registration precedes execution. A rejected start never invokes the
  /// operation. Completed work is automatically released by the scope.
  /// The operation inherits the caller's actor isolation and task locals.
  public func start<Value: Sendable>(
    name: String? = nil,
    inheriting isolation: isolated (any Actor)? = #isolation,
    priority: TaskPriority? = nil,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Value
  ) throws(ScopeError) -> WorkResult<Value> {
    try start(Work(inheriting: isolation, priority: priority, operation: operation), name: name)
  }

  /// Consumes deferred work, registering it before scheduling its operation.
  ///
  /// Rejection throws without creating a task and discards the operation.
  /// Completed work is automatically released by the scope. The operation keeps
  /// its original actor isolation; task locals and the default priority come
  /// from this call. The result observer does not keep the scope alive.
  public func start<Value: Sendable>(
    _ work: consuming Work<Value>,
    name: String? = nil
  ) throws(ScopeError) -> WorkResult<Value> {
    let registration = WorkRegistration(name: name)
    guard tree.insert(registration, into: node) else { throw .closed }
    let running = work.launch()
    let result = running.result
    registration.install(consume running)
    releaseOnCompletion(registration)
    return result
  }

  /// Closes this subtree to new work without cancelling, and without waiting.
  ///
  /// Running work continues and may finish on its own. This is safe to call
  /// from work inside the subtree. Use ``finish()`` from outside the subtree
  /// when completion must be awaited.
  public func close() {
    tree.close(node, cancelling: false)
  }

  /// Closes this subtree and initiates cancellation without waiting.
  ///
  /// This is safe to call from work inside the subtree. Use ``cancel()`` from
  /// outside the subtree when completion must be awaited.
  public func requestCancellation() {
    tree.close(node, cancelling: true)
  }

  /// Closes this subtree to new work and awaits what is already running.
  ///
  /// Started work and ``CompletingLifetimeHandle`` leaves finish on their own.
  /// Plain ``LifetimeHandle`` leaves cannot report completion and are cancelled.
  /// A later ``cancel()`` or dropped scope escalates to cancellation; every
  /// caller then awaits the same completion. Cancellation of the calling task
  /// does not shorten the wait.
  ///
  /// Do not call this from work or handle callbacks within the targeted subtree:
  /// that would wait for the caller itself. Library-controlled cycles fail a
  /// precondition; use ``close()`` from inside the subtree.
  public func finish() async {
    await awaitClosure(cancelling: false)
  }

  /// Closes this subtree, requests cancellation, and awaits all tracked cleanup.
  ///
  /// Repeated and concurrent calls join the same completion, including cleanup
  /// initiated by a child's deinitialization or by ``finish()``. Cancellation of
  /// the calling task does not shorten the wait. Siblings are cancelled
  /// concurrently.
  ///
  /// Do not call this from work or cancellation callbacks within the targeted
  /// subtree: that would wait for the caller itself. Library-controlled cycles
  /// fail a precondition; use ``requestCancellation()`` from inside the subtree.
  public func cancel() async {
    await awaitClosure(cancelling: true)
  }

  deinit {
    tree.close(node, cancelling: true)
  }

  private func awaitClosure(cancelling: Bool) async {
    precondition(
      !CancellationContext.ancestors.contains(node.token),
      "A handle callback cannot await its own subtree. Use requestCancellation() or close()."
    )
    let work = CancellationContext.work
    work?.beginWaiting(for: node.token)
    defer { work?.endWaiting(for: node.token) }
    tree.close(node, cancelling: cancelling)
    await node.completion.wait()
  }

  private func admit(_ registration: WorkRegistration) async throws(ScopeError) {
    guard tree.insert(registration, into: node) else {
      await registration.cancel()
      throw .closed
    }
  }

  // Finished work is released while its scope is open; a closed scope's driver
  // already owns the registration and releases it with the node.
  private func releaseOnCompletion(_ registration: WorkRegistration) {
    let tree = tree
    let node = node
    Task.detached {
      await registration.wait()
      tree.removeFinished(registration, from: node)
    }
  }

  // Runs body in the caller's task, then cancels and drains this scope.
  private func enclosing<Value, Failure: Error>(
    _ body: (Scope) async throws(Failure) -> Value
  ) async throws(Failure) -> Value {
    let outcome = await withTaskCancellationHandler {
      do throws(Failure) {
        return Result<Value, Failure>.success(try await body(self))
      } catch {
        return .failure(error)
      }
    } onCancel: {
      requestCancellation()
    }
    await cancel()
    return try outcome.get()
  }
}

/// An error registering a child or work in a scope.
public enum ScopeError: Error, Equatable {
  /// The scope or one of its ancestors has begun cancellation.
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

  /// Creates and registers a child, or throws if this subtree is closed.
  ///
  /// Retain the returned scope for as long as it should remain active. Its last
  /// reference being dropped requests cancellation of that child's subtree.
  public func child(name: String? = nil) throws(ScopeError) -> Scope {
    let child = try tree.addChild(to: node)
    return Scope(name: name, tree: tree, node: child)
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
    guard tree.insert(registration, into: node) else {
      await registration.cancel()
      throw .closed
    }
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
    let tree = tree
    let node = node
    Task.detached {
      _ = await result.task.result
      tree.removeFinished(registration, from: node)
    }
    return result
  }

  /// Closes this subtree and initiates cancellation without waiting.
  ///
  /// This is safe to call from work inside the subtree. Use ``cancel()`` from
  /// outside the subtree when completion must be awaited.
  public func requestCancellation() {
    tree.requestCancellation(of: node)
  }

  /// Closes this subtree, requests cancellation, and awaits all tracked cleanup.
  ///
  /// Repeated and concurrent calls join the same completion, including cleanup
  /// initiated by a child's deinitialization. Cancellation of the calling task
  /// does not shorten the wait. Siblings are cancelled concurrently.
  ///
  /// Do not call this from work or cancellation callbacks within the targeted
  /// subtree: that would wait for the caller itself. Library-controlled cycles
  /// fail a precondition; use ``requestCancellation()`` from inside the subtree.
  public func cancel() async {
    precondition(
      !CancellationContext.ancestors.contains(node.token),
      "A cancellation callback cannot await its own subtree. Use requestCancellation()."
    )
    let work = CancellationContext.work
    work?.beginWaiting(for: node.token)
    defer { work?.endWaiting(for: node.token) }
    tree.requestCancellation(of: node)
    await node.completion.wait()
  }

  deinit {
    tree.requestCancellation(of: node)
  }
}

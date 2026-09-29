import Synchronization
import Testing

@testable import Lifetime

@Suite(.timeLimit(.minutes(1)))
struct ScopeTests {
  @Test func subtreeCancellationLeavesSiblingAndParentOpen() async throws {
    let root = Scope.root(name: "root")
    let child = try root.child(name: "child")
    let grandchild = try child.child()
    let sibling = try root.child()
    let left = WorkEvents()
    let right = WorkEvents()
    let leftResult = try grandchild.start { await left.run() }
    let rightResult = try sibling.start { await right.run() }
    await left.started.wait()
    await right.started.wait()
    child.requestCancellation()
    await left.cancelled.wait()
    #expect(!right.cancelled.isOpen)
    #expect(throws: ScopeError.closed) { try grandchild.child() }
    #expect(throws: ScopeError.closed) { try child.start { 1 } }
    left.release.open()
    await child.cancel()
    #expect(left.finished.isOpen)
    #expect(try await leftResult.value)
    let another = try root.child()
    #expect(root.name == "root")
    #expect(child.name == "child")
    #expect(!right.cancelled.isOpen)
    right.release.open()
    await root.cancel()
    #expect(try await rightResult.value)
    await another.cancel()
    await grandchild.cancel()
    await sibling.cancel()
  }

  @Test func startConsumesNoncopyableWorkAndRetainsOwnership() async throws {
    let scope = Scope.root()
    let events = WorkEvents()
    let work = Work { await events.run() }
    let observer = try scope.start(consume work, name: "deferred")
    await events.started.wait()
    #expect(!events.cancelled.isOpen)
    events.release.open()
    await scope.cancel()
    #expect(try await observer.value)
    #expect(events.finished.isOpen)
  }

  @Test func rejectedAdoptionDrainsBeforeThrowing() async throws {
    let scope = Scope.root()
    await scope.cancel()
    let leaf = Leaf()
    let rejection = Task {
      do {
        try await scope.adopt(leaf)
        Issue.record("A closed scope accepted work")
      } catch {
        #expect(error as? ScopeError == .closed)
        #expect(leaf.finished.isOpen)
      }
    }
    await leaf.entered.wait()
    #expect(!leaf.finished.isOpen)
    leaf.release.open()
    await rejection.value
  }

  @Test func rejectedStartNeverInvokesOperation() async {
    let root = Scope.root()
    let invoked = Gate()
    root.requestCancellation()
    #expect(throws: ScopeError.closed) {
      try root.start { invoked.open() }
    }
    await root.cancel()
    #expect(!invoked.isOpen)
  }

  @Test func droppingChildDoesNotLoseParentsAbilityToAwaitCleanup() async throws {
    let root = Scope.root()
    let events = WorkEvents()
    var child: Scope? = try root.child()
    weak let weakChild = child
    let observer = try #require(child).start { await events.run() }
    await events.started.wait()
    child = nil
    #expect(weakChild == nil)
    await events.cancelled.wait()
    let parentCancellation = Task {
      await root.cancel()
      #expect(events.finished.isOpen)
    }
    #expect(!events.finished.isOpen)
    events.release.open()
    await parentCancellation.value
    #expect(try await observer.value)
  }

  @Test func droppingRootCancelsRetainedDescendants() async throws {
    var root: Scope? = Scope.root()
    weak let weakRoot = root
    let child = try #require(root).child()
    let events = WorkEvents()
    let result = try child.start { await events.run() }
    await events.started.wait()
    root = nil
    #expect(weakRoot == nil)
    #expect(throws: ScopeError.closed) { try child.child() }
    await events.cancelled.wait()
    events.release.open()
    await child.cancel()
    #expect(try await result.value)
    #expect(events.finished.isOpen)
  }

  @Test func siblingsBeginCancellationConcurrently() async throws {
    let root = Scope.root()
    let child = try root.child()
    let first = Leaf()
    let second = Leaf()
    try await root.adopt(first)
    try await child.adopt(second)
    let cancellation = Task { await root.cancel() }
    await first.entered.wait()
    await second.entered.wait()
    #expect(!first.finished.isOpen)
    #expect(!second.finished.isOpen)
    first.release.open()
    second.release.open()
    await cancellation.value
    #expect(first.finished.isOpen)
    #expect(second.finished.isOpen)
  }

  @Test func concurrentCancelCallersJoinOneDrain() async throws {
    let root = Scope.root()
    let leaf = Leaf()
    try await root.adopt(leaf)
    let allStarted = Gate()
    let count = Counter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<32 {
        group.addTask {
          if count.increment() == 32 {
            allStarted.open()
          }
          await root.cancel()
          #expect(leaf.finished.isOpen)
        }
      }
      await allStarted.wait()
      await leaf.entered.wait()
      #expect(!leaf.finished.isOpen)
      leaf.release.open()
    }
    #expect(leaf.calls.withLock { $0 } == 1)
    await root.cancel()
    #expect(leaf.finished.isOpen)
    #expect(leaf.calls.withLock { $0 } == 1)
  }

  @Test func cancelledCallerStillDrainsSubtree() async throws {
    let root = Scope.root()
    let leaf = Leaf()
    try await root.adopt(leaf)
    let proceed = Gate()
    let caller = Task {
      await proceed.wait()
      #expect(Task.isCancelled)
      await root.cancel()
      #expect(leaf.finished.isOpen)
    }
    caller.cancel()
    proceed.open()
    await leaf.entered.wait()
    leaf.release.open()
    await caller.value
    #expect(leaf.finished.isOpen)
  }

  @Test func workCanRequestItsOwnSubtreeCancellation() async throws {
    let root = Scope.root()
    let events = WorkEvents()
    let other = try root.start { await events.run() }
    await events.started.wait()
    let requester = try root.start {
      root.requestCancellation()
      return 42
    }
    #expect(try await requester.value == 42)
    await events.cancelled.wait()
    events.release.open()
    await root.cancel()
    #expect(try await other.value)
  }

  @Test func workCanAwaitCancellationOfADifferentSubtree() async throws {
    let root = Scope.root()
    let target = try root.child()
    let leaf = Leaf()
    try await target.adopt(leaf)
    let caller = try root.start {
      await target.cancel()
      return leaf.finished.isOpen
    }
    await leaf.entered.wait()
    leaf.release.open()
    #expect(try await caller.value)
    await root.cancel()
  }

  @Test func synchronousCancellationHandlerCanReenterScope() async throws {
    let root = Scope.root()
    let entered = Gate()
    let cancelled = Gate()
    let result = try root.start {
      await withTaskCancellationHandler {
        entered.open()
        await cancelled.wait()
      } onCancel: {
        root.requestCancellation()
        cancelled.open()
      }
    }
    await entered.wait()
    await root.cancel()
    try await result.value
    #expect(cancelled.isOpen)
  }

  @Test @MainActor func startInheritsActorAndLocals() async throws {
    let root = Scope.root()
    try await Local.$value.withValue(23) {
      var actorValue = 0
      let result = try root.start {
        MainActor.assertIsolated()
        actorValue += 1
        return actorValue + Local.value
      }
      #expect(try await result.value == 24)
    }
    await root.cancel()
  }

  @Test(arguments: [false, true])
  func finishedStartReleasesItsResultWhileScopeRemainsOpen(deferred: Bool) async throws {
    let root = Scope.root()
    let released = Gate()
    func startAndObserve() async throws {
      let result: WorkResult<DeinitSignal>
      if deferred {
        let work = Work { DeinitSignal(released) }
        result = try root.start(consume work)
      } else {
        result = try root.start { DeinitSignal(released) }
      }
      _ = try await result.value
    }
    try await startAndObserve()
    await released.wait()
    let stillOpen = try root.child()
    await root.cancel()
    await stillOpen.cancel()
  }
}

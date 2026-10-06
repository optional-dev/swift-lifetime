import Synchronization
import Testing

@testable import Lifetime

@Suite(.timeLimit(.minutes(1)))
struct FinishTests {
  @Test func finishAwaitsRunningWorkWithoutCancelling() async throws {
    let root = Scope.root()
    let child = try root.child()
    let events = WorkEvents()
    let result = try child.start { await events.runUntilReleased() }
    await events.started.wait()
    let finishing = Task {
      await root.finish()
      #expect(events.finished.isOpen)
    }
    events.release.open()
    await finishing.value
    #expect(!events.cancelled.isOpen)
    #expect(try await result.value == false)
    #expect(root.isClosed)
    #expect(child.isClosed)
    #expect(throws: ScopeError.closed) { try root.child() }
    #expect(throws: ScopeError.closed) { try child.start { 1 } }
    await child.cancel()
    await root.cancel()
  }

  @Test func closeRejectsNewWorkWhileRunningWorkContinues() async throws {
    let root = Scope.root()
    let events = WorkEvents()
    let result = try root.start { await events.runUntilReleased() }
    await events.started.wait()
    root.close()
    #expect(root.isClosed)
    #expect(throws: ScopeError.closed) { try root.start { 1 } }
    #expect(throws: ScopeError.closed) { try root.child() }
    #expect(!events.cancelled.isOpen)
    #expect(!events.finished.isOpen)
    events.release.open()
    #expect(try await result.value == false)
    await root.finish()
    #expect(events.finished.isOpen)
  }

  @Test func finishLeavesSiblingAndParentOpen() async throws {
    let root = Scope.root()
    let child = try root.child()
    let sibling = try root.child()
    let events = WorkEvents()
    let result = try sibling.start { await events.runUntilReleased() }
    await events.started.wait()
    await child.finish()
    #expect(child.isClosed)
    #expect(!root.isClosed)
    #expect(!sibling.isClosed)
    #expect(!events.cancelled.isOpen)
    _ = try root.child()
    events.release.open()
    #expect(try await result.value == false)
    await root.cancel()
  }

  @Test func cancelEscalatesAFinishingSubtree() async throws {
    let root = Scope.root()
    let child = try root.child()
    let events = WorkEvents()
    let result = try child.start { await events.runUntilReleased() }
    await events.started.wait()
    root.close()
    let finishing = Task { await root.finish() }
    #expect(!events.cancelled.isOpen)
    let cancelling = Task { await root.cancel() }
    await events.cancelled.wait()
    #expect(!events.finished.isOpen)
    events.release.open()
    await finishing.value
    await cancelling.value
    #expect(events.finished.isOpen)
    #expect(try await result.value)
  }

  @Test func cancellingAChildWhileItsParentFinishesEscalatesOnlyThatSubtree() async throws {
    let root = Scope.root()
    let left = try root.child()
    let right = try root.child()
    let leftEvents = WorkEvents()
    let rightEvents = WorkEvents()
    let leftResult = try left.start { await leftEvents.runUntilReleased() }
    let rightResult = try right.start { await rightEvents.runUntilReleased() }
    await leftEvents.started.wait()
    await rightEvents.started.wait()
    root.close()
    let finishing = Task { await root.finish() }
    let cancelling = Task { await left.cancel() }
    await leftEvents.cancelled.wait()
    #expect(!rightEvents.cancelled.isOpen)
    leftEvents.release.open()
    await cancelling.value
    #expect(try await leftResult.value)
    #expect(!rightEvents.cancelled.isOpen)
    rightEvents.release.open()
    await finishing.value
    #expect(try await rightResult.value == false)
  }

  @Test func droppingAFinishingScopeEscalatesToCancellation() async throws {
    var scope: Scope? = Scope.root()
    weak let weakScope = scope
    let events = WorkEvents()
    let result = try #require(scope).start { await events.runUntilReleased() }
    await events.started.wait()
    scope?.close()
    #expect(!events.cancelled.isOpen)
    scope = nil
    #expect(weakScope == nil)
    await events.cancelled.wait()
    events.release.open()
    #expect(try await result.value)
  }

  @Test func finishCancelsHandlesThatCannotReportCompletion() async throws {
    let root = Scope.root()
    let leaf = Leaf()
    try await root.adopt(leaf)
    let finishing = Task { await root.finish() }
    await leaf.entered.wait()
    #expect(!leaf.finished.isOpen)
    leaf.release.open()
    await finishing.value
    #expect(leaf.finished.isOpen)
    await root.cancel()
    #expect(leaf.calls.withLock { $0 } == 1)
  }

  @Test func finishAwaitsCompletingHandlesWithoutCancelling() async throws {
    let root = Scope.root()
    let leaf = CompletingLeaf()
    try await root.adopt(leaf)
    let finishing = Task {
      await root.finish()
      #expect(leaf.finished.isOpen)
      #expect(!leaf.cancelled.isOpen)
    }
    await leaf.waited.wait()
    #expect(!leaf.finished.isOpen)
    leaf.release.open()
    await finishing.value
    await root.cancel()
    #expect(leaf.cancelCalls.withLock { $0 } == 0)
  }

  @Test func finishThenCancelCancelsACompletingHandleOnce() async throws {
    let root = Scope.root()
    let leaf = CompletingLeaf()
    try await root.adopt(leaf)
    root.close()
    let finishing = Task { await root.finish() }
    let cancelling = Task { await root.cancel() }
    await leaf.cancelled.wait()
    #expect(!leaf.finished.isOpen)
    leaf.release.open()
    await finishing.value
    await cancelling.value
    #expect(leaf.finished.isOpen)
    await root.cancel()
    #expect(leaf.cancelCalls.withLock { $0 } == 1)
  }

  @Test func concurrentFinishAndCancelCallersJoinOneCompletion() async throws {
    let root = Scope.root()
    let leaf = Leaf()
    try await root.adopt(leaf)
    let allStarted = Gate()
    let count = Counter()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<32 {
        group.addTask {
          if count.increment() == 32 {
            allStarted.open()
          }
          if index.isMultiple(of: 2) {
            await root.finish()
          } else {
            await root.cancel()
          }
          #expect(leaf.finished.isOpen)
        }
      }
      await allStarted.wait()
      await leaf.entered.wait()
      #expect(!leaf.finished.isOpen)
      leaf.release.open()
    }
    #expect(leaf.calls.withLock { $0 } == 1)
  }

  @Test func finishOfACompletedScopeReturnsImmediately() async {
    let root = Scope.root()
    await root.cancel()
    await root.finish()
    #expect(root.isClosed)
    root.close()
    await root.finish()
  }

  @Test func workMayCloseItsOwnScopeAndLetSiblingsFinish() async throws {
    let root = Scope.root()
    let events = WorkEvents()
    let sibling = try root.start { await events.runUntilReleased() }
    await events.started.wait()
    let closer = try root.start {
      root.close()
      return root.isClosed
    }
    #expect(try await closer.value)
    #expect(throws: ScopeError.closed) { try root.start { 1 } }
    #expect(!events.cancelled.isOpen)
    events.release.open()
    #expect(try await sibling.value == false)
    await root.finish()
    #expect(events.finished.isOpen)
  }

  @Test func adoptedCompletingHandleIsReleasedWhenItFinishesWhileScopeRemainsOpen()
    async throws
  {
    let root = Scope.root()
    let leaf = CompletingLeaf()
    let released = Gate()
    try await root.adopt(CompletingBox(leaf: leaf, resource: DeinitSignal(released)))
    #expect(!released.isOpen)
    leaf.release.open()
    await released.wait()
    #expect(!root.isClosed)
    let stillOpen = try root.child()
    await root.cancel()
    await stillOpen.cancel()
    #expect(leaf.cancelCalls.withLock { $0 } == 0)
  }

  @Test func rejectedCompletingAdoptionCancelsAndDrainsBeforeThrowing() async {
    let root = Scope.root()
    await root.cancel()
    let leaf = CompletingLeaf()
    let rejection = Task {
      do {
        try await root.adopt(leaf)
        Issue.record("A closed scope accepted a completing handle")
      } catch {
        #expect(error as? ScopeError == .closed)
        #expect(leaf.finished.isOpen)
      }
    }
    await leaf.cancelled.wait()
    #expect(!leaf.finished.isOpen)
    leaf.release.open()
    await rejection.value
    #expect(leaf.cancelCalls.withLock { $0 } == 1)
  }

  @Test func cancellationCancelsARunningCompletingHandle() async throws {
    let root = Scope.root()
    let leaf = CompletingLeaf()
    try await root.adopt(leaf)
    let cancelling = Task { await root.cancel() }
    await leaf.cancelled.wait()
    #expect(!leaf.finished.isOpen)
    leaf.release.open()
    await cancelling.value
    #expect(leaf.finished.isOpen)
    #expect(leaf.cancelCalls.withLock { $0 } == 1)
  }

  @Test func isClosedReflectsClosureAndCancellation() async throws {
    let root = Scope.root()
    let child = try root.child()
    #expect(!root.isClosed)
    #expect(!child.isClosed)
    child.close()
    #expect(child.isClosed)
    #expect(!root.isClosed)
    root.requestCancellation()
    #expect(root.isClosed)
    await root.cancel()
    #expect(child.isClosed)
  }
}

import Synchronization
import Testing

@testable import Lifetime

@Suite(.timeLimit(.minutes(1)))
struct StructuredTests {
  @Test func withChildCancelsAndDrainsOnReturn() async throws {
    let root = Scope.root()
    let events = WorkEvents()
    let captured = Mutex<Scope?>(nil)
    let run = Task {
      try await root.withChild(name: "child") { child in
        captured.withLock { $0 = child }
        #expect(child.name == "child")
        #expect(!child.isClosed)
        _ = try child.start { await events.run() }
        await events.started.wait()
        return 7
      }
    }
    await events.cancelled.wait()
    #expect(!events.finished.isOpen)
    events.release.open()
    #expect(try await run.value == 7)
    #expect(events.finished.isOpen)
    #expect(captured.withLock { $0 }?.isClosed == true)
    #expect(!root.isClosed)
    let stillOpen = try root.child()
    await root.cancel()
    await stillOpen.cancel()
  }

  @Test func withChildCancelsAndDrainsOnThrow() async throws {
    enum Failure: Error { case expected }
    let root = Scope.root()
    let events = WorkEvents()
    let run = Task {
      try await root.withChild { child -> Void in
        _ = try child.start { await events.run() }
        await events.started.wait()
        throw Failure.expected
      }
    }
    await events.cancelled.wait()
    #expect(!events.finished.isOpen)
    events.release.open()
    await #expect(throws: Failure.expected) { try await run.value }
    #expect(events.finished.isOpen)
    await root.cancel()
  }

  @Test func withChildRejectsWithoutRunningBodyWhenClosed() async throws {
    let root = Scope.root()
    root.close()
    let invoked = Gate()
    await #expect(throws: ScopeError.closed) {
      try await root.withChild { _ in invoked.open() }
    }
    #expect(!invoked.isOpen)
    await root.cancel()
  }

  @Test func withChildPropagatesCallerCancellationWhileBodyContinues() async throws {
    let root = Scope.root()
    let events = WorkEvents()
    let proceed = Gate()
    let run = Task {
      try await root.withChild { child in
        _ = try child.start { await events.run() }
        await events.started.wait()
        await proceed.wait()
        return Task.isCancelled
      }
    }
    await events.started.wait()
    run.cancel()
    await events.cancelled.wait()
    #expect(!events.finished.isOpen)
    events.release.open()
    proceed.open()
    #expect(try await run.value)
    #expect(events.finished.isOpen)
    #expect(!root.isClosed)
    await root.cancel()
  }

  @Test func withChildOnCancelledTaskProvidesClosedChild() async throws {
    let root = Scope.root()
    let proceed = Gate()
    let run = Task {
      await proceed.wait()
      #expect(Task.isCancelled)
      return try await root.withChild { child in
        #expect(child.isClosed)
        #expect(throws: ScopeError.closed) { try child.start { 1 } }
        return 3
      }
    }
    run.cancel()
    proceed.open()
    #expect(try await run.value == 3)
    #expect(!root.isClosed)
    await root.cancel()
  }

  @Test func withRootRunsNonThrowingBodyAndDrains() async throws {
    let events = WorkEvents()
    let run = Task {
      await Scope.withRoot(name: "root") { root in
        #expect(root.name == "root")
        _ = try? root.start { await events.run() }
        await events.started.wait()
        return 5
      }
    }
    await events.cancelled.wait()
    events.release.open()
    #expect(await run.value == 5)
    #expect(events.finished.isOpen)
  }

  @Test func withChildFromWorkInTheParentDrainsWithoutSelfWait() async throws {
    let root = Scope.root()
    let leaf = Leaf()
    let result = try root.start {
      try await root.withChild { child in
        try await child.adopt(leaf)
        return true
      }
    }
    await leaf.entered.wait()
    leaf.release.open()
    #expect(try await result.value)
    #expect(leaf.finished.isOpen)
    await root.cancel()
  }

  @Test func withChildBodyMayFinishTheChildBeforeExit() async throws {
    let root = Scope.root()
    let events = WorkEvents()
    let run = Task {
      try await root.withChild { child in
        let result = try child.start { await events.runUntilReleased() }
        await events.started.wait()
        await child.finish()
        return try await result.value
      }
    }
    await events.started.wait()
    events.release.open()
    #expect(try await run.value == false)
    #expect(!events.cancelled.isOpen)
    await root.cancel()
  }
}

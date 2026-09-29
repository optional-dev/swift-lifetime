import Synchronization
import Testing

@testable import Lifetime

@Suite(.timeLimit(.minutes(1)))
struct WorkTests {
  @Test @MainActor func droppingUnstartedWorkReleasesCapturesWithoutInvocation() {
    let invoked = Gate()
    let released = Gate()
    func makeWork() -> Work<Void> {
      let resource = DeinitSignal(released)
      return Work {
        withExtendedLifetime(resource) {}
        invoked.open()
      }
    }
    let work = makeWork()
    #expect(!invoked.isOpen)
    #expect(!released.isOpen)
    _ = consume work
    #expect(released.isOpen)
    #expect(!invoked.isOpen)
  }

  @Test @MainActor func rejectedWorkIsDiscardedWithoutInvocation() async {
    let scope = Scope.root()
    await scope.cancel()
    let invoked = Gate()
    let released = Gate()
    func makeWork() -> Work<Void> {
      let resource = DeinitSignal(released)
      return Work {
        withExtendedLifetime(resource) {}
        invoked.open()
      }
    }
    let work = makeWork()
    do {
      _ = try scope.start(consume work)
      Issue.record("A closed scope accepted work")
    } catch {
      #expect(error == .closed)
    }
    #expect(released.isOpen)
    #expect(!invoked.isOpen)
  }

  @Test func droppingScopeCancelsWhileObserverSurvives() async throws {
    let events = WorkEvents()
    var scope: Scope? = Scope.root()
    weak let weakScope = scope
    let work = Work { await events.run() }
    let result = try #require(scope).start(consume work)
    await events.started.wait()
    scope = nil
    #expect(weakScope == nil)
    await events.cancelled.wait()
    #expect(!events.finished.isOpen)
    events.release.open()
    #expect(try await result.value)
    #expect(events.finished.isOpen)
  }

  @Test @MainActor func cancellationBeforeActorExecutionSkipsOperation() async throws {
    let scope = Scope.root()
    let invoked = Gate()
    let work = Work { invoked.open() }
    let result = try scope.start(consume work)
    // Cancel the underlying task synchronously while its actor is still occupied.
    result.task.cancel()
    await #expect(throws: CancellationError.self) { try await result.value }
    #expect(!invoked.isOpen)
    await scope.cancel()
  }

  @Test func cancelWaitsForCleanupAndSupportsConcurrentCallers() async throws {
    let scope = Scope.root()
    let events = WorkEvents()
    let work = Work { await events.run() }
    let result = try scope.start(consume work)
    await events.started.wait()
    async let first: Void = scope.cancel()
    async let second: Void = scope.cancel()
    await events.cancelled.wait()
    #expect(!events.finished.isOpen)
    events.release.open()
    await first
    #expect(events.finished.isOpen)
    await second
    await scope.cancel()
    #expect(try await result.value)
  }

  @Test func alreadyCancelledCallerStillDrainsWork() async throws {
    let scope = Scope.root()
    let events = WorkEvents()
    let work = Work { await events.run() }
    let result = try scope.start(consume work)
    await events.started.wait()
    let callerStarted = Gate()
    let callerProceed = Gate()
    let waiter = Task {
      callerStarted.open()
      await callerProceed.wait()
      #expect(Task.isCancelled)
      await scope.cancel()
      #expect(events.finished.isOpen)
    }
    await callerStarted.wait()
    waiter.cancel()
    callerProceed.open()
    await events.cancelled.wait()
    #expect(!events.finished.isOpen)
    events.release.open()
    await waiter.value
    #expect(try await result.value)
  }

  @Test func resultsPreserveValuesAndErrors() async throws {
    enum Failure: Error { case expected }
    let scope = Scope.root()
    let success = Work { 42 }
    let observer = try scope.start(consume success)
    let observerCopy = observer
    #expect(try await observer.value == 42)
    #expect(try await observerCopy.value == 42)
    let failure = Work<Int> { throw Failure.expected }
    let failed = try scope.start(consume failure)
    await #expect(throws: Failure.expected) { try await failed.value }
    await scope.cancel()
    #expect(try await observer.value == 42)
    await #expect(throws: Failure.expected) { try await failed.value }
  }

  @Test func cancellingObserverDoesNotCancelWorkOrShortenWait() async throws {
    let scope = Scope.root()
    let release = Gate()
    let work = Work {
      await release.wait()
      return Task.isCancelled
    }
    let result = try scope.start(consume work)
    let waiter = Task {
      let cancelled = try await result.value
      #expect(release.isOpen)
      #expect(!cancelled)
    }
    waiter.cancel()
    release.open()
    try await waiter.value
    await scope.cancel()
  }

  @Test @MainActor func preservesActorIsolationAndUsesStartTaskLocals() async throws {
    let scope = Scope.root()
    var actorValue = 2
    let result = try Local.$value.withValue(17) {
      var work: Work<Int>? = Work {
        MainActor.assertIsolated()
        actorValue += 1
        return actorValue + Local.value
      }
      #expect(actorValue == 2)
      return try Local.$value.withValue(23) {
        try scope.start(work.take()!)
      }
    }
    #expect(try await result.value == 26)
    await scope.cancel()
  }

  @Test func deferredWorkAndInlineStartPreserveCustomActorIsolation() async throws {
    actor Owner {
      var count = 0

      func makeWork() -> Work<Int> {
        Work {
          self.assertIsolated()
          self.count += 1
          return self.count
        }
      }

      func start(in scope: Scope) throws -> WorkResult<Int> {
        try scope.start {
          self.assertIsolated()
          self.count += 1
          return self.count
        }
      }
    }
    let owner = Owner()
    let work = await owner.makeWork()
    #expect(await owner.count == 0)
    let scope = Scope.root()
    let deferred = try scope.start(consume work)
    #expect(try await deferred.value == 1)
    let inline = try await owner.start(in: scope)
    #expect(try await inline.value == 2)
    await scope.cancel()
  }

  @Test(arguments: [false, true])
  func priorityComesFromStartUnlessExplicit(explicit: Bool) async throws {
    let scope = Scope.root()
    let pending = Mutex<Work<TaskPriority>?>(
      Work(priority: explicit ? .high : nil) { Task.currentPriority }
    )
    let observed = Gate()
    let starter = Task.detached(priority: .background) {
      defer { observed.open() }
      let result = try scope.start(pending.withLock { $0.take()! })
      return try await result.value
    }
    // Observe before the higher-priority test task can escalate the starter.
    await observed.wait()
    #expect(try await starter.value == (explicit ? .high : .background))
    await scope.cancel()
  }
}

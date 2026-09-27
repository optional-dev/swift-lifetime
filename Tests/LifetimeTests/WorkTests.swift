import Testing

@testable import Lifetime

@Suite(.timeLimit(.minutes(1)))
struct WorkTests {
  @Test func droppingOwnerCancelsWhileObserverSurvives() async throws {
    let events = WorkEvents()
    let result: WorkResult<Bool>
    do {
      let work = Work { await events.run() }
      result = work.result
      await events.started.wait()
      _ = consume work
    }
    // The cancellation handler runs synchronously during Work.deinit.
    #expect(events.cancelled.isOpen)
    #expect(!events.finished.isOpen)
    events.release.open()
    #expect(try await result.value)
    #expect(events.finished.isOpen)
  }

  @Test func cancelWaitsForCleanupAndSupportsConcurrentBorrowers() async throws {
    let events = WorkEvents()
    let work = Work { await events.run() }
    let result = work.result
    await events.started.wait()
    // Capture the noncopyable owner once; Swift 6.2 can share the resulting
    // Sendable closure between concurrent borrowers, as adoption does.
    let cancel: @Sendable () async -> Void = { await work.cancel() }
    async let first: Void = cancel()
    async let second: Void = cancel()
    await events.cancelled.wait()
    #expect(!events.finished.isOpen)
    events.release.open()
    await first
    #expect(events.finished.isOpen)
    await second
    await cancel()
    #expect(try await result.value)
  }

  @Test func alreadyCancelledCallerStillDrainsWork() async throws {
    let events = WorkEvents()
    let work = Work { await events.run() }
    let result = work.result
    await events.started.wait()
    let callerStarted = Gate()
    let callerProceed = Gate()
    let waiter = Task {
      callerStarted.open()
      await callerProceed.wait()
      #expect(Task.isCancelled)
      await work.cancel()
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
    let success = Work { 42 }
    let observer = success.result
    let observerCopy = observer
    #expect(try await observer.value == 42)
    #expect(try await observerCopy.value == 42)
    await success.cancel()
    #expect(try await observer.value == 42)
    let failure = Work<Int> { throw Failure.expected }
    await #expect(throws: Failure.expected) { try await failure.result.value }
    await failure.cancel()
  }

  @Test func cancellingObserverDoesNotCancelOwnerOrShortenWait() async throws {
    let release = Gate()
    let work = Work {
      await release.wait()
      return Task.isCancelled
    }
    let result = work.result
    let waiter = Task {
      let cancelled = try await result.value
      #expect(release.isOpen)
      #expect(!cancelled)
    }
    waiter.cancel()
    release.open()
    try await waiter.value
    await work.cancel()
  }

  @Test @MainActor func inheritsMainActorAndTaskLocals() async throws {
    try await Local.$value.withValue(17) { () async throws in
      var actorValue = 2
      let work = Work {
        MainActor.assertIsolated()
        actorValue += 1
        return actorValue + Local.value
      }
      #expect(try await work.result.value == 20)
      await work.cancel()
    }
  }

  @Test @MainActor func dropBeforeExecutionPreventsInvocation() async {
    let invoked = Gate()
    let result: WorkResult<Void>
    do {
      let work = Work { invoked.open() }
      result = work.result
      _ = consume work
    }
    await #expect(throws: CancellationError.self) { try await result.value }
    #expect(!invoked.isOpen)
  }

  @Test func workAndStartInheritCustomActorIsolation() async throws {
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
    #expect(try await work.result.value == 1)
    await work.cancel()
    let scope = Scope.root()
    let result = try await owner.start(in: scope)
    #expect(try await result.value == 2)
    await scope.cancel()
  }
}

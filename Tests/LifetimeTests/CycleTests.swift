import Testing

@testable import Lifetime

@Suite(.timeLimit(.minutes(1)))
struct CycleTests {
  @Test func startedWorkCannotAwaitItsOwnScope() async {
    await #expect(processExitsWith: .failure) {
      let root = Scope.root()
      let result = try root.start { await root.cancel() }
      try await result.value
    }
  }

  @Test func deferredWorkCannotAwaitAnAncestor() async {
    await #expect(processExitsWith: .failure) {
      let root = Scope.root()
      let child = try root.child()
      let work = Work {
        await root.cancel()
      }
      let result = try child.start(consume work)
      try await result.value
    }
  }

  @Test func alreadyCancellingWorkCannotBeginASelfWait() async {
    await #expect(processExitsWith: .failure) {
      let root = Scope.root()
      let started = Gate()
      let cancelled = Gate()
      let result = try root.start {
        await withTaskCancellationHandler {
          started.open()
          await cancelled.wait()
          await root.cancel()
        } onCancel: {
          cancelled.open()
        }
      }
      await started.wait()
      await root.cancel()
      try await result.value
    }
  }

  @Test func customCancellationCallbackCannotAwaitItsOwnSubtree() async {
    await #expect(processExitsWith: .failure) {
      struct InvalidLeaf: LifetimeHandle {
        let root: Scope
        func cancel() async { await root.cancel() }
      }
      let root = Scope.root()
      try await root.adopt(InvalidLeaf(root: root))
      await root.cancel()
    }
  }

  @Test func workCannotAwaitItsOwnResult() async {
    await #expect(processExitsWith: .failure) {
      let cell = AsyncCell<WorkResult<Void>>()
      let root = Scope.root()
      let work = Work {
        let result = await cell.wait()
        try await result.value
      }
      let result = try root.start(consume work)
      cell.resolve(result)
      try await result.value
      await root.cancel()
    }
  }

  @Test func startedWorkCannotFinishItsOwnScope() async {
    await #expect(processExitsWith: .failure) {
      let root = Scope.root()
      let result = try root.start { await root.finish() }
      try await result.value
    }
  }

  @Test func alreadyFinishingWorkCannotBeginASelfWait() async {
    await #expect(processExitsWith: .failure) {
      let root = Scope.root()
      let started = Gate()
      let closed = Gate()
      let result = try root.start {
        started.open()
        await closed.wait()
        await root.finish()
      }
      await started.wait()
      root.close()
      closed.open()
      try await result.value
    }
  }

  @Test func completingCallbackCannotAwaitItsOwnSubtree() async {
    await #expect(processExitsWith: .failure) {
      struct InvalidLeaf: CompletingLifetimeHandle {
        let root: Scope
        func cancel() async {}
        func wait() async { await root.finish() }
      }
      let root = Scope.root()
      try await root.adopt(InvalidLeaf(root: root))
      await root.finish()
    }
  }
}

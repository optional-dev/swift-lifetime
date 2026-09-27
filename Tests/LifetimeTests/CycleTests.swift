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

  @Test func adoptedWrappedWorkCannotAwaitAnAncestor() async {
    await #expect(processExitsWith: .failure) {
      let root = Scope.root()
      let child = try root.child()
      let ready = Gate()
      let started = Gate()
      let work = Work {
        started.open()
        await ready.wait()
        await root.cancel()
      }
      let result = work.result
      await started.wait()
      try await child.adopt(WrappedWork(work: consume work))
      ready.open()
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
      let work = Work {
        let result = await cell.wait()
        try await result.value
      }
      cell.resolve(work.result)
      try await work.result.value
      await work.cancel()
    }
  }
}

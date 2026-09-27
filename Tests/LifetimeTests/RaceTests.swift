import Synchronization
import Testing

@testable import Lifetime

@Suite(.timeLimit(.minutes(1)))
struct RaceTests {
  @Test(arguments: 0..<20)
  func startRacingAncestorCancellationIsEitherDrainedOrRejected(iteration: Int) async throws {
    let root = Scope.root()
    let child = try root.child()
    let start = Gate()
    let cancellationReturned = Gate()
    let running = Counter()
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await start.wait()
        await root.cancel()
        cancellationReturned.open()
        #expect(running.value == 0)
      }
      for _ in 0..<32 {
        group.addTask {
          await start.wait()
          let cancelled = Gate()
          do {
            let result = try child.start {
              #expect(!cancellationReturned.isOpen)
              running.increment()
              await withTaskCancellationHandler {
                await cancelled.wait()
              } onCancel: {
                cancelled.open()
              }
              running.decrement()
            }
            do { try await result.value } catch { #expect(error is CancellationError) }
          } catch {
            #expect(error as? ScopeError == .closed)
          }
        }
      }
      start.open()
    }
    #expect(cancellationReturned.isOpen)
    #expect(running.value == 0)
    #expect(throws: ScopeError.closed) { try child.child() }
    await child.cancel()
  }

  @Test func pendingRegistrationIsDrainedEvenWhenInstalledAfterClosure() async {
    let node = ScopeNode(ancestors: [])
    let tree = ScopeTree(root: node)
    let registration = WorkRegistration(name: nil)
    #expect(tree.insert(registration, into: node))
    tree.requestCancellation(of: node)
    #expect(!tree.insert(WorkRegistration(name: nil), into: node))
    let leaf = Leaf()
    registration.install(leaf)
    await leaf.entered.wait()
    #expect(!leaf.finished.isOpen)
    leaf.release.open()
    await node.completion.wait()
    #expect(leaf.finished.isOpen)
    #expect(leaf.calls.withLock { $0 } == 1)
  }

  @Test func cancellationJoinsAlreadyClosingChildWhileClosingSiblings() async throws {
    let root = Scope.root()
    let child = try root.child()
    let sibling = try root.child()
    let first = Leaf()
    let second = Leaf()
    try await child.adopt(first)
    try await sibling.adopt(second)
    child.requestCancellation()
    await first.entered.wait()
    let cancellation = Task {
      await root.cancel()
      #expect(first.finished.isOpen)
      #expect(second.finished.isOpen)
    }
    await second.entered.wait()
    second.release.open()
    await sibling.cancel()
    #expect(!first.finished.isOpen)
    first.release.open()
    await cancellation.value
    await child.cancel()
    #expect(first.calls.withLock { $0 } == 1)
  }

  @Test func cancellationWaitsForStructuredChildrenAndTheirCleanup() async throws {
    let root = Scope.root()
    let first = WorkEvents()
    let second = WorkEvents()
    let result = try root.start {
      await withTaskGroup(of: Bool.self) { group in
        group.addTask { await first.run() }
        group.addTask { await second.run() }
        for await cancelled in group { #expect(cancelled) }
      }
    }
    await first.started.wait()
    await second.started.wait()
    let cancellation = Task {
      await root.cancel()
      #expect(first.finished.isOpen)
      #expect(second.finished.isOpen)
    }
    await first.cancelled.wait()
    await second.cancelled.wait()
    first.release.open()
    second.release.open()
    await cancellation.value
    try await result.value
  }

  @Test func cancelledCallerStillDrainsRejectedCustomHandle() async {
    let root = Scope.root()
    await root.cancel()
    let leaf = Leaf()
    let proceed = Gate()
    let rejection = Task {
      await proceed.wait()
      #expect(Task.isCancelled)
      do {
        try await root.adopt(leaf)
        Issue.record("Closed scope accepted a handle")
      } catch {
        #expect(error as? ScopeError == .closed)
        #expect(leaf.finished.isOpen)
      }
    }
    rejection.cancel()
    proceed.open()
    await leaf.entered.wait()
    leaf.release.open()
    await rejection.value
    #expect(leaf.finished.isOpen)
  }
}

import Synchronization

enum CancellationContext {
  @TaskLocal static var work: WorkIdentity?
  @TaskLocal static var ancestors: [ScopeToken] = []
}

// Retained identity tokens avoid address reuse while a wait is still observable.
final class ScopeToken: Sendable, Hashable {
  static func == (lhs: ScopeToken, rhs: ScopeToken) -> Bool { lhs === rhs }

  func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

// Registration is generic over noncopyable handles, which cannot be downcast to
// Work. Detect the cycle at either end of the wait instead: Scope.cancel records
// a wait, and Work.cancel records its cancelling scope's ancestry. One mutex
// makes both orderings safe, including Work hidden inside a custom handle.
final class WorkIdentity: Sendable {
  private struct State {
    var waits: [ScopeToken: Int] = [:]
    var cancellationAncestors: Set<ScopeToken> = []
  }

  private let state = Mutex(State())

  func beginWaiting(for scope: ScopeToken) {
    state.withLock { state in
      precondition(
        !state.cancellationAncestors.contains(scope),
        "Work cannot await cancellation of its own subtree. Use requestCancellation()."
      )
      state.waits[scope, default: 0] += 1
    }
  }

  func endWaiting(for scope: ScopeToken) {
    state.withLock { state in
      guard let count = state.waits[scope] else { return }
      if count == 1 {
        state.waits.removeValue(forKey: scope)
      } else {
        state.waits[scope] = count - 1
      }
    }
  }

  func recordCancellation(in ancestors: [ScopeToken]) {
    state.withLock { state in
      precondition(
        ancestors.allSatisfy { state.waits[$0] == nil },
        "Work cannot await cancellation of its own subtree. Use requestCancellation()."
      )
      state.cancellationAncestors.formUnion(ancestors)
    }
  }
}

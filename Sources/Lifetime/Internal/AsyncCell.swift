import Synchronization

// A one-shot, cancellation-insensitive rendezvous. Never resume under the lock.
final class AsyncCell<Value: Sendable>: Sendable {
  private struct State {
    var value: Value?
    var waiters: [CheckedContinuation<Value, Never>] = []
  }

  private let state = Mutex(State())

  func resolve(_ value: Value) {
    let waiters = state.withLock { state in
      precondition(state.value == nil, "An AsyncCell can only be resolved once.")
      state.value = value
      let waiters = state.waiters
      state.waiters.removeAll()
      return waiters
    }
    for waiter in waiters { waiter.resume(returning: value) }
  }

  func wait() async -> Value {
    await withCheckedContinuation { continuation in
      let value = state.withLock { state -> Value? in
        if let value = state.value { return value }
        state.waiters.append(continuation)
        return nil
      }
      if let value { continuation.resume(returning: value) }
    }
  }
}

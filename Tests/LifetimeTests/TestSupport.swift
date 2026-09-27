import Synchronization

@testable import Lifetime

// Swift 6.2 cannot share a captured noncopyable local across sending closures.
// Keep the mutex in a Sendable reference so every task uses the same counter.
final class Counter: Sendable {
  private let storage = Mutex(0)

  var value: Int { storage.withLock { $0 } }

  @discardableResult
  func increment() -> Int {
    storage.withLock { value in
      value += 1
      return value
    }
  }

  func decrement() {
    storage.withLock { $0 -= 1 }
  }
}

final class Gate: Sendable {
  private struct State {
    var open = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())

  var isOpen: Bool { state.withLock { $0.open } }

  func open() {
    let waiters = state.withLock { state in
      state.open = true
      let waiters = state.waiters
      state.waiters.removeAll()
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state in
        if state.open { return true }
        state.waiters.append(continuation)
        return false
      }
      if ready { continuation.resume() }
    }
  }
}

final class WorkEvents: Sendable {
  let started = Gate()
  let cancelled = Gate()
  let release = Gate()
  let finished = Gate()

  func run() async -> Bool {
    await withTaskCancellationHandler {
      started.open()
      await cancelled.wait()
      await release.wait()
      finished.open()
      return Task.isCancelled
    } onCancel: {
      cancelled.open()
    }
  }
}

final class Leaf: LifetimeHandle {
  let entered = Gate()
  let release = Gate()
  let finished = Gate()
  let calls = Mutex(0)

  func cancel() async {
    calls.withLock { $0 += 1 }
    entered.open()
    await release.wait()
    finished.open()
  }
}

struct WrappedWork<Value: Sendable>: LifetimeHandle, ~Copyable {
  let work: Work<Value>

  func cancel() async { await work.cancel() }
}

final class DeinitSignal: Sendable {
  let signal: Gate
  init(_ signal: Gate) { self.signal = signal }
  deinit { signal.open() }
}

enum Local {
  @TaskLocal static var value = 0
}

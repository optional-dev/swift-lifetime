import Synchronization

final class ScopeNode: Sendable {
  let token = ScopeToken()
  let ancestors: [ScopeToken]
  let completion = AsyncCell<Void>()

  init(ancestors: [ScopeToken]) {
    self.ancestors = ancestors + [token]
  }
}

final class WorkRegistration: Sendable {
  let token = ScopeToken()
  let name: String?
  private let action = AsyncCell<@Sendable () async -> Void>()

  init(name: String?) { self.name = name }

  func install<Handle: LifetimeHandle & ~Copyable>(_ handle: consuming Handle) {
    let owned = consume handle
    action.resolve { await owned.cancel() }
  }

  func cancel() async {
    let cancel = await action.wait()
    await cancel()
  }
}

// One lock serializes admission and closure throughout a tree. Entries own only
// internal records; they never retain a public Scope. Finished entries disappear,
// while surviving public scopes retain their permanently resolved completion.
final class ScopeTree: Sendable {
  private struct Entry {
    let node: ScopeNode
    let parent: ScopeToken?
    var children: Set<ScopeToken> = []
    var work: [ScopeToken: WorkRegistration] = [:]
    var closing = false
  }

  private struct Batch: Sendable {
    let node: ScopeNode
    let work: [WorkRegistration]
    let children: [ScopeNode]
  }

  private let entries: Mutex<[ScopeToken: Entry]>

  init(root: ScopeNode) {
    entries = Mutex([root.token: Entry(node: root, parent: nil)])
  }

  func addChild(to parent: ScopeNode) throws(ScopeError) -> ScopeNode {
    let child = ScopeNode(ancestors: parent.ancestors)
    let accepted = entries.withLock { entries in
      guard entries[parent.token]?.closing == false else { return false }
      entries[child.token] = Entry(node: child, parent: parent.token)
      entries[parent.token]?.children.insert(child.token)
      return true
    }
    guard accepted else { throw .closed }
    return child
  }

  func insert(_ work: WorkRegistration, into node: ScopeNode) -> Bool {
    entries.withLock { entries in
      guard entries[node.token]?.closing == false else { return false }
      entries[node.token]?.work[work.token] = work
      return true
    }
  }

  func removeFinished(_ work: WorkRegistration, from node: ScopeNode) {
    let removed = entries.withLock { entries -> WorkRegistration? in
      guard entries[node.token]?.closing == false else { return nil }
      return entries[node.token]?.work.removeValue(forKey: work.token)
    }
    // Releasing an owned handle can invoke arbitrary deinit/cancellation code.
    // Keep its destruction outside the tree lock.
    withExtendedLifetime(removed) {}
  }

  func requestCancellation(of node: ScopeNode) {
    let batches = entries.withLock { entries in
      var pending = [node.token]
      var batches: [Batch] = []
      while let token = pending.popLast() {
        guard var entry = entries[token], !entry.closing else { continue }
        entry.closing = true
        let children = entry.children.compactMap { entries[$0]?.node }
        batches.append(Batch(node: entry.node, work: Array(entry.work.values), children: children))
        pending.append(contentsOf: entry.children)
        entry.work.removeAll()
        entries[token] = entry
      }
      return batches
    }
    for batch in batches {
      Task.detached {
        await withTaskGroup(of: Void.self) { group in
          for work in batch.work {
            group.addTask {
              await CancellationContext.$ancestors.withValue(batch.node.ancestors) {
                await work.cancel()
              }
            }
          }
          for child in batch.children {
            group.addTask { await child.completion.wait() }
          }
        }
        batch.node.completion.resolve(())
        self.removeCompleted(batch.node)
      }
    }
  }

  private func removeCompleted(_ node: ScopeNode) {
    let removed = entries.withLock { entries in
      let entry = entries.removeValue(forKey: node.token)
      if let parent = entry?.parent { entries[parent]?.children.remove(node.token) }
      return entry
    }
    withExtendedLifetime(removed) {}
  }
}

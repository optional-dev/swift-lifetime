import Synchronization

final class ScopeNode: Sendable {
  let token = ScopeToken()
  let ancestors: [ScopeToken]
  let completion = AsyncCell<Void>()

  init(ancestors: [ScopeToken]) {
    self.ancestors = ancestors + [token]
  }
}

// How a closing scope drives a leaf: request cancellation, or await completion.
enum LeafAction: Sendable {
  case cancel
  case wait
}

// Owns one installed handle. Cancellation runs at most once per registration;
// waiting may run more than once because each caller must record its ancestry.
// A plain handle cannot report completion, so waiting on it cancels it.
final class WorkRegistration: Sendable {
  private struct Installed: Sendable {
    let completes: Bool
    let perform: @Sendable (LeafAction) async -> Void
  }

  let token = ScopeToken()
  let name: String?
  private let installed = AsyncCell<Installed>()
  private let cancellation = Once()

  init(name: String?) { self.name = name }

  func install<Handle: LifetimeHandle & ~Copyable>(_ handle: consuming Handle) {
    let owned = consume handle
    installed.resolve(Installed(completes: false) { _ in await owned.cancel() })
  }

  func install<Handle: CompletingLifetimeHandle & ~Copyable>(_ handle: consuming Handle) {
    let owned = consume handle
    installed.resolve(
      Installed(completes: true) { action in
        switch action {
        case .cancel: await owned.cancel()
        case .wait: await owned.wait()
        }
      })
  }

  func cancel() async {
    let installed = await installed.wait()
    await cancellation.run { await installed.perform(.cancel) }
  }

  func wait() async {
    let installed = await installed.wait()
    guard installed.completes else { return await cancel() }
    await installed.perform(.wait)
  }
}

// One lock serializes admission and closure throughout a tree. Entries own only
// internal records; they never retain a public Scope. Finished entries disappear,
// while surviving public scopes retain their permanently resolved completion.
final class ScopeTree: Sendable {
  private enum Phase {
    case open
    case finishing
    case cancelling
  }

  private struct Entry {
    let node: ScopeNode
    let parent: ScopeToken?
    var children: Set<ScopeToken> = []
    var work: [ScopeToken: WorkRegistration] = [:]
    var phase = Phase.open
  }

  // A newly closed node. Exactly one driver resolves its completion.
  private struct Batch: Sendable {
    let node: ScopeNode
    let action: LeafAction
    let work: [WorkRegistration]
    let children: [ScopeNode]
  }

  // Leaves of a finishing node that must now be cancelled. Their driver is
  // already waiting for them, so escalation resolves nothing itself.
  private struct Escalation: Sendable {
    let node: ScopeNode
    let work: [WorkRegistration]
  }

  private let entries: Mutex<[ScopeToken: Entry]>

  init(root: ScopeNode) {
    entries = Mutex([root.token: Entry(node: root, parent: nil)])
  }

  func isClosed(_ node: ScopeNode) -> Bool {
    entries.withLock { entries in entries[node.token]?.phase != .open }
  }

  func addChild(to parent: ScopeNode) throws(ScopeError) -> ScopeNode {
    let child = ScopeNode(ancestors: parent.ancestors)
    let accepted = entries.withLock { entries in
      guard entries[parent.token]?.phase == .open else { return false }
      entries[child.token] = Entry(node: child, parent: parent.token)
      entries[parent.token]?.children.insert(child.token)
      return true
    }
    guard accepted else { throw .closed }
    return child
  }

  func insert(_ work: WorkRegistration, into node: ScopeNode) -> Bool {
    entries.withLock { entries in
      guard entries[node.token]?.phase == .open else { return false }
      entries[node.token]?.work[work.token] = work
      return true
    }
  }

  func removeFinished(_ work: WorkRegistration, from node: ScopeNode) {
    let removed = entries.withLock { entries -> WorkRegistration? in
      guard entries[node.token]?.phase == .open else { return nil }
      return entries[node.token]?.work.removeValue(forKey: work.token)
    }
    // Releasing an owned handle can invoke arbitrary deinit/cancellation code.
    // Keep its destruction outside the tree lock.
    withExtendedLifetime(removed) {}
  }

  // Closes every open descendant. Finishing lets leaves complete on their own;
  // cancelling also escalates descendants that are already finishing.
  func close(_ node: ScopeNode, cancelling: Bool) {
    let (batches, escalations) = entries.withLock { entries in
      var pending = [node.token]
      var batches: [Batch] = []
      var escalations: [Escalation] = []
      while let token = pending.popLast() {
        guard var entry = entries[token] else { continue }
        switch entry.phase {
        case .open:
          entry.phase = cancelling ? .cancelling : .finishing
          let children = entry.children.compactMap { entries[$0]?.node }
          batches.append(
            Batch(
              node: entry.node,
              action: cancelling ? .cancel : .wait,
              work: Array(entry.work.values),
              children: children
            ))
        case .finishing where cancelling:
          entry.phase = .cancelling
          escalations.append(Escalation(node: entry.node, work: Array(entry.work.values)))
        case .finishing, .cancelling:
          continue
        }
        // A finishing node keeps its leaves so a later cancellation can reach them.
        if cancelling { entry.work.removeAll() }
        pending.append(contentsOf: entry.children)
        entries[token] = entry
      }
      return (batches, escalations)
    }
    for batch in batches { drive(batch) }
    for escalation in escalations { escalate(escalation) }
  }

  private func drive(_ batch: Batch) {
    Task.detached {
      await withTaskGroup(of: Void.self) { group in
        for work in batch.work {
          group.addTask {
            await CancellationContext.$ancestors.withValue(batch.node.ancestors) {
              switch batch.action {
              case .cancel: await work.cancel()
              case .wait: await work.wait()
              }
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

  private func escalate(_ escalation: Escalation) {
    Task.detached {
      await withTaskGroup(of: Void.self) { group in
        for work in escalation.work {
          group.addTask {
            await CancellationContext.$ancestors.withValue(escalation.node.ancestors) {
              await work.cancel()
            }
          }
        }
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

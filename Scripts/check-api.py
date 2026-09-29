#!/usr/bin/env python3
"""Compile consumer fixtures, including failures that runtime tests cannot cover."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SWIFT = os.environ.get("SWIFT", "swift")
SWIFTC = os.environ.get("SWIFTC", "swiftc")


def run(*args):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=True)


run(SWIFT, "build")
build = Path(run(SWIFT, "build", "--show-bin-path").stdout.strip())
module = next(p for p in (build / "Modules", build) if (p / "Lifetime.swiftmodule").exists())
package = json.loads(run(SWIFT, "package", "dump-package").stdout)
assert [p["name"] for p in package["products"]] == ["Lifetime"]

flags = ["-swift-version", "6", "-parse-as-library", "-I", str(module)]
if sys.platform == "darwin":
    target = json.loads(run(SWIFTC, "-print-target-info").stdout)["target"]["unversionedTriple"]
    flags += ["-target", target + "15.0"]

# Compile to SIL/object code: type checking alone does not run ownership checking.
fixtures = {
    "valid_ownership": (None, """
        import Lifetime
        struct ExternalLeaf: LifetimeHandle, ~Copyable {
          borrowing func cancel() async {}
        }
        func forward<H: LifetimeHandle & ~Copyable>(
          _ handle: consuming H, into scope: Scope
        ) async throws {
          try await scope.adopt(consume handle)
        }
        func prepare() -> Work<Int> { Work { 42 } }
        func forward<V: Sendable>(
          _ work: consuming Work<V>, into scope: Scope
        ) throws -> WorkResult<V> {
          try scope.start(consume work)
        }
        func useAPI() async throws {
          let root = Scope.root()
          let child = try root.child()
          let work = prepare()
          let result = try forward(consume work, into: child)
          try await forward(ExternalLeaf(), into: root)
          let started = try root.start { "value" }
          _ = try await result.value
          _ = try await started.value
          await child.cancel()
          await root.cancel()
        }
    """),
    "actor_isolated_captures_are_safe": (None, """
        import Lifetime
        final class Counter { var value = 0 }
        @MainActor func valid() async throws {
          let counter = Counter()
          let root = Scope.root()
          let work = Work { counter.value += 1 }
          let deferred = try root.start(consume work)
          let result = try root.start { counter.value += 1 }
          counter.value += 1
          try await deferred.value
          try await result.value
          await root.cancel()
        }
    """),
    "disconnected_capture_can_transfer": (None, """
        import Lifetime
        final class Counter { var value = 0 }
        func valid() async throws {
          let counter = Counter()
          let root = Scope.root()
          let work = Work { counter.value += 1; return counter.value }
          let result = try root.start(consume work)
          _ = try await result.value
          await root.cancel()
        }
    """),
    "work_rejects_unsafe_capture_sharing": ("sending", """
        import Lifetime
        final class Counter { var value = 0 }
        func invalid() async throws {
          let counter = Counter()
          let root = Scope.root()
          let work = Work { counter.value += 1 }
          counter.value += 1
          let result = try root.start(consume work)
          try await result.value
          await root.cancel()
        }
    """),
    "start_rejects_unsafe_capture_sharing": ("sending", """
        import Lifetime
        final class Counter { var value = 0 }
        func invalid() async throws {
          let counter = Counter()
          let root = Scope.root()
          let result = try root.start { counter.value += 1 }
          counter.value += 1
          try await result.value
          await root.cancel()
        }
    """),
    "scope_is_not_a_leaf": ("LifetimeHandle", """
        import Lifetime
        func invalid() async throws {
          let scope = Scope.root()
          try await scope.adopt(scope)
        }
    """),
    "raw_task_is_not_a_leaf": ("LifetimeHandle", """
        import Lifetime
        func invalid() async throws {
          let scope = Scope.root()
          try await scope.adopt(Task { 42 })
        }
    """),
    "deferred_work_is_not_a_leaf": ("LifetimeHandle", """
        import Lifetime
        func invalid() async throws {
          let scope = Scope.root()
          let work = Work { 42 }
          try await scope.adopt(consume work)
        }
    """),
    "generic_adoption_cannot_accept_work": ("LifetimeHandle", """
        import Lifetime
        func forward<H: LifetimeHandle & ~Copyable>(
          _ handle: consuming H, into scope: Scope
        ) async throws {
          try await scope.adopt(consume handle)
        }
        func invalid() async throws {
          let scope = Scope.root()
          let work = Work { 42 }
          try await forward(consume work, into: scope)
        }
    """),
    "unstarted_work_has_no_result": ("result", """
        import Lifetime
        func invalid() {
          let work = Work { 42 }
          _ = work.result
        }
    """),
    "unstarted_work_has_no_cancel": ("cancel", """
        import Lifetime
        func invalid() async {
          let work = Work { 42 }
          await work.cancel()
        }
    """),
    "consumed_work_cannot_be_reused": ("consum", """
        import Lifetime
        func invalid() async throws {
          let scope = Scope.root()
          let work = Work { 42 }
          _ = try scope.start(consume work)
          _ = try scope.start(consume work)
        }
    """),
    "work_cannot_be_duplicated": ("consum", """
        import Lifetime
        func invalid() async throws {
          let scope = Scope.root()
          let work = Work { 42 }
          let alias = work
          _ = try scope.start(consume work)
          _ = try scope.start(consume alias)
        }
    """),
    "observer_cannot_cancel": ("cancel", """
        import Lifetime
        func invalid(_ result: WorkResult<Int>) async {
          await result.cancel()
        }
    """),
    "detached_work_is_removed": ("DetachedWork", """
        import Lifetime
        func invalid() { _ = DetachedWork { 42 } }
    """),
}

with tempfile.TemporaryDirectory(prefix="lifetime-api-") as directory:
    directory = Path(directory)
    for name, (diagnostic, source) in fixtures.items():
        path = directory / f"{name}.swift"
        path.write_text(source)
        result = subprocess.run(
            [SWIFTC, *flags, "-c", str(path), "-o", str(directory / f"{name}.o")],
            cwd=ROOT, text=True, capture_output=True,
        )
        if diagnostic is None:
            valid = result.returncode == 0
        else:
            valid = result.returncode != 0 and diagnostic in result.stderr
        if not valid:
            sys.exit(f"Unexpected compiler result for {name}:\n{result.stdout}{result.stderr}")
        print(f"PASS {name}")

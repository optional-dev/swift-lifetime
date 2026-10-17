# Contributing to swift-lifetime

This package tracks work in a tree and makes subtree cancellation awaitable.
Changes should strengthen that contract or improve its usability. General async
utilities without a tree ownership role belong elsewhere.

## Requirements

Use Swift 6.4+ in Swift 6 language mode. The package enables strict memory safety,
nonisolated default isolation, and `NonisolatedNonsendingByDefault`. Apple platform
minimums are macOS 27, iOS 27, tvOS 27, and watchOS 27, so async `defer` and task
cancellation shields are available without compatibility fallbacks. Linux is supported.

## Checks

```sh
swift build
swift test
swift test -c release
python3 Scripts/check-api.py
swift format lint --recursive --strict Sources Tests Package.swift
```

To run the Linux suite using Docker: `./linux.sh run swift test`. CI tests both
Swift 6.4 and the latest Linux image. The old benchmark executable covered the
removed API and has been removed; performance claims need measurements against
the new implementation.

Format changed Swift files with `swift format format -i`. The repo's
`.swift-format.json` uses two-space indentation and a 100-column line length.
Public declarations need documentation. `mise install` and `prek install` set up
the optional formatting hook.

## Cancellation tests

Use Swift Testing. Verify observable cleanup **after** awaited cancellation;
merely checking a cancellation flag is insufficient. Use continuation gates and
explicit handshakes for ordering, never sleep-based timing. Exercise concurrent
and repeated callers, rejection during shutdown, and deinit-triggered cleanup.
Precondition failures belong in subprocess exit tests. Ownership constraints
belong in `Scripts/check-api.py` compile fixtures.

Do not run callbacks, resume continuations, request task cancellation, or destroy
user-owned handles while holding a state lock. Check that removal of a record
cannot hide cleanup still in progress. Preserve completion across public handle
deinitialization. See [docs/internals.md](docs/internals.md).

## Pull requests

Explain the concrete behavior change and how it was validated. Keep the README,
DocC, changelog, and public surface consistent. Use typed throws for fixed error
sets. Do not add compatibility aliases for APIs intentionally removed in the
minimal redesign.

Report suspected vulnerabilities privately as described in
[SECURITY.md](SECURITY.md). Contributions are under the [MIT license](LICENSE).

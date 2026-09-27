# Security policy

`swift-lifetime` is a concurrency-runtime support library; it does not
handle credentials, network traffic, or persisted user data on its own.
Most realistic security-relevant defects in this package will surface
as **incorrect cancellation, missed teardown, or unsoundness under
`Sendable` checking** — situations where ownership guarantees promised
in the documentation are not actually honored.

## Supported versions

The supported stable line starts at `1.0.0`. Security fixes ship on
current 1.x releases; pre-1.0 snapshots are out of scope.

| Version | Supported       |
|---------|-----------------|
| 1.x     | ✅ fixes ship here |
| < 1.0   | ❌                |

## Reporting a vulnerability

**Do not file a public GitHub issue for a suspected vulnerability.**

Use [GitHub's private vulnerability reporting](https://github.com/GoodHatsLLC/swift-lifetime/security/advisories/new)
to open a private advisory against this repository. Include:

- A description of the issue and the security impact.
- A minimal reproduction (ideally a Swift Testing case using the public
  API of the `Lifetime` product).
- Affected versions and platforms.
- Any suggested mitigation.

Acknowledgement target: within **7 days**. We may ask follow-up
questions through the same private channel.

If you do not get a response within 14 days, you can escalate by
emailing the maintainer listed in the repository's GitHub profile.

## Scope of "security" for this package

Reports that fit, with examples:

- A `Scope.cancel()` call returns before its registered teardown has
  actually finished, in a reproducible scenario.
- A `Sendable` annotation on a public type is unsound and allows a
  data race observable from supported Swift 6 + strict memory safety
  configurations.
- A subtree admits work after cancellation has closed it.
- Dropping a child loses its parent's ability to await cleanup.
- A `WorkResult` prevents its `Work` owner from cancelling on deinit.

Reports that are not in scope (please file as regular issues instead):

- Performance regressions without a cancellation or memory-safety defect.
- API ergonomic preferences.
- Issues only reproducible under runtime configurations the package
  does not claim to support (e.g. Swift 5 language mode, iOS 17, or
  unsafe compiler modes).

## Coordinated disclosure

For accepted reports, we aim to ship a fix and a GitHub Security
Advisory together. CVE assignment is at GitHub's discretion; we will
request one when the impact warrants it.

# cel-swift

Pure-Swift port of cel-go. The plan, architecture, milestones and conformance targets are in
`docs/plan.md`; read it before starting a milestone.

## Porting rules

- **Port, don't invent.** Each Swift file names its cel-go source file(s) in a header comment. Behaviour
  follows cel-go unless the spec (`third_party/cel-spec/doc/langdef.md`) says otherwise; any deliberate
  divergence goes in `docs/divergences.md` with the reason.
- **Ported files keep cel-go's copyright header** (Apache-2.0); `CELRegex` files keep the Go Authors' BSD
  notice. See `NOTICE`. Files that are not ports say `Not a ported file` in their first comment;
  `tools/check-headers/check_headers.py` checks all of this in CI.
- **The grind loop**: run the conformance target for one file, group failures by cause, read the matching
  cel-go code, fix, rerun; then run the differential suite before committing. A milestone is done when its
  exit criteria hold, not when most tests pass.
- **Skip list discipline**: a skip entry needs a reason and an issue. Never skip a test to make a number go
  up; removing entries is the goal of every milestone.
- **Strings are Unicode scalars.** CEL counts code points: `String.count` and `Character` APIs in
  `Sources/CEL` are bugs.

## Swift conventions

- Swift tools 6.0, language mode 6, strict concurrency. `Sendable` everywhere, value types, no global
  mutable state.
- No force unwraps outside tests. No `Foundation` in hot paths; in `CEL` only what `FoundationEssentials`
  provides on Linux.
- `CEL` has zero dependencies. Protobuf lives in `CELProtobuf`, YAML in `CELPolicy`.
- Tests use swift-testing (`import Testing`).

## Skills

Vendored in `.claude/skills` (provenance in its `README.md`). Load the matching one before the work, not
after:

- `swift-api-design-guidelines`: any new or changed `public` / `package` declaration.
- `swift-concurrency-pro`: anything touching `Sendable`, isolation, cancellation or the interrupt check.
- `swift-testing-pro`: writing or reviewing tests.

The concurrency and testing skills target Swift 6.2. **This repo's floor is Swift 6.0 on macOS 13 / iOS 16**,
and CI builds with 6.0, so where a skill and this file disagree, this file wins:

- Not available on the floor: `@concurrent`, `Task.immediate`, default-actor-isolation settings, raw
  identifiers as test names, exit tests, attachments. Use them only behind `#if compiler(>=6.2)` when a
  fallback exists, otherwise not at all.
- `Synchronization` (`Mutex`, `Atomic`) needs macOS 15 / iOS 18. The core is synchronous value code and
  should need neither; if something does, raise it before reaching for `@unchecked Sendable`.

## Library practices

This is a library other packages depend on, so the public surface is the product.

- **Access control.** `public` is a commitment; default to `internal`. Code shared between this package's
  targets (e.g. `CELExtensions` using `CEL` internals) is `package`, never `public` and never
  `@_spi` / `@testable` in non-test code.
- **Source compatibility.** SemVer from the first tag. Before 1.0 a minor bump may break; after 1.0 only a
  major may. Adding a case to a public enum, a requirement to a public protocol without a default, or
  changing a signature is breaking. Once a tag exists, check with
  `swift package diagnose-api-breaking-changes <last-tag>` before committing API changes.
- **Public enums clients switch over** (`Value`, `CELType`) are decided deliberately: either the case list
  is closed by the spec, or clients get accessors instead of exhaustive switches.
- **Errors.** Public errors are concrete types (`CompileError`, `EvalError`) carrying source locations.
  Typed throws (`throws(CompileError)`) only where the error set is truly closed; otherwise plain `throws`.
- **Performance annotations.** `@inlinable` / `@usableFromInline` only with a benchmark showing the gain:
  an inlinable body becomes part of the client's compiled code and constrains later changes.
- **No name clashes with the standard library** in public API (`Duration`, `Error`, `Type`, `Optional`,
  `Regex`): qualify or rename, since clients import both.
- **Portability.** Everything in `Sources` builds on Linux; Darwin-only code needs `#if canImport(Darwin)`
  and a Linux path (Glibc and, for the static Linux SDK, Musl: `pthread_t` differs). CI is the check, not
  the local macOS build.
- **Documentation.** Every `public` declaration has a doc comment in DocC markup; the API design skill sets
  the shape. `tools/check-docs/check-docs.sh` (through swiftlock) lists gaps and builds the DocC catalogs.

## Builds

- **Run every `swift build` / `swift test` / `swift run` through `tools/build-guard/swiftlock`**, e.g.
  `tools/build-guard/swiftlock swift build --build-tests -j 4`. It allows two builds at a time machine-wide (parallel agent
  worktrees each do a full build) and starts `swiftguard.sh`, which kills any swift-frontend over 8 GB. macOS
  ignores `ulimit -v`/`-d`, and an unbounded frontend has already exhausted 64 GB and panicked the machine.
- **No big generated Swift literals.** Fixture data goes into resource files (JSON lines, text) read at test time;
  a 7,000-row array literal of tuples with optionals took the type checker past 30 GB. Generated tables in
  `Sources` get explicit element types and stay split into small chunks.

## Repo

- `third_party/cel-spec` is a submodule pinned to a release tag (currently v0.25.3). Bump deliberately, with
  the conformance dashboard diff in the commit.
- Conformance: `swift test --filter CELConformanceTests` runs the cel-spec suite in checked and parse-only
  mode against `Tests/CELConformanceTests/passing.txt` (regressions fail; `CEL_CONFORMANCE_UPDATE=1` rewrites
  it) and `skip.txt`; `tools/dashboard/dashboard.py` prints the per-file table against cel-go, cel-rust and
  cel-cpp. The runner is `Tests/CELConformanceTests/CELConformanceRunner.swift`.
- `tools/oracle` answers parse / check / eval requests with cel-go over JSONL (protocol in its README);
  `tools/gen-protos.sh` regenerates `Sources/CELSpecProtos`.
- `tools/api-check/check-api.sh` (CI job `api-breakage`) compares the public API with the latest tag;
  before 1.0 it reports and does not fail, so read its output on any PR that touches `public` declarations.

## Changes go through pull requests

The repo is public and released (`0.1.0`), so every change, docs included, lands through a PR; nothing is
pushed to `main` directly.

- Branch from `origin/main` (`git checkout -b <branch> origin/main`; in a worktree `main` is checked out
  elsewhere). Branch names: `lukasz-<what>`, or `<area>/<what>` for agent branches.
- One feature area per PR, small enough to review in one sitting. Titles follow the commit form
  `<area>: <what>`. The description says what changed and why, with the dashboard delta when conformance moves
  and the `tools/bench/bench.py` numbers when performance does; no test plan.
- Bug fixes keep the reproducer commit separate from the fix, so the PR shows what was broken.
- Run `swift build` and `swift test` (through swiftlock) before opening the PR; CI runs the full matrix on
  every PR (Linux Swift 6.0 to 6.3, macOS, iOS simulator, static Linux SDK, oracle, fuzz, API breakage).
  Merge only when it is green.
- Merge with `gh pr merge --squash --delete-branch`; the squashed title is the PR title.
- Pushes use `--force-with-lease` with the remote and branch named, never bare `--force`.
- This is a public repo: no customer names, internal hostnames or local paths in code, tests, commits or PR
  text. GitHub mirrors public commits permanently, so a force-push does not unpublish them.
- User-visible changes add a line under `## [Unreleased]` in `CHANGELOG.md` in the same PR.

## Releases

- Tags are plain SemVer without a `v` (`0.1.0`), as Swift packages usually tag; SwiftPM resolves
  `from: "0.1.0"` against them. Before 1.0 a minor release may break the API, a patch release may not.
- A release is its own PR: move the `[Unreleased]` entries under `## [x.y.z] - YYYY-MM-DD`, refresh the
  conformance and performance numbers (`tools/dashboard/dashboard.py --run`, `tools/bench/bench.py`) in
  `CHANGELOG.md` and the README table, update the compare links at the bottom of the changelog.
- After it merges and CI is green on `main`: `git tag -a x.y.z -m "cel-swift x.y.z" <merge commit>`,
  `git push origin refs/tags/x.y.z`, then `gh release create x.y.z --verify-tag --notes-file <notes>`. The
  notes follow the 0.1.0 release: a one-paragraph summary, Highlights, Installation, Conformance (table
  against cel-go, cel-cpp and cel-rust), Platforms, Performance, Breaking changes (from the `api-breakage`
  job, with migration notes), Known limitations, and a link to `CHANGELOG.md` at the tag.
- After the tag is pushed, empty `tools/api-check/allowlist.txt` in its own PR. Not in the release PR: CI
  compares against the latest tag, which is still the previous release until the tag exists.

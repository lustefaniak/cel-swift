# cel-swift

Pure-Swift port of cel-go. The plan, architecture, milestones and conformance targets are in
`docs/plan.md`; read it before starting a milestone.

## Porting rules

- **Port, don't invent.** Each Swift file names its cel-go source file(s) in a header comment. Behaviour
  follows cel-go unless the spec (`third_party/cel-spec/doc/langdef.md`) says otherwise; any deliberate
  divergence goes in `docs/divergences.md` with the reason.
- **Ported files keep cel-go's copyright header** (Apache-2.0); `CELRegex` files keep the Go Authors' BSD
  notice. See `NOTICE`.
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

## Repo

- `third_party/cel-spec` is a submodule pinned to a release tag (currently v0.25.3). Bump deliberately, with
  the conformance dashboard diff in the commit.
- Private repo, single committer: commits go straight to `main`.

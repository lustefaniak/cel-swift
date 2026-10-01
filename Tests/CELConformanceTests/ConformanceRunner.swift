// The seam between the conformance harness and the CEL implementation.
//
// Mirrors the pipeline of cel-go conformance/conformance_test.go: parse (with or without macros), extend the
// environment with the container and type_env declarations, check unless disabled, stop after checking for
// check_only tests, otherwise plan and evaluate with the bindings. The harness owns everything around that
// (loading, matching, skip list, ratchet, reporting); a runner only executes one test.

import CELSpecProtos

/// How a test is run.
enum ConformanceMode: String, CaseIterable, Codable, Sendable {
  /// Parse, then type-check unless the test sets `disable_check`, then evaluate. This is cel-go's mode.
  case checked
  /// Parse and evaluate without the checker. Not applicable to `disable_check` tests (checked mode already
  /// runs those unchecked) or `check_only` tests (nothing to evaluate).
  case parseOnly = "parse-only"
}

/// One test, as handed to a runner.
struct ConformanceRequest: Sendable {
  /// `file/section/test`, as cel-go names it.
  var name: String
  var mode: ConformanceMode
  /// The test as read from the textproto. Runners read `expr`, `disableMacros`, `container`, `typeEnv`,
  /// `bindings` and `locale` from it; the result matcher is the harness's business.
  var test: Cel_Expr_Conformance_Test_SimpleTest

  /// Whether the runner must type-check before evaluating (cel-go: `!pb.GetDisableCheck()`).
  var runsChecker: Bool { mode == .checked && test.disableCheck == false }

  /// Whether the runner must stop after checking and report the deduced type (`check_only`).
  var checkOnly: Bool { test.checkOnly }
}

/// What a runner observed for one test. Values and types are reported as cel-spec protos so matching is
/// independent of the implementation's value model.
enum ConformanceOutcome: Sendable {
  /// The runner cannot run this test yet (missing feature); counts as a failure, reported separately.
  case notImplemented(String)
  /// Parsing failed. cel-go treats this as a test failure for every test.
  case parseError(String)
  /// Checking (or extending the environment with the test's declarations) failed; also always a failure.
  case checkError(String)
  /// `check_only` tests: the deduced type of the checked expression.
  case checked(deducedType: Cel_Expr_Type)
  /// Evaluation finished. `result` holds a value, an error set or an unknown set; `deducedType` is the checked
  /// output type, `nil` when the checker did not run.
  case evaluated(result: Cel_Expr_ExprValue, deducedType: Cel_Expr_Type?)
}

/// Runs a single conformance test through a CEL implementation.
///
/// The only file that knows about both the CEL library and this protocol is the runner implementation; it
/// converts `Cel_Expr_Decl` to declarations, `Cel_Expr_ExprValue` bindings to CEL values and results back to
/// `Cel_Expr_Value`. Swapping implementations means replacing that one file (see `conformanceRunner`).
protocol ConformanceRunner: Sendable {
  /// A short name recorded in the results file.
  var name: String { get }

  func run(_ request: ConformanceRequest) -> ConformanceOutcome
}

// Errors of typed programs, with the source positions and snippets a UI or a CLI shows.
// Not a ported file.

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CEL
import CELPolicy

/// Why an expression or a policy cannot be used: syntax, type, declaration or output-shape
/// problems, each with its position in the source.
///
/// ``description`` renders every issue the way cel-go does, with the source line and a caret,
/// ready to print in a CLI:
///
/// ```
/// ERROR: select.yaml:7:20: undefined field 'titel'
///  |       - condition: pr.titel.startsWith("chore:")
///  | ...................^
/// ```
///
/// ``issues`` carries the same information as values, for a UI that lists problems next to the
/// file.
public struct ValidationError: Error, Sendable, CustomStringConvertible, LocalizedError {
  /// One problem and where it is.
  public struct Issue: Sendable, Hashable, CustomStringConvertible {
    /// The problem, without position, such as `undefined field 'titel'`.
    public var message: String
    /// The name of the source: a file name, or `<input>` for an expression without one.
    public var sourceName: String
    /// The 1-based line, or `nil` when the problem has no position (a declaration error).
    public var line: Int?
    /// The 1-based column, counted in Unicode scalars, or `nil` when the problem has no position.
    public var column: Int?

    /// Creates an issue.
    public init(message: String, sourceName: String, line: Int?, column: Int?) {
      self.message = message
      self.sourceName = sourceName
      self.line = line
      self.column = column
    }

    /// `source:line:column: message`, or `source: message` without a position.
    public var description: String {
      if let line, let column {
        return "\(sourceName):\(line):\(column): \(message)"
      }
      return "\(sourceName): \(message)"
    }
  }

  /// The problems, in the order they were found.
  public let issues: [Issue]
  /// Every issue with its source line and a caret under the column, sorted by position.
  public let description: String

  /// The rendered issues, for `localizedDescription`.
  public var errorDescription: String? { description }

  init(issues: [Issue], description: String) {
    self.issues = issues
    self.description = description
  }

  init(_ errors: CELErrors) {
    let sourceName = errors.source.description
    self.init(
      issues: errors.errors.map { error in
        let located = error.location.line >= 1 && error.location.column >= 0
        return Issue(
          message: error.message, sourceName: sourceName, line: located ? error.location.line : nil,
          column: located ? error.location.column + 1 : nil)
      },
      description: errors.toDisplayString())
  }

  init(_ error: CompileError) {
    self.init(error.errors)
  }

  init(_ error: PolicyError) {
    self.init(
      issues: error.issues.map { issue in
        let located = issue.line >= 1 && issue.column >= 0
        return Issue(
          message: issue.message, sourceName: error.source.description, line: located ? issue.line : nil,
          column: located ? issue.column + 1 : nil)
      },
      description: error.description)
  }

  init(_ error: DeclarationError, sourceName: String) {
    self.init(
      issues: [Issue(message: error.message, sourceName: sourceName, line: nil, column: nil)],
      description: "ERROR: \(sourceName): \(error.message)")
  }
}

/// Why a typed program could not produce its output: an evaluation error positioned in the
/// source, facts that could not be encoded, or a result that does not decode as the output type.
///
/// ```
/// ERROR: decide.yaml:9:28: no such key: trusted
///  |           pr.author in lists.trusted
///  | ...........................^
/// ```
public struct EvaluationError: Error, Sendable, CustomStringConvertible, LocalizedError {
  /// The problem, such as `no such key: trusted` or `division by zero`.
  public var message: String
  /// The name of the source the expression or policy came from.
  public var sourceName: String
  /// The 1-based line of the sub-expression that failed, or `nil` when there is none (encoding and
  /// decoding errors, errors without a position).
  public var line: Int?
  /// The 1-based column of the sub-expression that failed, counted in Unicode scalars, or `nil`.
  public var column: Int?
  /// The error value the evaluation produced, `nil` for encoding and decoding errors.
  public var evalError: EvalError?
  /// The message with its position and source snippet, as cel-go renders errors.
  public let description: String

  /// The rendered error, for `localizedDescription`.
  public var errorDescription: String? { description }

  init(evalError: EvalError, expression: CheckedExpression) {
    var errors = CELErrors(source: expression.source)
    let location = expression.ast.sourceInfo.startLocation(evalError.expressionID)
    errors.reportError(exprID: evalError.expressionID, at: location, evalError.message)
    let located = location.line >= 1 && location.column >= 0
    self.message = evalError.message
    self.sourceName = expression.sourceName
    self.line = located ? location.line : nil
    self.column = located ? location.column + 1 : nil
    self.evalError = evalError
    self.description = located ? errors.toDisplayString() : "ERROR: \(expression.sourceName): \(evalError.message)"
  }

  init(message: String, sourceName: String) {
    self.message = message
    self.sourceName = sourceName
    self.line = nil
    self.column = nil
    self.evalError = nil
    self.description = "ERROR: \(sourceName): \(message)"
  }
}

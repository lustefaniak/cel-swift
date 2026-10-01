// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Re-designed from cel-go cel/env.go `Issues` (Err, Errors, String, ReportErrorAtID).

/// The errors found while parsing, checking or validating an expression.
///
/// ``description`` renders every issue the way cel-go does, with the source line and a caret
/// under the offending column:
///
/// ```
/// ERROR: <input>:1:3: undeclared reference to 'y' (in container '')
///  | x + y
///  | ..^
/// ```
public struct CompileError: Error, Sendable, CustomStringConvertible {
  /// One diagnostic: a message and where it applies.
  public struct Issue: Sendable, Hashable, CustomStringConvertible {
    /// The diagnostic message, without location, such as `undeclared reference to 'y'`.
    public var message: String
    /// The 1-based line of the issue in the source, or `nil` when it has no location.
    public var line: Int?
    /// The 1-based column of the issue, counted in Unicode scalars, or `nil` when it has no
    /// location.
    public var column: Int?
    /// The id of the expression node the issue is attached to, or `nil`.
    public var expressionID: Int64?

    /// The issue rendered as `line:column: message`.
    public var description: String {
      if let line, let column {
        return "\(line):\(column): \(message)"
      }
      return message
    }
  }

  /// The issues, in the order they were reported.
  public let issues: [Issue]

  /// Every issue rendered with its source snippet, sorted by location, as cel-go's
  /// `Issues.String()`.
  public let description: String

  package let errors: CELErrors

  package init(_ errors: CELErrors) {
    self.errors = errors
    self.description = errors.toDisplayString()
    self.issues = errors.errors.map { error in
      let hasLocation = error.location.line >= 0 && error.location != .none
      return Issue(
        message: error.message,
        line: hasLocation ? error.location.line : nil,
        column: hasLocation ? error.location.column + 1 : nil,
        expressionID: error.exprID == 0 ? nil : error.exprID)
    }
  }

  /// An error with one issue that has no location (cel-go `ErrorAsIssues`).
  package init(message: String, source: any Source) {
    var errors = CELErrors(source: source)
    errors.reportError(at: .none, message)
    self.init(errors)
  }
}

// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//	https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// The issue set cel-go's policy parser returns (`*cel.Issues` built with
// `cel.NewIssuesWithSourceInfo`), on top of the core `CELErrors` and `SourceInfo`.

import CEL

/// Errors found while parsing or compiling a policy, with their source locations.
///
/// The ``description`` renders the errors the way cel-go does, sorted by position, each followed
/// by the offending source line and a caret:
///
/// ```
/// ERROR: policy.yaml:3:3: unsupported rule tag: custom
///  |   custom: yaml-type
///  | ..^
/// ```
public struct PolicyError: Error, Sendable, CustomStringConvertible {
  /// A single error with its location.
  public struct Issue: Sendable, Hashable {
    /// The error message.
    public var message: String
    /// The 1-based line of the error, or -1 when unknown.
    public var line: Int
    /// The 0-based column of the error, counted in Unicode scalars, or -1 when unknown.
    public var column: Int
    /// The identifier of the policy element the error was reported against, or 0.
    public var id: Int64
  }

  /// The source the errors refer to.
  public let source: PolicySource
  var errors: CELErrors

  init(source: PolicySource) {
    self.source = source
    self.errors = CELErrors(source: source)
  }

  /// The errors, in the order they were reported, up to cel-go's limit of 100.
  public var issues: [Issue] {
    errors.errors.map {
      Issue(message: $0.message, line: $0.location.line, column: $0.location.column, id: $0.exprID)
    }
  }

  var isEmpty: Bool { errors.numErrors == 0 }

  mutating func report(id: Int64, location: Location, message: String) {
    errors.reportError(exprID: id, at: location, message)
  }

  /// The errors rendered as cel-go renders them: sorted by location, one `ERROR:` entry each with
  /// a source snippet, separated by newlines.
  public var description: String {
    errors.toDisplayString()
  }
}

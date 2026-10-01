// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go common/errors.go, common/error.go, the SourceInfo offset helpers in
// common/ast/ast.go, and cel.Issues (cel/env.go).
//
// TODO(core): the core module is defining its own `Source`, `SourceInfo` and error types in
// parallel. When they land, `PolicySourceInfo` should become the core `SourceInfo` and `PolicyError`
// should carry (or be replaced by) the core issue type, so policy and expression errors share one
// formatter. The display format here is cel-go's and must stay byte-identical.

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

  /// The errors, in the order they were reported.
  public var issues: [Issue]
  /// The source the errors refer to.
  public var source: PolicySource
  /// The number of errors reported, including any not kept in ``issues`` beyond the report limit.
  var reportedCount: Int

  static let maxErrorsToReport = 100

  init(source: PolicySource) {
    self.issues = []
    self.source = source
    self.reportedCount = 0
  }

  mutating func report(id: Int64, location: PolicyLocation, message: String) {
    reportedCount += 1
    if reportedCount > Self.maxErrorsToReport {
      return
    }
    issues.append(Issue(message: message, line: location.line, column: location.column, id: id))
  }

  /// Appends the errors of another error set.
  mutating func append(_ other: PolicyError) {
    issues.append(contentsOf: other.issues)
    reportedCount += other.issues.count
  }

  /// The errors rendered as cel-go renders them: sorted by location, one `ERROR:` entry each with
  /// a source snippet, separated by newlines.
  public var description: String {
    let sorted = issues.enumerated().sorted { a, b in
      let (ea, eb) = (a.element, b.element)
      if ea.line != eb.line { return ea.line < eb.line }
      if ea.column != eb.column { return ea.column < eb.column }
      return a.offset < b.offset
    }.map(\.element)
    var result = sorted.prefix(Self.maxErrorsToReport).map { Self.display($0, source) }
    if reportedCount > Self.maxErrorsToReport {
      result.append("\(reportedCount - Self.maxErrorsToReport) more errors were truncated")
    }
    return result.joined(separator: "\n")
  }

  private static let maxSnippetLength = 16384

  static func display(_ issue: Issue, _ source: PolicySource) -> String {
    var result = "ERROR: \(source.description):\(issue.line):\(issue.column + 1): \(issue.message)"
    if let snippet = source.snippet(line: issue.line), snippet.utf8.count <= maxSnippetLength {
      let line = snippet.replacingAll("\t", with: " ")
      result += "\n | " + line
      var indicator = "\n | "
      var scalars = line.unicodeScalars.makeIterator()
      var next = scalars.next()
      var i = 0
      while i < issue.column, let s = next {
        indicator += s.utf8.count > 1 ? "\u{ff0e}" : "."
        next = scalars.next()
        i += 1
      }
      if let s = next, s.utf8.count > 1 {
        indicator += "\u{ff3e}"
      } else {
        indicator += "^"
      }
      result += indicator
    }
    return result
  }
}

/// Source positions of policy elements by identifier, as cel-go's `ast.SourceInfo`.
///
/// TODO(core): replace with the core `SourceInfo` once `Sources/CEL/Common` lands.
struct PolicySourceInfo: Sendable {
  struct OffsetRange: Sendable, Hashable {
    var start: Int32
    var stop: Int32
  }

  var description: String
  var lineOffsets: [Int32]
  var offsetRanges: [Int64: OffsetRange] = [:]

  init(source: PolicySource) {
    description = source.description
    lineOffsets = source.lineOffsets
  }

  func startLocation(of id: Int64) -> PolicyLocation {
    guard let range = offsetRanges[id] else { return .none }
    return location(ofOffset: range.start)
  }

  func location(ofOffset offset: Int32) -> PolicyLocation {
    var line = 1
    var col = Int(offset)
    for lineOffset in lineOffsets {
      if lineOffset > offset {
        break
      }
      line += 1
      col = Int(offset - lineOffset)
    }
    return PolicyLocation(line: line, column: col)
  }
}

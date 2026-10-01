// Copyright 2018 Google LLC
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

// Ported from cel-go common/error.go and common/errors.go.

/// A single diagnostic produced while parsing or checking an expression (cel-go `common.Error`).
package struct CELError: Error, Hashable, Sendable {
  /// Where the error occurred; `Location.none` when unknown.
  package var location: Location
  /// The human readable message.
  package var message: String
  /// The id of the expression the error is attached to, or 0.
  package var exprID: Int64

  package init(exprID: Int64 = 0, message: String, location: Location) {
    self.location = location
    self.message = message
    self.exprID = exprID
  }

  private static let maxSnippetLength = 16384

  /// Renders the error the way cel-go does, with the source line and a caret under the column:
  ///
  ///     ERROR: <input>:1:5: message
  ///      | expr
  ///      | ....^
  package func toDisplayString(_ source: any Source) -> String {
    var result =
      "ERROR: \(source.description):\(location.line):\(location.column + 1): \(message)"
    if let snippet = source.snippet(line: location.line), snippet.utf8.count <= CELError.maxSnippetLength {
      var line = ""
      line.unicodeScalars.append(
        contentsOf: snippet.unicodeScalars.lazy.map { $0 == "\t" ? " " : $0 })
      var indLine = "\n | "
      var scalars = line.unicodeScalars[...]
      var i = 0
      while i < location.column, let first = scalars.first {
        scalars = scalars.dropFirst()
        indLine += first.value >= 0x80 ? "\u{ff0e}" : "."
        i += 1
      }
      if let first = scalars.first, first.value >= 0x80 {
        indLine += "\u{ff3e}"
      } else {
        indLine += "^"
      }
      result += "\n | " + line + indLine
    }
    return result
  }
}

/// An ordered collection of errors reported against a source (cel-go `common.Errors`).
package struct CELErrors: Sendable {
  package private(set) var errors: [CELError] = []
  package let source: any Source
  package private(set) var numErrors = 0
  package let maxErrorsToReport: Int

  /// Creates an empty error collection for `source` (an empty text source when `nil`).
  package init(source: (any Source)? = nil, maxErrorsToReport: Int = 100) {
    self.source = source ?? TextSource("")
    self.maxErrorsToReport = maxErrorsToReport
  }

  /// Records an error at `location` that is not attached to an expression.
  package mutating func reportError(at location: Location, _ message: String) {
    reportError(exprID: 0, at: location, message)
  }

  /// Records an error at `location` attached to the expression with the given id.
  package mutating func reportError(exprID: Int64, at location: Location, _ message: String) {
    numErrors += 1
    if numErrors > maxErrorsToReport {
      return
    }
    errors.append(CELError(exprID: exprID, message: message, location: location))
  }

  /// Returns a new collection with `other` appended.
  package func appending(_ other: [CELError]) -> CELErrors {
    var result = self
    result.errors.append(contentsOf: other)
    result.numErrors += other.count
    return result
  }

  /// Whether any error was reported.
  package var isEmpty: Bool { errors.isEmpty }

  /// Renders all errors sorted by location, as cel-go's `ToDisplayString`.
  package func toDisplayString() -> String {
    var result: [String] = []
    let sorted = errors.enumerated().sorted { lhs, rhs in
      let li = lhs.element.location
      let ri = rhs.element.location
      if li.line != ri.line { return li.line < ri.line }
      if li.column != ri.column { return li.column < ri.column }
      return lhs.offset < rhs.offset
    }
    for (i, entry) in sorted.enumerated() {
      if i >= maxErrorsToReport {
        break
      }
      result.append(entry.element.toDisplayString(source))
    }
    if numErrors > maxErrorsToReport {
      result.append("\(numErrors - maxErrorsToReport) more errors were truncated")
    }
    return result.joined(separator: "\n")
  }
}

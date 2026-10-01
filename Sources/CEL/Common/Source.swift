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

// Ported from cel-go common/source.go and common/runes/buffer.go.

/// The text of an expression together with the metadata needed to map offsets to lines and columns.
///
/// Offsets and columns are counted in Unicode scalars (code points), as in cel-go.
package protocol Source: Sendable {
  /// The source content.
  var content: String { get }

  /// A short description of where the source came from, such as a file name. `<input>` for plain text.
  var description: String { get }

  /// Code point offsets at which lines start, excluding the first line; the last entry is the content
  /// length plus one.
  var lineOffsets: [Int32] { get }

  /// The content as Unicode scalars; parsers read this instead of `content`.
  var scalars: [Unicode.Scalar] { get }

  /// Translates a location into a code point offset, or `nil` when the line does not exist.
  func locationOffset(_ location: Location) -> Int32?

  /// Translates a code point offset into a location, or `nil` when the conversion is not feasible.
  func offsetLocation(_ offset: Int32) -> Location?

  /// Produces a location from a line and column; derived sources may translate relative positions.
  func newLocation(line: Int, column: Int) -> Location

  /// Returns the text of the given 1-based line, without its newline, or `nil` when it does not exist.
  func snippet(line: Int) -> String?
}

/// Error thrown when a source exceeds a code point limit.
package struct SizeLimitError: Error, Sendable, Equatable, CustomStringConvertible {
  package let size: Int
  package let limit: Int

  package var description: String {
    "expression code point size exceeds limit: size: \(size), limit \(limit)"
  }
}

/// A `Source` backed by an in-memory string.
package struct TextSource: Source {
  package let scalars: [Unicode.Scalar]
  package let description: String
  package let lineOffsets: [Int32]

  /// Creates a source from `text` with the description `<input>`.
  package init(_ text: String) {
    self.init(text, description: "<input>")
  }

  /// Creates a source from `text` with the given description.
  package init(_ text: String, description: String) {
    let (scalars, offsets) = TextSource.scan(text)
    self.scalars = scalars
    self.lineOffsets = offsets
    self.description = description
  }

  /// Creates a source, rejecting text with more than `limit` code points (a negative limit disables it).
  package init(_ text: String, description: String = "<input>", limit: Int) throws(SizeLimitError) {
    if limit >= 0 && text.utf8.count > limit {
      let size = text.unicodeScalars.count
      if size > limit {
        throw SizeLimitError(size: size, limit: limit)
      }
    }
    self.init(text, description: description)
  }

  /// Creates a source with no content, carrying only a description and line offsets (cel-go `NewInfoSource`).
  package init(description: String, lineOffsets: [Int32]) {
    self.scalars = []
    self.description = description
    self.lineOffsets = lineOffsets
  }

  private static func scan(_ text: String) -> ([Unicode.Scalar], [Int32]) {
    var scalars: [Unicode.Scalar] = []
    scalars.reserveCapacity(text.utf8.count)
    if text.isEmpty {
      return (scalars, [0])
    }
    var offsets: [Int32] = []
    var off: Int32 = 0
    for scalar in text.unicodeScalars {
      if scalar == "\n" {
        offsets.append(off + 1)
      }
      scalars.append(scalar)
      off += 1
    }
    offsets.append(off + 1)
    return (scalars, offsets)
  }

  package var content: String {
    TextSource.string(scalars[...])
  }

  package func locationOffset(_ location: Location) -> Int32? {
    if let lineOffset = findLineOffset(location.line) {
      return lineOffset + Int32(location.column)
    }
    return nil
  }

  package func newLocation(line: Int, column: Int) -> Location {
    Location(line: line, column: column)
  }

  package func offsetLocation(_ offset: Int32) -> Location? {
    let (line, lineOffset) = findLine(offset)
    return Location(line: Int(line), column: Int(offset - lineOffset))
  }

  package func snippet(line: Int) -> String? {
    guard let charStart = findLineOffset(line), !scalars.isEmpty else {
      return nil
    }
    if let charEnd = findLineOffset(line + 1) {
      return slice(Int(charStart), Int(charEnd - 1))
    }
    return slice(Int(charStart), scalars.count)
  }

  private func slice(_ start: Int, _ end: Int) -> String {
    let lo = max(0, min(start, scalars.count))
    let hi = max(lo, min(end, scalars.count))
    return TextSource.string(scalars[lo..<hi])
  }

  private func findLineOffset(_ line: Int) -> Int32? {
    if line == 1 {
      return 0
    }
    if line > 1 && line <= lineOffsets.count {
      return lineOffsets[line - 2]
    }
    return nil
  }

  private func findLine(_ characterOffset: Int32) -> (Int32, Int32) {
    var line: Int32 = 1
    for lineOffset in lineOffsets {
      if lineOffset > characterOffset {
        break
      }
      line += 1
    }
    if line == 1 {
      return (line, 0)
    }
    return (line, lineOffsets[Int(line) - 2])
  }

  package static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
  }
}

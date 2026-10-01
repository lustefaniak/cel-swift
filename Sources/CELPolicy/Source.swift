// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go policy/source.go.

import CEL

/// The contents of a policy file, with the line table used to map character offsets to positions.
///
/// Offsets and columns count Unicode scalars, as CEL source positions do.
public struct PolicySource: Sendable {
  let text: TextSource

  /// Creates a source from the text of a policy file.
  ///
  /// - Parameters:
  ///   - content: The policy text.
  ///   - description: A short description of the source, typically the file path; it prefixes
  ///     error messages.
  public init(_ content: String, description: String = "<input>") {
    self.text = TextSource(content, description: description)
  }

  /// Creates a source from the bytes of a policy file, decoded as UTF-8.
  ///
  /// - Parameters:
  ///   - bytes: The UTF-8 encoded policy text.
  ///   - description: A short description of the source, typically the file path.
  public init(bytes: some Sequence<UInt8>, description: String) {
    self.init(String(decoding: Array(bytes), as: UTF8.self), description: description)
  }

  /// The full text of the policy file.
  public var content: String { text.content }

  /// A short description of the source, typically the file path; it prefixes error messages.
  public var description: String { text.description }

  /// Returns the text of a 1-based line without its line break, or `nil` when the line does not
  /// exist.
  public func snippet(line: Int) -> String? {
    text.snippet(line: line)
  }

  /// Returns a source for a fragment of this file whose first character sits at the given line
  /// and 0-based column.
  ///
  /// CEL expressions embedded in a policy are parsed from such fragments so their error positions
  /// refer to the policy file.
  ///
  /// - Parameters:
  ///   - content: The text of the fragment.
  ///   - line: The 1-based line of the fragment start in this file.
  ///   - column: The 0-based column of the fragment start in this file.
  public func relative(_ content: String, line: Int, column: Int) -> RelativeSource {
    RelativeSource(
      parent: self,
      local: TextSource(content, description: description),
      absoluteLocation: Location(line: line, column: column))
  }
}

extension PolicySource: Source {
  package var lineOffsets: [Int32] { text.lineOffsets }
  package var scalars: [Unicode.Scalar] { text.scalars }

  package func locationOffset(_ location: Location) -> Int32? {
    text.locationOffset(location)
  }

  package func offsetLocation(_ offset: Int32) -> Location? {
    text.offsetLocation(offset)
  }

  package func newLocation(line: Int, column: Int) -> Location {
    text.newLocation(line: line, column: column)
  }
}

/// An embedded source fragment within a larger ``PolicySource``.
///
/// The fragment's ``content`` is the embedded text, while descriptions, line tables, snippets and
/// locations are those of the enclosing file, so a CEL parser reading the fragment reports
/// positions in the policy file.
public struct RelativeSource: Sendable {
  /// The enclosing policy file.
  public let parent: PolicySource
  let local: TextSource
  let absoluteLocation: Location

  /// The embedded text.
  public var content: String { local.content }

  /// The 1-based line in the parent file where the fragment starts.
  public var line: Int { absoluteLocation.line }

  /// The 0-based column in the parent file where the fragment starts.
  public var column: Int { absoluteLocation.column }

  /// Returns the 1-based line and 0-based column in the parent file of a character offset
  /// relative to the start of the fragment, or `nil` when the fragment start is not in the file.
  ///
  /// - Parameter offset: An offset into ``content``, counted in Unicode scalars.
  public func absoluteLocation(ofOffset offset: Int) -> (line: Int, column: Int)? {
    guard let loc = offsetLocation(Int32(offset)) else { return nil }
    return (loc.line, loc.column)
  }
}

extension RelativeSource: Source {
  package var description: String { parent.description }
  package var lineOffsets: [Int32] { parent.lineOffsets }
  package var scalars: [Unicode.Scalar] { local.scalars }

  package func locationOffset(_ location: Location) -> Int32? {
    parent.locationOffset(location)
  }

  /// The absolute location given the relative offset, if found.
  package func offsetLocation(_ offset: Int32) -> Location? {
    guard let absOffset = parent.locationOffset(absoluteLocation) else {
      return nil
    }
    return parent.offsetLocation(absOffset + offset)
  }

  package func newLocation(line: Int, column: Int) -> Location {
    parent.newLocation(line: line, column: column)
  }

  package func snippet(line: Int) -> String? {
    parent.snippet(line: line)
  }
}

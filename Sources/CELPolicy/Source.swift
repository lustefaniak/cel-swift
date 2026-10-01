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

// Ported from cel-go policy/source.go, with the parts of common/source.go and common/location.go it
// relies on.
//
// TODO(core): `Sources/CEL/Common/Source.swift` is being written in parallel. Once it lands,
// `PolicySource` should wrap the core `Source` (as cel-go's `policy.Source` embeds `common.Source`)
// and `RelativeSource` should conform to the core source protocol so the CEL parser can report
// positions relative to the policy file. Until then the line-offset logic lives here.

/// The contents of a policy file, with the line table used to map character offsets to positions.
///
/// Offsets and columns count Unicode scalars, as CEL source positions do.
public struct PolicySource: Sendable, Hashable {
  /// The full text of the policy file.
  public let content: String
  /// A short description of the source, typically the file path; it prefixes error messages.
  public let description: String

  let scalars: [Unicode.Scalar]
  /// Character offsets at which lines start: entry `i` is the offset of line `i + 2`. The last
  /// entry is one past the end of the content.
  let lineOffsets: [Int32]

  /// Creates a source from the text of a policy file.
  ///
  /// - Parameters:
  ///   - content: The policy text.
  ///   - description: A short description of the source, typically the file path.
  public init(_ content: String, description: String = "<input>") {
    self.content = content
    self.description = description
    let scalars = Array(content.unicodeScalars)
    self.scalars = scalars
    var offsets: [Int32] = []
    if !scalars.isEmpty {
      for (i, s) in scalars.enumerated() where s == "\n" {
        offsets.append(Int32(i + 1))
      }
      offsets.append(Int32(scalars.count + 1))
    } else {
      offsets.append(0)
    }
    self.lineOffsets = offsets
  }

  /// Creates a source from the bytes of a policy file, decoded as UTF-8.
  ///
  /// - Parameters:
  ///   - bytes: The UTF-8 encoded policy text.
  ///   - description: A short description of the source, typically the file path.
  public init(bytes: some Sequence<UInt8>, description: String) {
    self.init(String(decoding: Array(bytes), as: UTF8.self), description: description)
  }

  /// Returns the text of a 1-based line without its line break, or `nil` when the line does not
  /// exist.
  public func snippet(line: Int) -> String? {
    guard let start = lineOffset(line), !scalars.isEmpty else { return nil }
    let end: Int
    if let next = lineOffset(line + 1) {
      end = Int(next) - 1
    } else {
      end = scalars.count
    }
    return slice(Int(start), end)
  }

  func slice(_ start: Int, _ end: Int) -> String {
    let lo = max(0, min(start, scalars.count))
    let hi = max(lo, min(end, scalars.count))
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[lo..<hi])
    return String(view)
  }

  /// The character offset of a location, or `nil` when its line does not exist.
  func locationOffset(_ location: PolicyLocation) -> Int32? {
    guard let lineOffset = lineOffset(location.line) else { return nil }
    return lineOffset + Int32(location.column)
  }

  /// The location of a character offset.
  func offsetLocation(_ offset: Int32) -> PolicyLocation {
    var line = 1
    var lineStart: Int32 = 0
    for o in lineOffsets {
      if o > offset {
        break
      }
      line += 1
    }
    if line > 1 {
      lineStart = lineOffsets[line - 2]
    }
    return PolicyLocation(line: line, column: Int(offset - lineStart))
  }

  private func lineOffset(_ line: Int) -> Int32? {
    if line == 1 {
      return 0
    }
    if line > 1 && line <= lineOffsets.count {
      return lineOffsets[line - 2]
    }
    return nil
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
    RelativeSource(parent: self, content: content, absoluteLocation: PolicyLocation(line: line, column: column))
  }
}

/// An embedded source fragment within a larger ``PolicySource``.
///
/// The fragment's ``content`` is the embedded text, while positions map back to the enclosing file.
public struct RelativeSource: Sendable, Hashable {
  /// The enclosing policy file.
  public let parent: PolicySource
  /// The embedded text.
  public let content: String
  let absoluteLocation: PolicyLocation

  /// The 1-based line in the parent file where the fragment starts.
  public var line: Int { absoluteLocation.line }
  /// The 0-based column in the parent file where the fragment starts.
  public var column: Int { absoluteLocation.column }

  init(parent: PolicySource, content: String, absoluteLocation: PolicyLocation) {
    self.parent = parent
    self.content = content
    self.absoluteLocation = absoluteLocation
  }

  /// Returns the 1-based line and 0-based column in the parent file of a character offset
  /// relative to the start of the fragment, or `nil` when the fragment start is not in the file.
  public func absoluteLocation(ofOffset offset: Int) -> (line: Int, column: Int)? {
    guard let loc = offsetLocation(Int32(offset)) else { return nil }
    return (loc.line, loc.column)
  }

  func offsetLocation(_ offset: Int32) -> PolicyLocation? {
    guard let absOffset = parent.locationOffset(absoluteLocation) else {
      return nil
    }
    return parent.offsetLocation(absOffset + offset)
  }
}

/// A 1-based line and 0-based column, as cel-go's `common.Location`.
///
/// TODO(core): replace with the core location type once `Sources/CEL/Common` lands.
struct PolicyLocation: Sendable, Hashable {
  var line: Int
  var column: Int

  static let none = PolicyLocation(line: -1, column: -1)
}

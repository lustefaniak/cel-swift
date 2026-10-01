//
// Copyright (c) 2011-2019 Canonical Ltd
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

// Ported from go.yaml.in/yaml/v3 yaml.go (Node, Kind, Style, ShortTag, LongTag).
//
// cel-go's policy parser works on go-yaml `yaml.Node` values: their tags, styles and 1-based
// line/column positions feed the policy source positions and error messages. `YAMLNode` keeps the
// same shape so the policy parser can be ported line by line.

/// A node in a parsed YAML document, with the source position of its first character.
///
/// `YAMLNode` mirrors the node model of go-yaml v3, which cel-go's policy parser is written
/// against: scalars keep their raw text and presentation style, mappings keep their keys and
/// values interleaved in ``content``, and every node records the 1-based ``line`` and ``column``
/// where it starts. Custom ``PolicyTagVisitor`` implementations receive these nodes for
/// embedder-specific policy fields.
public struct YAMLNode: Sendable, Hashable {
  /// The structural kind of a YAML node.
  public enum Kind: Sendable, Hashable {
    /// A document root; its single child is the document content.
    case document
    /// A sequence; ``YAMLNode/content`` holds the elements.
    case sequence
    /// A mapping; ``YAMLNode/content`` holds keys and values interleaved.
    case mapping
    /// A scalar; ``YAMLNode/value`` holds its text.
    case scalar
    /// An alias to an anchored node; ``YAMLNode/alias`` holds the target.
    case alias
  }

  /// The presentation style of a node, as written in the source.
  public struct Style: OptionSet, Sendable, Hashable {
    /// The raw bit set; values match go-yaml's `yaml.Style` constants.
    public let rawValue: UInt32

    /// Creates a style from its raw bit set.
    public init(rawValue: UInt32) {
      self.rawValue = rawValue
    }

    /// The node carries an explicit tag such as `!txt` or `!!str`.
    public static let tagged = Style(rawValue: 1 << 0)
    /// A double-quoted scalar.
    public static let doubleQuoted = Style(rawValue: 1 << 1)
    /// A single-quoted scalar.
    public static let singleQuoted = Style(rawValue: 1 << 2)
    /// A literal block scalar (`|`).
    public static let literal = Style(rawValue: 1 << 3)
    /// A folded block scalar (`>`).
    public static let folded = Style(rawValue: 1 << 4)
    /// A flow sequence or mapping (`[...]`, `{...}`).
    public static let flow = Style(rawValue: 1 << 5)
  }

  /// The structural kind of the node.
  public var kind: Kind
  /// The tag as written or resolved, in short form (`!!str`, `!!map`, `!txt`), or empty.
  ///
  /// Use ``longTag`` or ``shortTag`` for the effective tag of the node.
  public var tag: String
  /// The scalar text, or the anchor name for an alias.
  public var value: String
  /// The anchor name defined on this node, or empty.
  public var anchor: String
  /// The presentation style of the node.
  public var style: Style
  /// Child nodes: the content of a document, sequence elements, or interleaved mapping keys and
  /// values.
  public var content: [YAMLNode]
  /// The 1-based line of the first character of the node.
  public var line: Int
  /// The 1-based column, counted in Unicode scalars, of the first character of the node.
  public var column: Int

  private var aliasTarget: [YAMLNode]

  /// The node an alias refers to, or `nil` when the node is not an alias.
  public var alias: YAMLNode? {
    get { aliasTarget.first }
    set { aliasTarget = newValue.map { [$0] } ?? [] }
  }

  /// Creates a node.
  ///
  /// - Parameters:
  ///   - kind: The structural kind.
  ///   - tag: The explicit or resolved tag, in short form; empty to resolve it from the content.
  ///   - value: The scalar text.
  ///   - style: The presentation style.
  ///   - content: Child nodes.
  ///   - line: The 1-based line of the node.
  ///   - column: The 1-based column of the node.
  public init(
    kind: Kind,
    tag: String = "",
    value: String = "",
    style: Style = [],
    content: [YAMLNode] = [],
    line: Int = 0,
    column: Int = 0
  ) {
    self.kind = kind
    self.tag = tag
    self.value = value
    self.anchor = ""
    self.style = style
    self.content = content
    self.line = line
    self.column = column
    self.aliasTarget = []
  }

  /// The effective tag in short form, such as `!!str`, `!!int` or `!!map`.
  ///
  /// When the node has no explicit tag, the tag is derived from the kind and, for plain scalars,
  /// from the YAML core schema rules go-yaml applies (`true` is `!!bool`, `1` is `!!int`, and so
  /// on). Quoted and block scalars are always `!!str`.
  public var shortTag: String {
    if isIndicatedString {
      return YAMLTags.str
    }
    if tag.isEmpty || tag == "!" {
      switch kind {
      case .mapping:
        return YAMLTags.map
      case .sequence:
        return YAMLTags.seq
      case .alias:
        if let alias {
          return alias.shortTag
        }
      case .scalar:
        return YAMLResolver.resolve(tag: "", value).tag
      case .document:
        break
      }
      return ""
    }
    return YAMLTags.shortTag(tag)
  }

  /// The effective tag in long form, such as `tag:yaml.org,2002:str`, or a custom tag as written.
  public var longTag: String {
    YAMLTags.longTag(shortTag)
  }

  private var isIndicatedString: Bool {
    kind == .scalar
      && (YAMLTags.shortTag(tag) == YAMLTags.str
        || (tag.isEmpty || tag == "!")
          && !style.intersection([.singleQuoted, .doubleQuoted, .literal, .folded]).isEmpty)
  }

  /// go-yaml's numeric `yaml.Kind` value, used in messages that print it.
  var goKindValue: Int {
    switch kind {
    case .document: return 1
    case .sequence: return 2
    case .mapping: return 4
    case .scalar: return 8
    case .alias: return 16
    }
  }
}

/// Tag constants and short/long tag conversion, ported from go-yaml resolve.go.
enum YAMLTags {
  static let null = "!!null"
  static let bool = "!!bool"
  static let str = "!!str"
  static let int = "!!int"
  static let float = "!!float"
  static let timestamp = "!!timestamp"
  static let seq = "!!seq"
  static let map = "!!map"
  static let binary = "!!binary"
  static let merge = "!!merge"

  static let longTagPrefix = "tag:yaml.org,2002:"

  static func shortTag(_ tag: String) -> String {
    if tag.hasPrefix(longTagPrefix) {
      return "!!" + tag.dropFirst(longTagPrefix.count)
    }
    return tag
  }

  static func longTag(_ tag: String) -> String {
    if tag.hasPrefix("!!") {
      return longTagPrefix + tag.dropFirst(2)
    }
    return tag
  }
}

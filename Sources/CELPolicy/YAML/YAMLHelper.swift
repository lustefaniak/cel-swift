// Copyright 2026 Google LLC
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

// Ported from cel-go policy/yaml.go (YAMLHelper) and the yamlNodeType table and normalizeEntry from
// policy/parser.go.

/// The node types the policy parser distinguishes, keyed by long tag.
enum YAMLNodeType: Int, Sendable, CustomStringConvertible {
  case text = 1
  case bool
  case null
  case string
  case int
  case double
  case list
  case map
  case timestamp

  /// The long tag names supported by the Go YAML v3 library.
  static func forLongTag(_ tag: String) -> YAMLNodeType? {
    switch tag {
    case "!txt": return .text
    case "tag:yaml.org,2002:bool": return .bool
    case "tag:yaml.org,2002:null": return .null
    case "tag:yaml.org,2002:str": return .string
    case "tag:yaml.org,2002:int": return .int
    case "tag:yaml.org,2002:float": return .double
    case "tag:yaml.org,2002:seq": return .list
    case "tag:yaml.org,2002:map": return .map
    case "tag:yaml.org,2002:timestamp": return .timestamp
    default: return nil
    }
  }

  var description: String {
    switch self {
    case .text: return "!txt"
    case .bool: return "tag:yaml.org,2002:bool"
    case .null: return "tag:yaml.org,2002:null"
    case .string: return "tag:yaml.org,2002:str"
    case .int: return "tag:yaml.org,2002:int"
    case .double: return "tag:yaml.org,2002:float"
    case .list: return "tag:yaml.org,2002:seq"
    case .map: return "tag:yaml.org,2002:map"
    case .timestamp: return "tag:yaml.org,2002:timestamp"
    }
  }
}

extension YAMLNode {
  private func hasType(_ type: YAMLNodeType) -> Bool {
    YAMLNodeType.forLongTag(longTag) == type
  }

  /// Whether the node is a sequence.
  public var isList: Bool { hasType(.list) }

  /// Whether the node is a mapping with an even number of children.
  public var isMap: Bool { hasType(.map) && content.count % 2 == 0 }

  /// Whether the node is a string scalar.
  public var isString: Bool { hasType(.string) }

  /// Whether the node is a boolean scalar.
  public var isBool: Bool { hasType(.bool) }

  /// Whether the node is a null scalar.
  public var isNull: Bool { hasType(.null) }

  /// Whether the node is an integer or floating-point scalar.
  public var isNumber: Bool { hasType(.int) || hasType(.double) }

  /// Whether the node is an integer scalar.
  public var isInteger: Bool { hasType(.int) }

  /// Whether the node is a floating-point scalar.
  public var isDouble: Bool { hasType(.double) }

  /// Whether the node is a timestamp scalar.
  public var isTimestamp: Bool { hasType(.timestamp) }

  /// The elements of a sequence node, or an empty array for any other node.
  public var listElements: [YAMLNode] {
    isList ? content : []
  }

  /// The key-value pairs of a mapping node in source order, or an empty array for any other node.
  ///
  /// Block scalar values (`|` and `>`) are repositioned to the first line of their content, at
  /// the column one past their key, so that positions computed from them point at the text rather
  /// than at the block indicator. This matches cel-go's `normalizeEntry`.
  public var mapEntries: [(key: YAMLNode, value: YAMLNode)] {
    guard isMap else { return [] }
    var entries: [(key: YAMLNode, value: YAMLNode)] = []
    entries.reserveCapacity(content.count / 2)
    var i = 0
    while i + 1 < content.count {
      entries.append(Self.normalizeEntry(content, i))
      i += 2
    }
    return entries
  }

  /// Extracts a key, value pair as the next two elements from the content slice. The value's
  /// source position information is normalized depending on style.
  static func normalizeEntry(_ content: [YAMLNode], _ i: Int) -> (key: YAMLNode, value: YAMLNode) {
    let key = content[i]
    var val = content[i + 1]
    if val.style == .folded || val.style == .literal {
      val.line += 1
      val.column = key.column + 1
    }
    return (key, val)
  }
}

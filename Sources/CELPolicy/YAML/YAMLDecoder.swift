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

// Ported from go.yaml.in/yaml/v3 decode.go (the `decoder` type: unmarshal, scalar, sequence,
// mapping, mappingStruct, terror).
//
// cel-go reads environment configs and test suites with `yaml.Unmarshal` into Go structs. go-yaml
// is lenient in specific ways those files rely on (any scalar decodes into a string field, so
// `version: 2` and `expr: 2` work) and strict in others (duplicate keys, a mapping where a string
// is expected). This decoder reproduces those rules field by field and collects the same
// `line N: cannot unmarshal ...` messages, without reflection.
//
// Not ported: `<<` merge keys, which go-yaml expands while decoding.

/// A YAML value decoded without a target type, as go-yaml decodes into `any`.
///
/// Plain scalars are resolved with go-yaml's YAML 1.2 rules: `true` / `false` (any case variant
/// go-yaml accepts) are booleans, `null` and `~` are null, integers keep their sign and range,
/// and timestamps stay strings.
public enum YAMLValue: Sendable, Hashable {
  /// A key-value pair of a mapping.
  public struct Entry: Sendable, Hashable {
    /// The key.
    public var key: YAMLValue
    /// The value.
    public var value: YAMLValue

    /// Creates a mapping entry.
    public init(key: YAMLValue, value: YAMLValue) {
      self.key = key
      self.value = value
    }
  }

  /// A null value.
  case null
  /// A boolean value.
  case bool(Bool)
  /// An integer that fits in `Int64`.
  case int(Int64)
  /// A non-negative integer above `Int64.max`.
  case uint(UInt64)
  /// A floating-point value.
  case double(Double)
  /// A string value; timestamps decode as strings too.
  case string(String)
  /// A sequence.
  case list([YAMLValue])
  /// A mapping, with entries in source order.
  case map([Entry])
}

extension YAMLNode {
  /// Decodes the node without a target type, as go-yaml's `node.Decode(&value)` into `any`.
  ///
  /// Tag visitors use this to read embedder-specific fields.
  ///
  /// - Returns: The decoded value, or `nil` for a null node.
  /// - Throws: ``YAMLError`` for a mapping with duplicate keys or a scalar whose explicit tag does
  ///   not fit its text.
  public func decodeValue() throws(YAMLError) -> YAMLValue? {
    try withStack(depth: decodeDepthBound) { () throws(YAMLError) -> YAMLValue? in
      var decoder = YAMLDecoder()
      let value = try decoder.decodeValue(self)
      if let error = decoder.unmarshalError {
        throw error
      }
      return value
    }
  }
}

/// Decodes YAML nodes into typed values with go-yaml's `Unmarshal` rules, collecting type errors.
///
/// Decoding methods return `nil` when the node is null or does not fit the target; type
/// mismatches are recorded in ``errors`` and decoding continues, as go-yaml does. Errors that
/// abort a decode in go-yaml (a custom unmarshaler failing, an explicit tag that does not fit its
/// value) are thrown.
package struct YAMLDecoder {
  /// The deepest nesting of collections decoded, counting those reached through aliases.
  ///
  /// go-yaml has no such limit (Go stacks grow), but its scanner rejects documents nested deeper
  /// than 10000 levels, and the libyaml used here those deeper than 1000. Aliases can splice
  /// anchored trees into each other and nest a decoded value deeper than its document; the limit
  /// keeps decoded values shallow enough to compare and release on any thread.
  package static let maxDepth = 1000

  /// The collected `line N: ...` type errors.
  package private(set) var errors: [String] = []
  /// The number of collections being decoded.
  private var depth = 0
  /// The nodes decoded so far, and how many of them were reached through an alias (go-yaml's
  /// `decodeCount` and `aliasCount`).
  private var decodeCount = 0
  private var aliasCount = 0
  /// The number of aliases being decoded.
  private var aliasDepth = 0

  package init() {}

  /// The error to report for the decode, if any type errors were collected.
  package var unmarshalError: YAMLError? {
    errors.isEmpty ? nil : YAMLError(message: "yaml: unmarshal errors:\n  " + errors.joined(separator: "\n  "))
  }

  /// Records an error message.
  package mutating func report(_ message: String) {
    errors.append(message)
  }

  /// Unwraps document and alias nodes, returning the node to decode, or `nil` for an empty
  /// document.
  package static func content(of node: YAMLNode) -> YAMLNode? {
    switch node.kind {
    case .document:
      return node.content.count == 1 ? content(of: node.content[0]) : nil
    case .alias:
      return node.alias.flatMap { content(of: $0) }
    default:
      return node
    }
  }

  /// Whether the node decodes as null into a pointer-like target (go-yaml leaves it nil).
  package static func isNull(_ node: YAMLNode) -> Bool {
    guard let n = content(of: node) else { return true }
    return n.kind == .scalar && n.shortTag == YAMLTags.null
  }

  /// go-yaml's `allowedAliasRatio`: the share of decoded nodes that may come from alias expansion.
  static func allowedAliasRatio(_ decodeCount: Int) -> Double {
    // 400,000 decode operations is ~500kb of dense object declarations, or
    // ~5kb of dense object declarations with 10000% alias expansion
    let low = 400_000
    // 4,000,000 decode operations is ~5MB of dense object declarations, or
    // ~4.5MB of dense object declarations with 10% alias expansion
    let high = 4_000_000
    if decodeCount <= low {
      // allow 99% to come from alias expansion for small-to-medium documents
      return 0.99
    }
    if decodeCount >= high {
      // allow 10% to come from alias expansion for very large documents
      return 0.10
    }
    // scale smoothly from 99% down to 10% over the range.
    return 0.99 - 0.89 * (Double(decodeCount - low) / Double(high - low))
  }

  /// The bookkeeping go-yaml's `unmarshal` does for each node, and its `document` and `alias`
  /// steps: counts the node, fails a decode that is mostly alias expansion, and unwraps documents
  /// and aliases. Returns the node to decode (`nil` for an empty document) and the number of
  /// aliases followed, which the caller passes to ``leave(_:)`` once the node is decoded.
  private mutating func enter(_ node: YAMLNode) throws(YAMLError) -> (YAMLNode?, Int) {
    var current = node
    var aliases = 0
    while true {
      decodeCount += 1
      if aliasDepth > 0 {
        aliasCount += 1
      }
      if aliasCount > 100 && decodeCount > 1000
        && Double(aliasCount) / Double(decodeCount) > Self.allowedAliasRatio(decodeCount)
      {
        aliasDepth -= aliases
        throw YAMLError(message: "yaml: document contains excessive aliasing")
      }
      switch current.kind {
      case .document:
        guard current.content.count == 1 else { return (nil, aliases) }
        current = current.content[0]
      case .alias:
        guard let target = current.alias else { return (nil, aliases) }
        aliasDepth += 1
        aliases += 1
        current = target
      default:
        return (current, aliases)
      }
    }
  }

  private mutating func leave(_ aliases: Int) {
    aliasDepth -= aliases
  }

  /// Enters a collection's content; balanced by ``ascend()``.
  private mutating func descend() throws(YAMLError) {
    if depth >= Self.maxDepth {
      throw YAMLError(message: "yaml: exceeded max depth of \(Self.maxDepth)")
    }
    depth += 1
  }

  private mutating func ascend() {
    depth -= 1
  }

  private mutating func terror(_ n: YAMLNode, _ tag: String, _ typeName: String) {
    let tag = n.tag.isEmpty ? tag : n.tag
    var value = n.value
    if tag != YAMLTags.seq && tag != YAMLTags.map {
      let bytes = Array(value.utf8)
      if bytes.count > 10 {
        value = " `" + String(decoding: bytes[0..<7], as: UTF8.self) + "...`"
      } else {
        value = " `" + value + "`"
      }
    } else {
      value = ""
    }
    errors.append("line \(n.line): cannot unmarshal \(YAMLTags.shortTag(tag))\(value) into \(typeName)")
  }

  /// Resolves a scalar the way `decoder.scalar` does.
  private func resolveScalar(_ n: YAMLNode) throws(YAMLError) -> (tag: String, value: YAMLResolvedScalar) {
    if n.kind == .scalar, n.shortTag == YAMLTags.str, n.tag.isEmpty || n.tag == "!" || n.tag == YAMLTags.str {
      return (YAMLTags.str, .string(n.value))
    }
    let r = YAMLResolver.resolve(tag: n.tag, n.value)
    if let error = r.error {
      throw YAMLError(message: "yaml: " + error)
    }
    return (r.tag, r.value)
  }

  // MARK: - Scalars

  /// Decodes a string; any scalar decodes as its text.
  package mutating func decodeString(_ node: YAMLNode, typeName: String = "string") throws(YAMLError) -> String? {
    let (entered, aliases) = try enter(node)
    defer { leave(aliases) }
    guard let n = entered else { return nil }
    switch n.kind {
    case .scalar:
      let (tag, resolved) = try resolveScalar(n)
      if resolved == .null {
        return nil
      }
      if tag == YAMLTags.binary {
        return n.value
      }
      return n.value
    case .sequence:
      terror(n, YAMLTags.seq, typeName)
    case .mapping:
      terror(n, YAMLTags.map, typeName)
    default:
      break
    }
    return nil
  }

  /// Decodes a boolean, accepting the YAML 1.1 words (`yes`, `off`, ...) go-yaml allows for typed
  /// booleans.
  package mutating func decodeBool(_ node: YAMLNode) throws(YAMLError) -> Bool? {
    let (entered, aliases) = try enter(node)
    defer { leave(aliases) }
    guard let n = entered else { return nil }
    guard n.kind == .scalar else {
      terror(n, n.kind == .sequence ? YAMLTags.seq : YAMLTags.map, "bool")
      return nil
    }
    let (tag, resolved) = try resolveScalar(n)
    switch resolved {
    case .null:
      return nil
    case .bool(let b):
      return b
    case .string(let s):
      switch s {
      case "y", "Y", "yes", "Yes", "YES", "on", "On", "ON": return true
      case "n", "N", "no", "No", "NO", "off", "Off", "OFF": return false
      default: break
      }
    default:
      break
    }
    terror(n, tag, "bool")
    return nil
  }

  /// Decodes a signed integer.
  package mutating func decodeInt64(_ node: YAMLNode, typeName: String = "int64") throws(YAMLError) -> Int64? {
    let (entered, aliases) = try enter(node)
    defer { leave(aliases) }
    guard let n = entered else { return nil }
    guard n.kind == .scalar else {
      terror(n, n.kind == .sequence ? YAMLTags.seq : YAMLTags.map, typeName)
      return nil
    }
    let (tag, resolved) = try resolveScalar(n)
    switch resolved {
    case .null:
      return nil
    case .int(let v):
      return v
    case .uint(let v) where v <= UInt64(Int64.max):
      return Int64(v)
    case .float(let f) where f.isFinite && f <= 9.223372036854775807e18 && f >= -9.223372036854775808e18:
      return Int64(f)
    default:
      break
    }
    terror(n, tag, typeName)
    return nil
  }

  /// Decodes a value without a target type, as go-yaml decodes into `any`.
  package mutating func decodeValue(_ node: YAMLNode) throws(YAMLError) -> YAMLValue? {
    let (entered, aliases) = try enter(node)
    defer { leave(aliases) }
    guard let n = entered else { return nil }
    switch n.kind {
    case .scalar:
      let (tag, resolved) = try resolveScalar(n)
      switch resolved {
      case .null: return nil
      case .bool(let b): return .bool(b)
      case .int(let v): return .int(v)
      case .uint(let v): return .uint(v)
      case .float(let f): return .double(f)
      case .timestamp: return .string(n.value)
      case .string(let s): return .string(tag == YAMLTags.binary ? n.value : s)
      case .merge: return .string(n.value)
      }
    case .sequence:
      try descend()
      defer { ascend() }
      var items: [YAMLValue] = []
      for child in n.content {
        items.append(try decodeValue(child) ?? .null)
      }
      return .list(items)
    case .mapping:
      guard checkUniqueKeys(n) else { return nil }
      try descend()
      defer { ascend() }
      var entries: [YAMLValue.Entry] = []
      var i = 0
      while i + 1 < n.content.count {
        let key = try decodeValue(n.content[i]) ?? .null
        let value = try decodeValue(n.content[i + 1]) ?? .null
        entries.append(YAMLValue.Entry(key: key, value: value))
        i += 2
      }
      return .map(entries)
    default:
      return nil
    }
  }

  // MARK: - Collections

  /// Decodes a sequence, dropping elements that fail to decode.
  package mutating func decodeList<T>(
    _ node: YAMLNode,
    typeName: String,
    element: (inout YAMLDecoder, YAMLNode) throws(YAMLError) -> T?
  ) throws(YAMLError) -> [T]? {
    let (entered, aliases) = try enter(node)
    defer { leave(aliases) }
    guard let n = entered else { return nil }
    switch n.kind {
    case .sequence:
      try descend()
      defer { ascend() }
      var items: [T] = []
      for child in n.content {
        if let item = try element(&self, child) {
          items.append(item)
        }
      }
      return items
    case .scalar:
      if try resolveScalar(n).value == .null {
        return nil
      }
      terror(n, try resolveScalar(n).tag, typeName)
    case .mapping:
      terror(n, YAMLTags.map, typeName)
    default:
      break
    }
    return nil
  }

  /// Decodes a mapping with string keys into a dictionary.
  package mutating func decodeStringMap<T>(
    _ node: YAMLNode,
    typeName: String,
    value: (inout YAMLDecoder, YAMLNode) throws(YAMLError) -> T?
  ) throws(YAMLError) -> [String: T]? {
    let (entered, aliases) = try enter(node)
    defer { leave(aliases) }
    guard let n = entered else { return nil }
    switch n.kind {
    case .mapping:
      guard checkUniqueKeys(n) else { return nil }
      try descend()
      defer { ascend() }
      var result: [String: T] = [:]
      var i = 0
      while i + 1 < n.content.count {
        if let key = try decodeString(n.content[i]) {
          if let v = try value(&self, n.content[i + 1]) {
            result[key] = v
          }
        }
        i += 2
      }
      return result
    case .scalar:
      if try resolveScalar(n).value == .null {
        return nil
      }
      terror(n, try resolveScalar(n).tag, typeName)
    case .sequence:
      terror(n, YAMLTags.seq, typeName)
    default:
      break
    }
    return nil
  }

  /// Decodes a mapping into a structure: calls `field` for each key, reporting keys repeated in
  /// the mapping and fields set twice.
  ///
  /// - Parameters:
  ///   - node: The node to decode.
  ///   - typeName: The Go type name used in error messages, for example `env.Config`.
  ///   - fields: The field names of the structure; other keys are ignored.
  ///   - field: Decodes the value of a known field.
  /// - Returns: Whether the node was a mapping; `false` for null and mismatched nodes.
  @discardableResult
  package mutating func decodeObject(
    _ node: YAMLNode,
    typeName: String,
    fields: Set<String>,
    field: (inout YAMLDecoder, String, YAMLNode) throws(YAMLError) -> Void
  ) throws(YAMLError) -> Bool {
    let (entered, aliases) = try enter(node)
    defer { leave(aliases) }
    guard let n = entered else { return false }
    switch n.kind {
    case .mapping:
      guard checkUniqueKeys(n) else { return false }
      try descend()
      defer { ascend() }
      var done: Set<String> = []
      var i = 0
      while i + 1 < n.content.count {
        let keyNode = n.content[i]
        defer { i += 2 }
        guard let name = try decodeString(keyNode) else { continue }
        guard fields.contains(name) else { continue }
        if done.contains(name) {
          errors.append("line \(keyNode.line): field \(name) already set in type \(typeName)")
          continue
        }
        done.insert(name)
        try field(&self, name, n.content[i + 1])
      }
      return true
    case .scalar:
      let (tag, resolved) = try resolveScalar(n)
      if resolved == .null {
        return false
      }
      terror(n, tag, typeName)
    case .sequence:
      terror(n, YAMLTags.seq, typeName)
    default:
      break
    }
    return false
  }

  /// The most duplicate-key errors reported for one mapping. go-yaml reports every pair of equal
  /// keys, n(n-1)/2 errors for a key repeated n times; these are the first of them.
  static let maxDuplicateKeyErrors = 1000

  private struct KeyIdentity: Hashable {
    var kind: YAMLNode.Kind
    var value: String
  }

  /// go-yaml's `checkUniqueKeys`: reports each key equal (same kind and text) to an earlier one,
  /// for every earlier one, ordered by the earlier key. go-yaml compares every pair of keys; the
  /// keys are grouped by hashing here, so a mapping without duplicates is checked in linear time.
  private mutating func checkUniqueKeys(_ n: YAMLNode) -> Bool {
    var groups: [KeyIdentity: [Int]] = [:]
    var hasDuplicates = false
    var i = 0
    while i < n.content.count {
      let key = KeyIdentity(kind: n.content[i].kind, value: n.content[i].value)
      let count = groups[key, default: []].count
      groups[key, default: []].append(i)
      hasDuplicates = hasDuplicates || count > 0
      i += 2
    }
    guard hasDuplicates else { return true }
    var seen: [KeyIdentity: Int] = [:]
    var reported = 0
    i = 0
    while i < n.content.count && reported < Self.maxDuplicateKeyErrors {
      let ni = n.content[i]
      let key = KeyIdentity(kind: ni.kind, value: ni.value)
      let position = seen[key, default: 0]
      seen[key] = position + 1
      if let indices = groups[key] {
        for j in indices[(position + 1)...] {
          guard reported < Self.maxDuplicateKeyErrors else { break }
          let nj = n.content[j]
          errors.append("line \(nj.line): mapping key \(goQuote(nj.value)) already defined at line \(ni.line)")
          reported += 1
        }
      }
      i += 2
    }
    return false
  }
}

/// Quotes a string the way Go's `%q` / `%#v` verbs do for printable text.
func goQuote(_ s: String) -> String {
  var r = "\""
  for u in s.unicodeScalars {
    switch u {
    case "\"": r += "\\\""
    case "\\": r += "\\\\"
    case "\n": r += "\\n"
    case "\t": r += "\\t"
    case "\r": r += "\\r"
    default:
      if u.value < 0x20 || u.value == 0x7f {
        let hex = String(u.value, radix: 16)
        r += "\\x" + (hex.count < 2 ? "0" + hex : hex)
      } else if (0x80...0x9f).contains(u.value) || u.value == 0xfeff {
        let hex = String(u.value, radix: 16)
        r += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      } else {
        r.unicodeScalars.append(u)
      }
    }
  }
  return r + "\""
}

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
//
// Ported from cel-go common/types/unknown.go.

/// A qualifier applied to a variable in an ``AttributeTrail``: a field name or a map / list key.
public enum AttributeQualifier: Sendable, Hashable, CustomStringConvertible {
  /// A boolean map key.
  case bool(Bool)
  /// An integer map key or list index.
  case int(Int64)
  /// An unsigned map key.
  case uint(UInt64)
  /// A field name or string map key.
  case string(String)

  /// Whether two qualifiers are equal, treating `int` and `uint` qualifiers with the same numeric
  /// value as equal.
  func matches(_ other: AttributeQualifier) -> Bool {
    switch (self, other) {
    case (.int(let i), .uint(let u)), (.uint(let u), .int(let i)):
      return i >= 0 && UInt64(i) == u
    case (.string(let a), .string(let b)):
      return utf8Equal(a, b)
    default:
      return self == other
    }
  }

  /// The qualifier formatted as in cel-go: `[1]`, `[2u]`, `.field` or `["key with spaces"]`.
  public var description: String {
    switch self {
    case .bool(let b): return "[\(b)]"
    case .int(let i): return "[\(i)]"
    case .uint(let u): return "[\(u)u]"
    case .string(let s):
      if AttributeQualifier.isIdentifier(s) {
        return ".\(s)"
      }
      return "[\(goQuote(s))]"
    }
  }

  private static func isIdentifier(_ s: String) -> Bool {
    s.unicodeScalars.allSatisfy { c in
      switch c.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
        .decimalNumber:
        return true
      default:
        return c == "_"
      }
    }
  }
}

/// A variable with an optional path of qualifiers, identifying the data an unknown depends on.
public struct AttributeTrail: Sendable, Hashable, CustomStringConvertible {
  /// The variable name, or the empty string for an unspecified attribute (for example an
  /// unresolved function call).
  public var variable: String
  /// The field selections and indices applied to the variable.
  public var qualifierPath: [AttributeQualifier]

  /// Creates an attribute trail for a variable and qualifier path.
  public init(variable: String, qualifierPath: [AttributeQualifier] = []) {
    self.variable = variable
    self.qualifierPath = qualifierPath
  }

  /// The attribute used when no variable is known.
  public static let unspecified = AttributeTrail(variable: "")

  /// Returns the trail extended with a qualifier.
  public func qualified(by qualifier: AttributeQualifier) -> AttributeTrail {
    var copy = self
    copy.qualifierPath.append(qualifier)
    return copy
  }

  /// Whether two trails have the same variable and equivalent qualifier paths.
  public func matches(_ other: AttributeTrail) -> Bool {
    guard variable == other.variable, qualifierPath.count == other.qualifierPath.count else {
      return false
    }
    return zip(qualifierPath, other.qualifierPath).allSatisfy { $0.matches($1) }
  }

  /// The trail formatted as in cel-go, such as `a.b[1]`, or `<unspecified>`.
  public var description: String {
    if variable.isEmpty {
      return "<unspecified>"
    }
    return variable + qualifierPath.map(\.description).joined()
  }
}

/// The set of expression ids, with their attribute trails, that caused a value to be unknown.
public struct UnknownSet: Sendable, Equatable, CustomStringConvertible {
  /// Attribute trails keyed by expression id.
  public private(set) var attributeTrails: [Int64: [AttributeTrail]]

  /// Creates an unknown for the expression `id` and the attribute it depends on.
  public init(expressionID id: Int64, attribute: AttributeTrail = .unspecified) {
    attributeTrails = [id: [attribute]]
  }

  private init(attributeTrails: [Int64: [AttributeTrail]]) {
    self.attributeTrails = attributeTrails
  }

  /// The unknown expression ids in ascending order.
  public var expressionIDs: [Int64] {
    attributeTrails.keys.sorted()
  }

  /// The attribute trails recorded for an expression id.
  public func attributeTrails(forExpressionID id: Int64) -> [AttributeTrail]? {
    attributeTrails[id]
  }

  /// Whether any trail is unspecified, which typically indicates an unresolved function call
  /// rather than a missing variable.
  public var hasUnknownFunction: Bool {
    attributeTrails.values.contains { trails in trails.contains { $0.variable.isEmpty } }
  }

  /// Whether `other` is a subset of this set.
  public func contains(_ other: UnknownSet) -> Bool {
    for (id, otherTrails) in other.attributeTrails {
      guard let trails = attributeTrails[id], trails.count == otherTrails.count else {
        return false
      }
      for ot in otherTrails where !trails.contains(where: { $0.matches(ot) }) {
        return false
      }
    }
    return true
  }

  /// Returns the union of two unknown sets, de-duplicating trails per expression id.
  public func merging(_ other: UnknownSet) -> UnknownSet {
    var out = attributeTrails
    for (id, trails) in other.attributeTrails {
      guard var existing = out[id] else {
        out[id] = trails
        continue
      }
      for trail in trails where !existing.contains(where: { $0.matches(trail) }) {
        existing.append(trail)
      }
      out[id] = existing
    }
    return UnknownSet(attributeTrails: out)
  }

  /// Merges two optional unknown sets. Port of cel-go `types.MergeUnknowns`.
  package static func merge(_ lhs: UnknownSet?, _ rhs: UnknownSet?) -> UnknownSet? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return lhs.merging(rhs)
  }

  /// The set formatted as in cel-go, `attr (id)` per expression id, in ascending id order.
  public var description: String {
    expressionIDs.map { id in
      let attrs = attributeTrails[id] ?? []
      if attrs.count == 1 {
        return "\(attrs[0]) (\(id))"
      }
      return "[\(attrs.map(\.description).joined(separator: " "))] (\(id))"
    }.joined(separator: ", ")
  }
}

extension Value {
  /// Merges an unknown argument into an accumulated unknown set.
  ///
  /// Port of cel-go `types.MaybeMergeUnknowns`: returns the merged set and `true` when the result
  /// is unknown.
  package static func maybeMergeUnknowns(_ value: Value, _ unknown: UnknownSet?) -> (UnknownSet?, Bool) {
    guard case .unknown(let src) = value else {
      return (unknown, unknown != nil)
    }
    return (UnknownSet.merge(src, unknown), true)
  }
}

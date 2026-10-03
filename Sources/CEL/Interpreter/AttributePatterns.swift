// Copyright 2020 Google LLC
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
// Ported from cel-go interpreter/attribute_patterns.go.

/// A top-level variable with qualifier patterns, marking matching attributes as unknown during
/// partial evaluation (cel-go `AttributePattern`).
///
/// The variable name must be the fully qualified name produced by namespace resolution: with the
/// container `a.b`, the variable `c` is matched by the pattern `a.b.c`. Qualifier patterns are
/// map-key-typed values or wildcards: `ns.myvar["complex-value"]`, `ns.myvar["complex-value"][0]`,
/// `ns.myvar["complex-value"].*.name`.
package struct AttributePattern: Sendable, Hashable {
  /// The fully qualified variable name.
  package let variable: String
  /// The qualifier patterns, applied in order.
  package private(set) var qualifierPatterns: [AttributeQualifierPattern]

  package init(_ variable: String) {
    self.variable = variable
    self.qualifierPatterns = []
  }

  /// Adds a string qualifier pattern: a field name or string map key.
  package func qualString(_ pattern: String) -> AttributePattern {
    adding(.init(value: .string(pattern)))
  }

  /// Adds an int qualifier pattern: a map key or list index.
  package func qualInt(_ pattern: Int64) -> AttributePattern {
    adding(.init(value: .int(pattern)))
  }

  /// Adds a uint qualifier pattern for a map key.
  package func qualUint(_ pattern: UInt64) -> AttributePattern {
    adding(.init(value: .uint(pattern)))
  }

  /// Adds a bool qualifier pattern for a map key.
  package func qualBool(_ pattern: Bool) -> AttributePattern {
    adding(.init(value: .bool(pattern)))
  }

  /// Adds a wildcard matching any single qualifier.
  package func wildcard() -> AttributePattern {
    adding(.init(value: nil))
  }

  private func adding(_ pattern: AttributeQualifierPattern) -> AttributePattern {
    var copy = self
    copy.qualifierPatterns.append(pattern)
    return copy
  }

  /// Whether the fully qualified variable name matches the pattern's variable.
  package func variableMatches(_ variable: String) -> Bool {
    self.variable == variable
  }
}

/// A wildcard or valued qualifier pattern (cel-go `AttributeQualifierPattern`).
package struct AttributeQualifierPattern: Sendable, Hashable {
  /// The value to match, or `nil` for a wildcard.
  package let value: AttributeQualifier?

  package var isWildcard: Bool { value == nil }

  /// Whether the qualifier matches: always for a wildcard, else when the qualifier's constant value
  /// equals the pattern value.
  package func matches(_ qualifier: any Qualifier) -> Bool {
    guard let value else {
      return true
    }
    guard let equator = qualifier as? any QualifierValueEquator else {
      return false
    }
    return equator.qualifierValueEquals(value)
  }
}

/// An attribute factory that marks attributes matching the unknown patterns of a partial activation
/// as unknown (cel-go `partialAttributeFactory`).
package struct PartialAttributeFactory: AttributeFactory {
  package let base: DefaultAttributeFactory

  package init(container: Container, provider: any TypeProvider, errorOnBadPresenceTest: Bool = false) {
    self.base = DefaultAttributeFactory(
      container: container, provider: provider, errorOnBadPresenceTest: errorOnBadPresenceTest)
  }

  /// Wraps the absolute attribute in a matcher that tests the unknown patterns on resolution.
  package func absoluteAttribute(id: Int64, names: [String]) -> any NamespacedAttribute {
    let attr = base.makeAbsoluteAttribute(id: id, names: names, factory: self)
    return AttributeMatcher(attribute: attr, matcherQualifiers: [], factory: self)
  }

  package func conditionalAttribute(
    id: Int64, expr: any Interpretable, truthy: any Attribute, falsy: any Attribute
  ) -> any Attribute {
    ConditionalAttribute(condID: id, expr: expr, truthy: truthy, falsy: falsy, factory: self)
  }

  /// A maybe attribute whose candidates are built by this factory.
  package func maybeAttribute(id: Int64, name: String) -> any Attribute {
    MaybeAttribute(
      attrID: id, attrs: [absoluteAttribute(id: id, names: maybeNames(name, base.container))],
      factory: self)
  }

  package func relativeAttribute(id: Int64, operand: any Interpretable) -> any Attribute {
    RelativeAttribute(attrID: id, operand: operand, qualifiers: [], factory: self)
  }

  package func newQualifier(
    objType: CELType?, qualID: Int64, value: QualifierInput, optional: Bool
  ) throws(ResolveError) -> any Qualifier {
    try base.newQualifier(objType: objType, qualID: qualID, value: value, optional: optional)
  }

  /// The unknown for an attribute whose variable and qualifiers match an unknown pattern, or `nil`.
  ///
  /// The pattern `a` makes the attribute `a.b` unknown at the id of `a`; `a.b`, `a.*` and
  /// `a.b[0]` make it unknown at the id of the qualifier `b`. Local variables shadowing a pattern
  /// variable never match. cel-go visits candidate patterns in Go map order; here in pattern order.
  func matchesUnknownPatterns(
    _ frame: ExecutionFrame, _ vars: any PartialActivation, attrID: Int64, variableNames: [String],
    qualifiers: [any Qualifier]
  ) throws(ResolveError) -> UnknownSet? {
    let patterns = vars.unknownAttributePatterns
    var candidates: [Int] = []
    for variable in variableNames {
      if vars.isLocalVariable(variable) {
        continue
      }
      for (i, pattern) in patterns.enumerated() where pattern.variableMatches(variable) {
        if qualifiers.isEmpty {
          return UnknownSet(expressionID: attrID, attribute: AttributeTrail(variable: variable))
        }
        if !candidates.contains(i) {
          candidates.append(i)
        }
      }
    }
    if candidates.isEmpty {
      return nil
    }
    // Resolve attribute qualifiers once into constants shared by every candidate pattern.
    var newQuals: [any Qualifier] = []
    newQuals.reserveCapacity(qualifiers.count)
    for qual in qualifiers {
      if let attr = qual as? any Attribute {
        let val = try attr.resolve(frame)
        newQuals.append(
          try newQualifier(objType: nil, qualID: qual.id, value: .value(val), optional: attr.isOptional))
      } else {
        newQuals.append(qual)
      }
    }
    for index in candidates.sorted() {
      let pattern = patterns[index]
      var isUnknown = true
      var matchExprID = attrID
      let qualPatterns = pattern.qualifierPatterns
      for (i, qual) in newQuals.enumerated() {
        if i >= qualPatterns.count {
          break
        }
        matchExprID = qual.id
        if !qualPatterns[i].matches(qual) {
          isUnknown = false
          break
        }
      }
      if isUnknown {
        var trail = AttributeTrail(variable: pattern.variable)
        for i in 0..<min(qualPatterns.count, newQuals.count) {
          if let cq = newQuals[i] as? any ConstantQualifier {
            switch cq.value {
            case .bool(let b): trail = trail.qualified(by: .bool(b))
            case .double(let d): trail = trail.qualified(by: .int(goInt64(d)))
            case .int(let n): trail = trail.qualified(by: .int(n))
            case .string(let s): trail = trail.qualified(by: .string(s))
            case .uint(let u): trail = trail.qualified(by: .uint(u))
            default: trail = trail.qualified(by: .string(formatGoValue(cq.value)))
            }
          } else {
            trail = trail.qualified(by: .string("*"))
          }
        }
        return UnknownSet(expressionID: matchExprID, attribute: trail)
      }
    }
    return nil
  }
}

/// Go's `int64(f)` for a finite in-range double; out-of-range values give the amd64 result.
private func goInt64(_ d: Double) -> Int64 {
  if d.isFinite, d >= -9_223_372_036_854_775_808.0, d < 9_223_372_036_854_775_808.0 {
    return Int64(d)
  }
  return Int64.min
}

/// A namespaced attribute that first tests the unknown patterns of a partial activation
/// (cel-go `attributeMatcher`).
final class AttributeMatcher: InterpretableNode, NamespacedAttribute {
  let attribute: any NamespacedAttribute
  let matcherQualifiers: [any Qualifier]
  let factory: PartialAttributeFactory

  init(attribute: any NamespacedAttribute, matcherQualifiers: [any Qualifier], factory: PartialAttributeFactory) {
    self.attribute = attribute
    self.matcherQualifiers = matcherQualifiers
    self.factory = factory
  }

  var id: Int64 { attribute.id }

  var isOptional: Bool { attribute.isOptional }

  var candidateVariableNames: [String] { attribute.candidateVariableNames }

  var qualifiers: [any Qualifier] { attribute.qualifiers }

  func addingNamespacedQualifier(_ qualifier: any Qualifier) throws -> any NamespacedAttribute {
    AttributeMatcher(
      attribute: try attribute.addingNamespacedQualifier(qualifier),
      matcherQualifiers: matcherQualifiers + [qualifier], factory: factory)
  }

  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    if let partial = vars.asPartialActivation() {
      // cel-go hands matchesUnknownPatterns what AsPartialActivation finds. Outside comprehensions that is
      // the caller's partial activation, which carries no execution frame, so resolving computed qualifiers
      // there is invisible to observers (no cost, no recorded state). Inside a comprehension it is the
      // folder, whose parent frame passes the context on, so the resolution is observed.
      // Detach the evaluation context in the first case to the same effect.
      let context = vars.context
      if vars.parentFrame == nil {
        vars.context = nil
      }
      defer { vars.context = context }
      if let unknown = try factory.matchesUnknownPatterns(
        vars, partial, attrID: attribute.id, variableNames: candidateVariableNames,
        qualifiers: matcherQualifiers)
      {
        return .unknown(unknown)
      }
    }
    return try attribute.resolve(vars)
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try attrQualify(factory, vars, obj, self)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try attrQualifyIfPresent(factory, vars, obj, self, presenceOnly: presenceOnly)
  }
}

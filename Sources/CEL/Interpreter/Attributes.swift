// Copyright 2019 Google LLC
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
// Ported from cel-go interpreter/attributes.go.
//
// Differences in shape, not behaviour:
// - Attributes are immutable: `addingQualifier` returns a new attribute instead of mutating the
//   receiver, so a planned program is `Sendable` without locks. The planner threads the returned
//   attributes through exactly where cel-go relies on mutation.
// - Resolution works on `Value`s; cel-go's specialised qualification of native Go maps and slices
//   has no counterpart, so every constant qualifier goes through `refQualify`.
// - Resolution errors are thrown as `ResolveError` (typed throws, no allocation), and converted to
//   error values with cel-go's messages where cel-go wraps them.

/// An error raised while resolving an attribute (cel-go `resolutionError`, or a `*types.Err`).
package enum ResolveError: Error {
  /// None of the candidate variable names is bound.
  case missingAttribute([String])
  /// A list index is out of range.
  case missingIndex(Value)
  /// A map key or field is not present.
  case missingKey(Value)
  /// Any other evaluation error.
  case eval(EvalError)

  /// Whether this is a missing variable, which a maybe attribute treats as "try the next name".
  package var isMissingAttribute: Bool {
    if case .missingAttribute = self { return true }
    return false
  }

  /// The error as a CEL error with cel-go's message.
  package var evalError: EvalError {
    switch self {
    case .missingAttribute(let names):
      return EvalError("no such attribute(s): \(names.joined(separator: ", "))")
    case .missingIndex(let index):
      return EvalError("index out of bounds: \(formatGoValue(index))")
    case .missingKey(let key):
      return EvalError("no such key: \(formatGoValue(key))")
    case .eval(let err):
      return err
    }
  }
}

/// An error raised while planning a program.
package struct PlanError: Error, Sendable, CustomStringConvertible {
  package var message: String

  package init(_ message: String) {
    self.message = message
  }

  package var description: String { message }
}

// MARK: - Protocols

/// A field selection or index on a value (cel-go `Qualifier`).
package protocol Qualifier: Sendable {
  /// The id of the expression the qualifier appears in.
  var id: Int64 { get }

  /// Whether the qualifier is optional (`.?field`, `[?index]`), resolved with ``qualifyIfPresent``.
  var isOptional: Bool { get }

  /// Applies the qualifier to `obj`.
  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value

  /// Applies the qualifier if it is present on `obj`. Returns the value (or `nil` when only presence
  /// was asked for) and whether the qualifier is present.
  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
}

/// A qualifier with a constant value (cel-go `ConstantQualifier`).
package protocol ConstantQualifier: Qualifier {
  /// The constant value of the qualifier.
  var value: Value { get }
}

/// A qualifier that can be compared with an attribute pattern value (cel-go `qualifierValueEquator`).
package protocol QualifierValueEquator {
  func qualifierValueEquals(_ value: AttributeQualifier) -> Bool
}

/// A variable or value with an optional path of qualifiers (cel-go `Attribute`).
package protocol Attribute: Qualifier {
  /// The attribute with a qualifier appended.
  func addingQualifier(_ qualifier: any Qualifier) throws -> any Attribute

  /// Resolves the attribute's value in an activation.
  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value
}

/// A variable within a namespace, with qualifiers (cel-go `NamespacedAttribute`).
package protocol NamespacedAttribute: Attribute {
  /// The possible variable names, in CEL's namespace resolution order.
  var candidateVariableNames: [String] { get }

  /// The qualifiers applied to the variable.
  var qualifiers: [any Qualifier] { get }

  /// The attribute with a qualifier appended.
  func addingNamespacedQualifier(_ qualifier: any Qualifier) throws -> any NamespacedAttribute
}

extension NamespacedAttribute {
  package func addingQualifier(_ qualifier: any Qualifier) throws -> any Attribute {
    try addingNamespacedQualifier(qualifier)
  }
}

/// The value a qualifier is built from: a constant, an attribute resolved at runtime, or a ready
/// qualifier (cel-go passes these as `any`).
package enum QualifierInput {
  case value(Value)
  case attribute(any Attribute)
  case qualifier(any Qualifier)
}

/// Creates attributes and qualifiers (cel-go `AttributeFactory`).
package protocol AttributeFactory: Sendable {
  /// An attribute referring to a top-level variable; several names are candidates in namespace
  /// resolution order.
  func absoluteAttribute(id: Int64, names: [String]) -> any NamespacedAttribute

  /// An attribute choosing between two attributes on the value of `expr`.
  func conditionalAttribute(
    id: Int64, expr: any Interpretable, truthy: any Attribute, falsy: any Attribute
  ) -> any Attribute

  /// An attribute that is either a qualified variable name or a field selection on a shorter name,
  /// for parse-only expressions.
  func maybeAttribute(id: Int64, name: String) -> any Attribute

  /// An attribute qualifying the result of a computation.
  func relativeAttribute(id: Int64, operand: any Interpretable) -> any Attribute

  /// A qualifier for an object of the given type, if known.
  func newQualifier(objType: CELType?, qualID: Int64, value: QualifierInput, optional: Bool)
    throws(ResolveError) -> any Qualifier
}

// MARK: - Factory

/// The standard attribute factory (cel-go `attrFactory`).
package struct DefaultAttributeFactory: AttributeFactory {
  package let container: Container
  package let provider: any TypeProvider
  /// Whether a presence test or optional selection on a non-container value is an error
  /// (cel-go `EnableErrorOnBadPresenceTest`).
  package let errorOnBadPresenceTest: Bool

  package init(container: Container, provider: any TypeProvider, errorOnBadPresenceTest: Bool = false) {
    self.container = container
    self.provider = provider
    self.errorOnBadPresenceTest = errorOnBadPresenceTest
  }

  package func absoluteAttribute(id: Int64, names: [String]) -> any NamespacedAttribute {
    makeAbsoluteAttribute(id: id, names: names, factory: self)
  }

  func makeAbsoluteAttribute(id: Int64, names: [String], factory: any AttributeFactory)
    -> AbsoluteAttribute
  {
    var disambiguateNames = false
    var stripped = names
    for i in stripped.indices where stripped[i].utf8.first == UInt8(ascii: ".") {
      disambiguateNames = true
      stripped[i] = String(decoding: stripped[i].utf8.dropFirst(), as: UTF8.self)
    }
    return AbsoluteAttribute(
      attrID: id, namespaceNames: stripped, disambiguateNames: disambiguateNames, qualifiers: [],
      provider: provider, factory: factory)
  }

  package func conditionalAttribute(
    id: Int64, expr: any Interpretable, truthy: any Attribute, falsy: any Attribute
  ) -> any Attribute {
    ConditionalAttribute(condID: id, expr: expr, truthy: truthy, falsy: falsy, factory: self)
  }

  package func maybeAttribute(id: Int64, name: String) -> any Attribute {
    MaybeAttribute(
      attrID: id, attrs: [absoluteAttribute(id: id, names: maybeNames(name, container))],
      factory: self)
  }

  package func relativeAttribute(id: Int64, operand: any Interpretable) -> any Attribute {
    RelativeAttribute(attrID: id, operand: operand, qualifiers: [], factory: self)
  }

  package func newQualifier(
    objType: CELType?, qualID: Int64, value: QualifierInput, optional: Bool
  ) throws(ResolveError) -> any Qualifier {
    // A field access on a known struct type uses the field's accessor directly.
    if case .value(.string(let name)) = value, let objType, objType.kind == .struct,
      let fieldType = provider.findStructFieldType(objType.runtimeTypeName, fieldName: name)
    {
      return FieldQualifier(
        id: qualID, name: name, fieldType: fieldType, optional: optional,
        errorOnBadPresenceTest: errorOnBadPresenceTest)
    }
    return try makeQualifier(
      id: qualID, value: value, optional: optional, errorOnBadPresenceTest: errorOnBadPresenceTest)
  }
}

/// The candidate names of a maybe attribute: a leading dot means the name is absolute.
func maybeNames(_ name: String, _ container: Container) -> [String] {
  if name.utf8.first == UInt8(ascii: ".") {
    return [name]
  }
  return container.resolveCandidateNames(name)
}

/// cel-go `newQualifier`.
func makeQualifier(id: Int64, value: QualifierInput, optional: Bool, errorOnBadPresenceTest: Bool)
  throws(ResolveError) -> any Qualifier
{
  switch value {
  case .attribute(let attr):
    // Attributes used as qualifiers report the qualification id and their own optionality.
    return AttrQualifier(qualID: id, attribute: attr, optional: optional)
  case .qualifier(let qual):
    return qual
  case .value(let v):
    switch v {
    case .string, .int, .uint, .bool, .double:
      return ValueQualifier(
        id: id, value: v, isOptional: optional, errorOnBadPresenceTest: errorOnBadPresenceTest)
    case .unknown(let unknown):
      return UnknownQualifier(id: id, unknown: unknown)
    default:
      throw .eval(EvalError("invalid qualifier type: \(goTypeName(v))"))
    }
  }
}

/// The Go type name cel-go prints with `%T` for a value, used in a few error messages.
func goTypeName(_ value: Value) -> String {
  switch value {
  case .null: return "types.Null"
  case .bool: return "types.Bool"
  case .int: return "types.Int"
  case .uint: return "types.Uint"
  case .double: return "types.Double"
  case .string: return "types.String"
  case .bytes: return "types.Bytes"
  case .list: return "*types.baseList"
  case .map: return "*types.baseMap"
  case .type: return "*types.Type"
  case .duration: return "types.Duration"
  case .timestamp: return "types.Timestamp"
  case .optional: return "*types.Optional"
  case .object(let o): return o.celType.runtimeTypeName
  case .error: return "*types.Err"
  case .unknown: return "*types.Unknown"
  }
}

// MARK: - Attributes

/// A variable with qualifiers (cel-go `absoluteAttribute`).
final class AbsoluteAttribute: NamespacedAttribute {
  let attrID: Int64
  /// The names the variable could have given the container, in resolution order.
  let namespaceNames: [String]
  /// Whether the names were written with a leading dot and must skip local variables.
  let disambiguateNames: Bool
  let qualifiers: [any Qualifier]
  let provider: any TypeProvider
  let factory: any AttributeFactory

  init(
    attrID: Int64, namespaceNames: [String], disambiguateNames: Bool, qualifiers: [any Qualifier],
    provider: any TypeProvider, factory: any AttributeFactory
  ) {
    self.attrID = attrID
    self.namespaceNames = namespaceNames
    self.disambiguateNames = disambiguateNames
    self.qualifiers = qualifiers
    self.provider = provider
    self.factory = factory
  }

  var id: Int64 { qualifiers.last?.id ?? attrID }

  var isOptional: Bool { false }

  var candidateVariableNames: [String] { namespaceNames }

  func addingNamespacedQualifier(_ qualifier: any Qualifier) throws -> any NamespacedAttribute {
    AbsoluteAttribute(
      attrID: attrID, namespaceNames: namespaceNames, disambiguateNames: disambiguateNames,
      qualifiers: qualifiers + [qualifier], provider: provider, factory: factory)
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try attrQualify(factory, vars, obj, self)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try attrQualifyIfPresent(factory, vars, obj, self, presenceOnly: presenceOnly)
  }

  /// Resolves the first candidate name bound in the activation, or a type name known to the
  /// provider, and applies the qualifiers.
  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    // With a leading dot, local (comprehension) variables are skipped by unwrapping to the input
    // activation.
    var frame = vars
    if disambiguateNames {
      var input: any Activation = vars
      while let next = input.unwrapped {
        input = next
      }
      frame = ExecutionFrame(input, context: vars.context)
    }
    for name in namespaceNames {
      if let obj = frame.resolveName(name) {
        switch obj {
        case .error(let err):
          throw .eval(err)
        case .optional:
          break
        default:
          if qualifiers.isEmpty {
            return obj
          }
        }
        let (out, isOpt) = try applyQualifiers(frame, obj, qualifiers)
        if isOpt {
          if case .unknown = out {
            return out
          }
          return .optional(out)
        }
        return out
      }
      // A type name resolves only when it is not qualified further.
      if qualifiers.isEmpty, let type = provider.findIdent(name) {
        return type
      }
    }
    throw .missingAttribute(namespaceNames)
  }
}

/// `(cond ? a : b).field` (cel-go `conditionalAttribute`).
final class ConditionalAttribute: Attribute {
  let condID: Int64
  let expr: any Interpretable
  let truthy: any Attribute
  let falsy: any Attribute
  let factory: any AttributeFactory

  init(
    condID: Int64, expr: any Interpretable, truthy: any Attribute, falsy: any Attribute,
    factory: any AttributeFactory
  ) {
    self.condID = condID
    self.expr = expr
    self.truthy = truthy
    self.falsy = falsy
    self.factory = factory
  }

  /// The id of a field access after the conditional, else the conditional's own id.
  var id: Int64 {
    let t = truthy.id
    return t == falsy.id ? t : condID
  }

  var isOptional: Bool { false }

  /// Appends the qualifier to both branches.
  func addingQualifier(_ qualifier: any Qualifier) throws -> any Attribute {
    ConditionalAttribute(
      condID: condID, expr: expr, truthy: try truthy.addingQualifier(qualifier),
      falsy: try falsy.addingQualifier(qualifier), factory: factory)
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try attrQualify(factory, vars, obj, self)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try attrQualifyIfPresent(factory, vars, obj, self, presenceOnly: presenceOnly)
  }

  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    let val = expr.eval(vars)
    switch val {
    case .bool(true): return try truthy.resolve(vars)
    case .bool(false): return try falsy.resolve(vars)
    case .unknown: return val
    case .error(let err): throw .eval(err)
    default: throw .eval(.noSuchOverload)
    }
  }
}

/// A parse-only identifier or select chain that is either a qualified variable name or a field
/// selection on a shorter name (cel-go `maybeAttribute`).
final class MaybeAttribute: Attribute {
  let attrID: Int64
  /// The candidate attributes, most specific variable name first.
  let attrs: [any NamespacedAttribute]
  let factory: any AttributeFactory

  init(attrID: Int64, attrs: [any NamespacedAttribute], factory: any AttributeFactory) {
    self.attrID = attrID
    self.attrs = attrs
    self.factory = factory
  }

  var id: Int64 { attrs[0].id }

  var isOptional: Bool { false }

  /// Adds the qualifier to every candidate and, for a string qualifier on an unqualified
  /// candidate, a new candidate for the longer qualified name, searched first.
  ///
  /// With the container `ns`, `a.b` is first `ns.a.b` or `a.b` as variables, then `ns.a['b']` or
  /// `a['b']` as field selections.
  func addingQualifier(_ qualifier: any Qualifier) throws -> any Attribute {
    var str: String?
    if let cq = qualifier as? any ConstantQualifier, case .string(let s) = cq.value {
      str = s
    }
    var augmentedNames: [String] = []
    var newAttrs: [any NamespacedAttribute] = []
    newAttrs.reserveCapacity(attrs.count + 1)
    for attr in attrs {
      if let str, attr.qualifiers.isEmpty {
        augmentedNames = attr.candidateVariableNames.map { $0 + "." + str }
      }
      newAttrs.append(try attr.addingNamespacedQualifier(qualifier))
    }
    if !augmentedNames.isEmpty {
      newAttrs.insert(factory.absoluteAttribute(id: qualifier.id, names: augmentedNames), at: 0)
    }
    return MaybeAttribute(attrID: attrID, attrs: newAttrs, factory: factory)
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try attrQualify(factory, vars, obj, self)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try attrQualifyIfPresent(factory, vars, obj, self, presenceOnly: presenceOnly)
  }

  /// The first candidate that resolves; a missing variable moves on to the next candidate, any other
  /// error is returned. If none resolves, the first missing-variable error.
  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    var maybeErr: ResolveError?
    for attr in attrs {
      do {
        return try attr.resolve(vars)
      } catch {
        if !error.isMissingAttribute {
          throw error
        }
        if maybeErr == nil {
          maybeErr = error
        }
      }
    }
    throw maybeErr ?? .missingAttribute([])
  }
}

/// Qualifiers applied to the result of an expression (cel-go `relativeAttribute`).
final class RelativeAttribute: Attribute {
  let attrID: Int64
  let operand: any Interpretable
  let qualifiers: [any Qualifier]
  let factory: any AttributeFactory

  init(attrID: Int64, operand: any Interpretable, qualifiers: [any Qualifier], factory: any AttributeFactory) {
    self.attrID = attrID
    self.operand = operand
    self.qualifiers = qualifiers
    self.factory = factory
  }

  var id: Int64 { qualifiers.last?.id ?? attrID }

  var isOptional: Bool { false }

  func addingQualifier(_ qualifier: any Qualifier) throws -> any Attribute {
    RelativeAttribute(
      attrID: attrID, operand: operand, qualifiers: qualifiers + [qualifier], factory: factory)
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try attrQualify(factory, vars, obj, self)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try attrQualifyIfPresent(factory, vars, obj, self, presenceOnly: presenceOnly)
  }

  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    let v = operand.eval(vars)
    switch v {
    case .error(let err): throw .eval(err)
    case .unknown: return v
    default: break
    }
    let (out, isOpt) = try applyQualifiers(vars, v, qualifiers)
    if isOpt {
      if case .unknown = out {
        return out
      }
      return .optional(out)
    }
    return out
  }
}

// MARK: - Qualifiers

/// An attribute used as a qualifier, `a[b.c]`, carrying the id of the index expression and its
/// optionality (cel-go `attrQualifier`). Qualification goes through the wrapped attribute.
final class AttrQualifier: Attribute {
  let qualID: Int64
  let attribute: any Attribute
  let optional: Bool

  init(qualID: Int64, attribute: any Attribute, optional: Bool) {
    self.qualID = qualID
    self.attribute = attribute
    self.optional = optional
  }

  var id: Int64 { qualID }

  var isOptional: Bool { optional }

  func addingQualifier(_ qualifier: any Qualifier) throws -> any Attribute {
    AttrQualifier(qualID: qualID, attribute: try attribute.addingQualifier(qualifier), optional: optional)
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try attribute.qualify(vars, obj)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try attribute.qualifyIfPresent(vars, obj, presenceOnly: presenceOnly)
  }

  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    try attribute.resolve(vars)
  }
}

/// A constant `string`, `int`, `uint`, `bool` or `double` qualifier (cel-go `stringQualifier`,
/// `intQualifier`, `uintQualifier`, `boolQualifier` and `doubleQualifier`, which behave
/// identically on CEL values).
final class ValueQualifier: ConstantQualifier, QualifierValueEquator {
  let id: Int64
  let value: Value
  let isOptional: Bool
  let errorOnBadPresenceTest: Bool

  init(id: Int64, value: Value, isOptional: Bool, errorOnBadPresenceTest: Bool) {
    self.id = id
    self.value = value
    self.isOptional = isOptional
    self.errorOnBadPresenceTest = errorOnBadPresenceTest
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    let (out, _) = try refQualify(
      obj, value, presenceTest: false, presenceOnly: false, errorOnBadPresenceTest: errorOnBadPresenceTest)
    return out ?? .null
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try refQualify(
      obj, value, presenceTest: true, presenceOnly: presenceOnly,
      errorOnBadPresenceTest: errorOnBadPresenceTest)
  }

  func qualifierValueEquals(_ pattern: AttributeQualifier) -> Bool {
    switch (value, pattern) {
    case (.string(let s), .string(let p)):
      return utf8Equal(s, p)
    case (.bool(let b), .bool(let p)):
      return b == p
    case (.int, _), (.uint, _), (.double, _):
      // cel-go numericValueEquals: CEL equality of the numbers.
      if case .bool(true) = value.celEquals(pattern.value) {
        return true
      }
      return false
    default:
      return false
    }
  }
}

extension AttributeQualifier {
  /// The qualifier as a CEL value.
  var value: Value {
    switch self {
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .uint(let u): return .uint(u)
    case .string(let s): return .string(s)
    }
  }
}

/// A field of a known struct type, read with the field's accessor (cel-go `fieldQualifier`).
final class FieldQualifier: ConstantQualifier, QualifierValueEquator {
  let id: Int64
  let name: String
  let fieldType: FieldType
  let isOptional: Bool
  let errorOnBadPresenceTest: Bool

  init(id: Int64, name: String, fieldType: FieldType, optional: Bool, errorOnBadPresenceTest: Bool) {
    self.id = id
    self.name = name
    self.fieldType = fieldType
    self.isOptional = optional
    self.errorOnBadPresenceTest = errorOnBadPresenceTest
  }

  var value: Value { .string(name) }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    guard case .object(let o) = obj else {
      let (out, _) = try refQualify(
        obj, value, presenceTest: false, presenceOnly: false,
        errorOnBadPresenceTest: errorOnBadPresenceTest)
      return out ?? .null
    }
    let out = fieldType.getFrom(o)
    if case .error(let err) = out {
      throw .eval(err)
    }
    return out
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    guard case .object(let o) = obj else {
      return try refQualify(
        obj, value, presenceTest: true, presenceOnly: presenceOnly,
        errorOnBadPresenceTest: errorOnBadPresenceTest)
    }
    if !fieldType.isSet(o) {
      return (nil, false)
    }
    if presenceOnly {
      return (nil, true)
    }
    let out = fieldType.getFrom(o)
    if case .error(let err) = out {
      throw .eval(err)
    }
    return (out, true)
  }

  func qualifierValueEquals(_ pattern: AttributeQualifier) -> Bool {
    if case .string(let p) = pattern {
      return utf8Equal(name, p)
    }
    return false
  }
}

/// A qualifier that always yields an unknown (cel-go `unknownQualifier`).
final class UnknownQualifier: ConstantQualifier {
  let id: Int64
  let unknown: UnknownSet

  init(id: Int64, unknown: UnknownSet) {
    self.id = id
    self.unknown = unknown
  }

  var isOptional: Bool { false }

  var value: Value { .unknown(unknown) }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    .unknown(unknown)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    (.unknown(unknown), true)
  }
}

// MARK: - Qualification

/// Applies qualifiers in order. Once an optional qualifier (or an optional input) is seen, the rest
/// are applied only if present, and an absent one yields `optional.none()`. Returns the value and
/// whether the result must be wrapped as an optional (cel-go `applyQualifiers`).
func applyQualifiers(_ vars: ExecutionFrame, _ obj: Value, _ qualifiers: [any Qualifier])
  throws(ResolveError) -> (Value, Bool)
{
  var obj = obj
  var isOpt = false
  if case .optional(let inner) = obj {
    isOpt = true
    guard let inner else {
      return (obj, false)
    }
    obj = inner
  }
  for qual in qualifiers {
    // An optional reached through the path (`{'k': optional.none()}.k.f`) is selected into like a root
    // optional, as the checker types it (optional_type(T).f is optional). cel-go only unwraps the root
    // and reports a missing key here (docs/divergences.md).
    if case .optional(let inner) = obj {
      isOpt = true
      guard let inner else {
        return (obj, false)
      }
      obj = inner
    }
    isOpt = isOpt || qual.isOptional
    if isOpt {
      let (qualObj, present) = try qual.qualifyIfPresent(vars, obj, presenceOnly: false)
      if !present {
        // optional.none(), not wrapped again by the caller.
        return (.optional(nil), false)
      }
      obj = qualObj ?? .null
    } else {
      obj = try qual.qualify(vars, obj)
    }
  }
  return (obj, isOpt)
}

/// Qualifies `obj` with the value of an attribute (cel-go `attrQualify`).
func attrQualify(
  _ factory: any AttributeFactory, _ vars: ExecutionFrame, _ obj: Value, _ qualAttr: any Attribute
) throws(ResolveError) -> Value {
  let val = try qualAttr.resolve(vars)
  let qual = try factory.newQualifier(
    objType: nil, qualID: qualAttr.id, value: .value(val), optional: qualAttr.isOptional)
  return try qual.qualify(vars, obj)
}

/// Qualifies `obj` with the value of an attribute if present (cel-go `attrQualifyIfPresent`).
func attrQualifyIfPresent(
  _ factory: any AttributeFactory, _ vars: ExecutionFrame, _ obj: Value, _ qualAttr: any Attribute,
  presenceOnly: Bool
) throws(ResolveError) -> (Value?, Bool) {
  let val = try qualAttr.resolve(vars)
  let qual = try factory.newQualifier(
    objType: nil, qualID: qualAttr.id, value: .value(val), optional: qualAttr.isOptional)
  return try qual.qualifyIfPresent(vars, obj, presenceOnly: presenceOnly)
}

/// Qualifies a CEL value: map lookup, list index, or field of an indexable object, optionally only
/// testing presence (cel-go `refQualify`).
func refQualify(
  _ obj: Value, _ idx: Value, presenceTest: Bool, presenceOnly: Bool, errorOnBadPresenceTest: Bool
) throws(ResolveError) -> (Value?, Bool) {
  switch obj {
  case .unknown:
    return (obj, true)
  case .error(let err):
    throw .eval(err)
  case .map(let m):
    if let val = m.find(idx) {
      if case .error(let err) = val {
        throw .eval(err)
      }
      return (val, true)
    }
    if presenceTest {
      return (nil, false)
    }
    throw .missingKey(idx)
  case .list(let l):
    let i: Int
    switch Value.indexOrError(idx) {
    case .success(let index): i = index
    case .failure(let err): throw .eval(err)
    }
    if i >= 0 && i < l.count {
      return (l.element(at: i), true)
    }
    if presenceTest {
      return (nil, false)
    }
    throw .missingIndex(idx)
  case .object(let o) where o.traits.contains(.indexer):
    if presenceTest && o.traits.contains(.fieldTester) {
      let presence: Value
      if case .string(let name) = idx {
        presence = o.isFieldSet(name)
      } else {
        presence = Value.maybeNoSuchOverload(idx)
      }
      if case .error(let err) = presence {
        throw .eval(err)
      }
      let isSet: Bool
      if case .bool(true) = presence { isSet = true } else { isSet = false }
      if presenceOnly || !isSet {
        return (nil, isSet)
      }
    }
    let val = obj.get(idx)
    if case .error(let err) = val {
      throw .eval(err)
    }
    return (val, true)
  default:
    if presenceTest && !errorOnBadPresenceTest {
      return (nil, false)
    }
    throw .missingKey(idx)
  }
}

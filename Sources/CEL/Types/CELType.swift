// Copyright 2023 Google LLC
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
// Ported from cel-go common/types/types.go.

/// A CEL type, as used by declarations, the type checker and runtime type values.
///
/// The case list mirrors the type kinds of the CEL specification (`cel.expr.Type`) and is closed:
/// primitives, the well-known `google.protobuf.Any`, `Duration` and `Timestamp` types, `null_type`,
/// lists, maps, type values, message (object) types, abstract (opaque) types, type parameters,
/// nullable wrapper types, `error` and `unknown`. Optional types are the abstract type
/// `optional_type(T)`, see ``optional(_:)``.
///
/// Equality (`==`) is structural. The CEL notions of type identity live in ``isExactType(_:)``,
/// ``isEquivalentType(_:)`` and ``isAssignable(from:)``, ported from cel-go.
public indirect enum CELType: Sendable, Hashable {
  /// The dynamic type, assignable to and from every type. Only exists at type-check time.
  case dyn
  /// The `google.protobuf.Any` type. Only exists at type-check time.
  case any
  /// The `bool` type.
  case bool
  /// The `bytes` type.
  case bytes
  /// The `double` type.
  case double
  /// The `google.protobuf.Duration` type.
  case duration
  /// The type of CEL error values.
  case error
  /// The `int` type.
  case int
  /// The `list(T)` type with element type `T`.
  case list(CELType)
  /// The `map(K, V)` type.
  case map(key: CELType, value: CELType)
  /// The `null_type` type.
  case null
  /// An abstract type with a name and type parameters, for example `optional_type(int)`.
  case opaque(name: String, parameters: [CELType])
  /// The `string` type.
  case string
  /// A message (struct) type identified by its fully qualified name.
  case object(String)
  /// The `google.protobuf.Timestamp` type.
  case timestamp
  /// The type of type values, optionally parameterized with the type it describes: `type(int)`.
  case type(CELType?)
  /// A type parameter, resolved during type checking.
  case typeParam(String)
  /// The `uint` type.
  case uint
  /// The type of unknown values.
  case unknown
  /// A nullable primitive, the type of the `google.protobuf.*Value` wrapper messages.
  case wrapper(CELType)
}

extension CELType {
  /// The category of a type, used to differentiate quickly between simple and complex types.
  ///
  /// A wrapper type has the kind of the type it wraps, as in cel-go.
  public enum Kind: Sendable, Hashable {
    /// The kind is not specified.
    case unspecified
    /// ``CELType/dyn``.
    case dyn
    /// ``CELType/any``.
    case any
    /// ``CELType/bool``.
    case bool
    /// ``CELType/bytes``.
    case bytes
    /// ``CELType/double``.
    case double
    /// ``CELType/duration``.
    case duration
    /// ``CELType/error``.
    case error
    /// ``CELType/int``.
    case int
    /// ``CELType/list(_:)``.
    case list
    /// ``CELType/map(key:value:)``.
    case map
    /// ``CELType/null``.
    case nullType
    /// ``CELType/opaque(name:parameters:)``.
    case opaque
    /// ``CELType/string``.
    case string
    /// ``CELType/object(_:)``.
    case `struct`
    /// ``CELType/timestamp``.
    case timestamp
    /// ``CELType/type(_:)``.
    case type
    /// ``CELType/typeParam(_:)``.
    case typeParam
    /// ``CELType/uint``.
    case uint
    /// ``CELType/unknown``.
    case unknown
  }

  /// The general category of the type.
  public var kind: Kind {
    switch self {
    case .dyn: return .dyn
    case .any: return .any
    case .bool: return .bool
    case .bytes: return .bytes
    case .double: return .double
    case .duration: return .duration
    case .error: return .error
    case .int: return .int
    case .list: return .list
    case .map: return .map
    case .null: return .nullType
    case .opaque: return .opaque
    case .string: return .string
    case .object: return .struct
    case .timestamp: return .timestamp
    case .type: return .type
    case .typeParam: return .typeParam
    case .uint: return .uint
    case .unknown: return .unknown
    case .wrapper(let wrapped): return wrapped.kind
    }
  }

  /// The type-erased, fully qualified runtime type name, for example `list` for `list(int)`.
  public var runtimeTypeName: String {
    switch self {
    case .dyn: return "dyn"
    case .any: return "google.protobuf.Any"
    case .bool: return "bool"
    case .bytes: return "bytes"
    case .double: return "double"
    case .duration: return "google.protobuf.Duration"
    case .error: return "error"
    case .int: return "int"
    case .list: return "list"
    case .map: return "map"
    case .null: return "null_type"
    case .opaque(let name, _): return name
    case .string: return "string"
    case .object(let name): return name
    case .timestamp: return "google.protobuf.Timestamp"
    case .type: return "type"
    case .typeParam(let name): return name
    case .uint: return "uint"
    case .unknown: return "unknown"
    case .wrapper(let wrapped): return wrapped.runtimeTypeName
    }
  }

  /// The type parameters: the element type of a list, the key and value types of a map, the
  /// described type of a parameterized `type`, or the parameters of an abstract type.
  public var parameters: [CELType] {
    switch self {
    case .list(let elem): return [elem]
    case .map(let key, let value): return [key, value]
    case .opaque(_, let params): return params
    case .type(let param): return param.map { [$0] } ?? []
    case .wrapper(let wrapped): return wrapped.parameters
    default: return []
    }
  }

  /// The fully qualified, parameterized type-check type name, `wrapper(int)` for a wrapper type.
  public var declaredTypeName: String {
    if case .wrapper = self {
      return "wrapper(\(runtimeTypeName))"
    }
    return runtimeTypeName
  }

  /// Whether the type is `dyn`, `google.protobuf.Any` or a type parameter.
  var isDynamic: Bool {
    switch kind {
    case .dyn, .any, .typeParam: return true
    default: return false
    }
  }

  /// The capabilities of values of this type.
  ///
  /// Message types support field testing and indexing; abstract types have no traits by default.
  /// Values backed by an ``ObjectValue`` report their own traits.
  public var traits: TypeTraits {
    switch self {
    case .any: return [.fieldTester, .indexer]
    case .bool: return [.comparer, .negator]
    case .bytes: return [.adder, .comparer, .sizer]
    case .double: return [.adder, .comparer, .divider, .multiplier, .negator, .subtractor]
    case .duration: return [.adder, .comparer, .negator, .receiver, .subtractor]
    case .int: return [.adder, .comparer, .divider, .modder, .multiplier, .negator, .subtractor]
    case .list: return [.adder, .container, .indexer, .iterable, .sizer]
    case .map: return [.container, .indexer, .iterable, .sizer]
    case .string: return [.adder, .comparer, .matcher, .receiver, .sizer]
    case .object: return [.fieldTester, .indexer]
    case .timestamp: return [.adder, .comparer, .receiver, .subtractor]
    case .uint: return [.adder, .comparer, .divider, .modder, .multiplier, .subtractor]
    case .wrapper(let wrapped): return wrapped.traits
    case .dyn, .error, .null, .opaque, .type, .typeParam, .unknown: return []
    }
  }

  /// Whether the type has all of the given traits.
  public func hasTrait(_ trait: TypeTraits) -> Bool {
    traits.isSuperset(of: trait)
  }
}

// MARK: - Constructors

extension CELType {
  /// The runtime list type, `list(dyn)`.
  public static let listOfDyn = CELType.list(.dyn)
  /// The runtime map type, `map(dyn, dyn)`.
  public static let mapOfDyn = CELType.map(key: .dyn, value: .dyn)

  /// The abstract type `optional_type(T)`.
  public static func optional(_ parameter: CELType) -> CELType {
    .opaque(name: "optional_type", parameters: [parameter])
  }

  /// The runtime optional type, `optional_type(dyn)`.
  public static let optionalOfDyn = CELType.optional(.dyn)

  /// Creates a reference to an externally defined type, such as a protobuf message type.
  ///
  /// Well-known protobuf type names are mapped to their CEL equivalents, so
  /// `google.protobuf.Int64Value` becomes `wrapper(int)` and `google.protobuf.Struct` becomes
  /// `map(string, dyn)`.
  public static func objectType(_ typeName: String) -> CELType {
    checkedWellKnowns[typeName] ?? .object(typeName)
  }

  /// The well-known protobuf types and their CEL type equivalents.
  static let checkedWellKnowns: [String: CELType] = [
    // Wrapper types.
    "google.protobuf.BoolValue": .wrapper(.bool),
    "google.protobuf.BytesValue": .wrapper(.bytes),
    "google.protobuf.DoubleValue": .wrapper(.double),
    "google.protobuf.FloatValue": .wrapper(.double),
    "google.protobuf.Int64Value": .wrapper(.int),
    "google.protobuf.Int32Value": .wrapper(.int),
    "google.protobuf.UInt64Value": .wrapper(.uint),
    "google.protobuf.UInt32Value": .wrapper(.uint),
    "google.protobuf.StringValue": .wrapper(.string),
    // Well-known types.
    "google.protobuf.Any": .any,
    "google.protobuf.Duration": .duration,
    "google.protobuf.Timestamp": .timestamp,
    // JSON types.
    "google.protobuf.ListValue": .list(.dyn),
    "google.protobuf.NullValue": .null,
    "google.protobuf.Struct": .map(key: .string, value: .dyn),
    "google.protobuf.Value": .dyn,
  ]
}

// MARK: - Type relations

extension CELType {
  /// Whether the two types are exactly the same, including type parameter names.
  ///
  /// As in cel-go, a wrapper type is exactly the type it wraps.
  public func isExactType(_ other: CELType) -> Bool {
    isTypeInternal(other, checkTypeParamName: true)
  }

  /// Whether the two types are equivalent, ignoring type parameter names.
  public func isEquivalentType(_ other: CELType) -> Bool {
    isTypeInternal(other, checkTypeParamName: false)
  }

  private func isTypeInternal(_ other: CELType, checkTypeParamName: Bool) -> Bool {
    let params = parameters
    let otherParams = other.parameters
    if kind != other.kind || params.count != otherParams.count {
      return false
    }
    if (checkTypeParamName || kind != .typeParam) && runtimeTypeName != other.runtimeTypeName {
      return false
    }
    for (p, o) in zip(params, otherParams)
    where !p.isTypeInternal(o, checkTypeParamName: checkTypeParamName) {
      return false
    }
    return true
  }

  /// Whether a value of type `fromType` may be assigned to this type during type checking.
  public func isAssignable(from fromType: CELType) -> Bool {
    if case .wrapper(let wrapped) = self {
      return CELType.null.isAssignable(from: fromType) || wrapped.isAssignable(from: fromType)
    }
    return defaultIsAssignable(from: fromType)
  }

  private func defaultIsAssignable(from fromType: CELType) -> Bool {
    if self == fromType || isDynamic {
      return true
    }
    let params = parameters
    let fromParams = fromType.parameters
    if kind != fromType.kind || runtimeTypeName != fromType.runtimeTypeName
      || params.count != fromParams.count
    {
      return false
    }
    for (p, f) in zip(params, fromParams) where !p.isAssignable(from: f) {
      return false
    }
    return true
  }

  /// Whether a runtime value may be passed where this type is declared.
  ///
  /// Parameterized types are erased at runtime, so only the first element of a list or the first
  /// entry of a map is inspected.
  public func isAssignableRuntime(_ value: Value) -> Bool {
    if case .wrapper(let wrapped) = self {
      return CELType.null.isAssignableRuntime(value) || wrapped.isAssignableRuntime(value)
    }
    let valueTypeName = value.runtimeTypeName
    if !(isDynamic || runtimeTypeName == valueTypeName) {
      return false
    }
    switch self {
    case .list(let elemType):
      guard case .list(let list) = value, list.count > 0 else { return true }
      return elemType.isAssignableRuntime(list.element(at: 0))
    case .map(let keyType, let valueType):
      guard case .map(let map) = value, let first = map.firstNonNil({ $0 }) else {
        return true
      }
      let elem = map.value(forKey: first) ?? .null
      return keyType.isAssignableRuntime(first.value) && valueType.isAssignableRuntime(elem)
    default:
      return true
    }
  }
}

// MARK: - Description

extension CELType: CustomStringConvertible {
  /// A human-readable definition of the type, such as `map(string, list(int))` or `<A>`.
  public var description: String {
    if case .typeParam = self {
      return "<\(declaredTypeName)>"
    }
    let params = parameters
    if params.isEmpty {
      return declaredTypeName
    }
    return "\(declaredTypeName)(\(params.map(\.description).joined(separator: ", ")))"
  }
}

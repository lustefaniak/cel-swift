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
// Ported from cel-go common/types/ref/reference.go (ref.Val) and common/types/util.go.

/// A CEL runtime value.
///
/// The case list is closed by the CEL specification: the primitive values, `null`, lists, maps,
/// type values, the well-known duration and timestamp values, optionals, objects (protobuf
/// messages, native Swift types and abstract values), and the two evaluation outcomes that are
/// values in CEL, errors and unknowns.
///
/// Lists, maps and objects are protocols so host data can be adapted lazily instead of copied;
/// ``ArrayList`` and ``OrderedMap`` are the concrete implementations used for literals.
///
/// `==` on `Value` is structural (same case and contents, `1 != 1u`). CEL equality, where
/// `1 == 1u == 1.0`, is a separate operation used by the interpreter.
public enum Value: Sendable {
  /// The `null` value.
  case null
  /// A `bool` value.
  case bool(Bool)
  /// An `int` value.
  case int(Int64)
  /// A `uint` value.
  case uint(UInt64)
  /// A `double` value.
  case double(Double)
  /// A `string` value. CEL operates on its Unicode scalars, never on `Character`s.
  case string(String)
  /// A `bytes` value.
  case bytes([UInt8])
  /// A list value.
  case list(any ListValue)
  /// A map value.
  case map(any MapValue)
  /// A type value, such as the result of `type(1)`.
  case type(CELType)
  /// A `google.protobuf.Duration` value.
  case duration(CELDuration)
  /// A `google.protobuf.Timestamp` value.
  case timestamp(CELTimestamp)
  /// An optional value: `optional.of(x)` holds `x`, `optional.none()` holds `nil`.
  indirect case optional(Value?)
  /// A message, native object or abstract value.
  case object(any ObjectValue)
  /// An evaluation error.
  case error(EvalError)
  /// An unknown value from partial evaluation.
  case unknown(UnknownSet)
}

extension Value {
  /// The runtime type of the value.
  ///
  /// Parameterized types are erased: every list is `list(dyn)`, every map `map(dyn, dyn)`.
  public var celType: CELType {
    switch self {
    case .null: return .null
    case .bool: return .bool
    case .int: return .int
    case .uint: return .uint
    case .double: return .double
    case .string: return .string
    case .bytes: return .bytes
    case .list: return .listOfDyn
    case .map: return .mapOfDyn
    case .type: return .type(nil)
    case .duration: return .duration
    case .timestamp: return .timestamp
    case .optional: return .optionalOfDyn
    case .object(let object): return object.celType
    case .error: return .error
    case .unknown: return .unknown
    }
  }

  /// The runtime type name of the value, for example `int`, `list` or `google.protobuf.Duration`.
  public var runtimeTypeName: String {
    switch self {
    case .null: return "null_type"
    case .bool: return "bool"
    case .int: return "int"
    case .uint: return "uint"
    case .double: return "double"
    case .string: return "string"
    case .bytes: return "bytes"
    case .list: return "list"
    case .map: return "map"
    case .type: return "type"
    case .duration: return "google.protobuf.Duration"
    case .timestamp: return "google.protobuf.Timestamp"
    case .optional: return "optional_type"
    case .object(let object): return object.celType.runtimeTypeName
    case .error: return "error"
    case .unknown: return "unknown"
    }
  }

  /// The capabilities of the value's type.
  public var traits: TypeTraits {
    if case .object(let object) = self {
      return object.traits
    }
    return celType.traits
  }

  /// Whether the value is an error.
  public var isError: Bool {
    if case .error = self { return true }
    return false
  }

  /// Whether the value is unknown.
  public var isUnknown: Bool {
    if case .unknown = self { return true }
    return false
  }

  /// Whether the value is an error or unknown, the values that short-circuit strict functions.
  public var isUnknownOrError: Bool {
    switch self {
    case .error, .unknown: return true
    default: return false
    }
  }

  /// Whether the value is a primitive: `bool`, `bytes`, `double`, `int`, `string` or `uint`.
  ///
  /// Well-known types such as durations and timestamps are not primitives.
  public var isPrimitive: Bool {
    switch self {
    case .bool, .bytes, .double, .int, .string, .uint: return true
    default: return false
    }
  }

  /// Whether the value is the zero value of its type: `false`, `0`, `""`, an empty list, and so on.
  public var isZeroValue: Bool {
    switch self {
    case .null: return true
    case .bool(let b): return !b
    case .int(let i): return i == 0
    case .uint(let u): return u == 0
    case .double(let d): return d == 0
    case .string(let s): return s.utf8.isEmpty
    case .bytes(let b): return b.isEmpty
    case .list(let l): return l.count == 0
    case .map(let m): return m.count == 0
    case .duration(let d): return d.nanoseconds == 0
    case .timestamp(let t): return t.isGoZeroTime
    case .object(let o): return o.isZeroValue
    case .optional, .type, .error, .unknown: return false
    }
  }
}

// MARK: - Structural equality

extension Value: Equatable {
  /// Structural equality: the same case with equal contents.
  ///
  /// Strings compare by Unicode scalars (not canonical equivalence), doubles with IEEE `==`,
  /// lists and maps element-wise, objects with ``ObjectValue/isEqual(to:)``, errors by message and
  /// type values by their full type. Use the CEL `==` operator semantics for evaluation instead.
  public static func == (lhs: Value, rhs: Value) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.uint(let a), .uint(let b)): return a == b
    case (.double(let a), .double(let b)): return a == b
    case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
    case (.bytes(let a), .bytes(let b)): return a == b
    case (.list(let a), .list(let b)):
      guard a.count == b.count else { return false }
      for i in 0..<a.count where a.element(at: i) != b.element(at: i) {
        return false
      }
      return true
    case (.map(let a), .map(let b)):
      guard a.count == b.count else { return false }
      for key in a.keys {
        guard let other = b.value(forKey: key), let mine = a.value(forKey: key), mine == other
        else { return false }
      }
      return true
    case (.type(let a), .type(let b)): return a == b
    case (.duration(let a), .duration(let b)): return a == b
    case (.timestamp(let a), .timestamp(let b)): return a == b
    case (.optional(let a), .optional(let b)): return a == b
    case (.object(let a), .object(let b)): return a.isEqual(to: b)
    case (.error(let a), .error(let b)): return a == b
    case (.unknown(let a), .unknown(let b)): return a == b
    default: return false
    }
  }
}

// MARK: - Literal conformances

extension Value: ExpressibleByBooleanLiteral {
  /// Creates a `bool` value.
  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }
}

extension Value: ExpressibleByIntegerLiteral {
  /// Creates an `int` value.
  public init(integerLiteral value: Int64) {
    self = .int(value)
  }
}

extension Value: ExpressibleByFloatLiteral {
  /// Creates a `double` value.
  public init(floatLiteral value: Double) {
    self = .double(value)
  }
}

extension Value: ExpressibleByStringLiteral {
  /// Creates a `string` value.
  public init(stringLiteral value: String) {
    self = .string(value)
  }
}

extension Value: ExpressibleByArrayLiteral {
  /// Creates a list value backed by an ``ArrayList``.
  public init(arrayLiteral elements: Value...) {
    self = .list(ArrayList(elements))
  }
}

extension Value: ExpressibleByDictionaryLiteral {
  /// Creates a map value backed by an ``OrderedMap``.
  ///
  /// - Precondition: every key is a `bool`, `int`, `uint` or `string` value, without duplicates.
  public init(dictionaryLiteral elements: (MapKey, Value)...) {
    var map = OrderedMap()
    for (key, value) in elements {
      map[key] = value
    }
    self = .map(map)
  }
}

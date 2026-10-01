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
// Ported from cel-go common/types/map.go and common/types/traits/mapper.go.

/// A CEL map key: `bool`, `int`, `uint` or `string`.
///
/// String keys compare and hash by their Unicode scalars, not by canonical equivalence, so
/// `"é"` (U+00E9) and `"e\u{301}"` are different keys, as in every other CEL implementation.
public enum MapKey: Sendable, Hashable, CustomStringConvertible {
  /// A `bool` key.
  case bool(Bool)
  /// An `int` key.
  case int(Int64)
  /// A `uint` key.
  case uint(UInt64)
  /// A `string` key.
  case string(String)

  /// Creates a key from a value of one of the key types, or `nil` for any other value.
  public init?(_ value: Value) {
    switch value {
    case .bool(let b): self = .bool(b)
    case .int(let i): self = .int(i)
    case .uint(let u): self = .uint(u)
    case .string(let s): self = .string(s)
    default: return nil
    }
  }

  /// The key as a CEL value.
  public var value: Value {
    switch self {
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .uint(let u): return .uint(u)
    case .string(let s): return .string(s)
    }
  }

  /// The key formatted like a CEL literal.
  public var description: String {
    value.description
  }

  /// Equality by case and contents; strings compare by Unicode scalars.
  public static func == (lhs: MapKey, rhs: MapKey) -> Bool {
    switch (lhs, rhs) {
    case (.bool(let a), .bool(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.uint(let a), .uint(let b)): return a == b
    case (.string(let a), .string(let b)): return utf8Equal(a, b)
    default: return false
    }
  }

  /// Hashes the case and contents; strings hash their UTF-8 bytes.
  public func hash(into hasher: inout Hasher) {
    switch self {
    case .bool(let b):
      hasher.combine(0)
      hasher.combine(b)
    case .int(let i):
      hasher.combine(1)
      hasher.combine(i)
    case .uint(let u):
      hasher.combine(2)
      hasher.combine(u)
    case .string(let s):
      hasher.combine(3)
      withUTF8Bytes(s) { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
      hasher.combine(0xFF as UInt8)
    }
  }
}

extension MapKey: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral
{
  /// Creates a `string` key.
  public init(stringLiteral value: String) {
    self = .string(value)
  }

  /// Creates an `int` key.
  public init(integerLiteral value: Int64) {
    self = .int(value)
  }

  /// Creates a `bool` key.
  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }
}

/// A CEL map.
///
/// Implement this protocol to expose host dictionaries to CEL without copying them: a conformer
/// supplies the entry count, key iteration and exact-key lookup, and nothing is materialized
/// unless a caller asks for it. ``OrderedMap`` is the implementation used for map literals.
///
/// Lookups with CEL's cross-numeric key semantics (`m[1.0]` finds the key `1` or `1u`) are built
/// on ``value(forKey:)``, which only needs to answer exact-key queries.
///
/// ```swift
/// struct Headers: MapValue {
///   let fields: [(name: String, value: String)]
///
///   var count: Int { fields.count }
///
///   func forEachKey(_ body: (MapKey) throws -> Bool) rethrows {
///     for field in fields {
///       if try !body(.string(field.name)) {
///         return
///       }
///     }
///   }
///
///   func value(forKey key: MapKey) -> Value? {
///     guard case .string(let name) = key else { return nil }
///     return fields.first { $0.name == name }.map { .string($0.value) }
///   }
/// }
/// ```
public protocol MapValue: Sendable {
  /// The number of entries.
  var count: Int { get }

  /// Calls `body` with each key in iteration order until `body` returns `false`.
  ///
  /// The order must be the same on every call for the same map, so that comprehensions, equality
  /// and formatting are deterministic; it need not be sorted. Each key is visited once.
  ///
  /// - Parameter body: Called with each key; returns `true` to continue with the next key, `false`
  ///   to stop.
  /// - Throws: Rethrows any error `body` throws, which stops the iteration.
  func forEachKey(_ body: (MapKey) throws -> Bool) rethrows

  /// Returns the value stored under exactly `key`, or `nil`.
  func value(forKey key: MapKey) -> Value?
}

extension MapValue {
  /// The keys in iteration order, collected into an array.
  ///
  /// - Complexity: O(*n*); prefer ``forEachKey(_:)`` when the keys are only iterated.
  public var keys: [MapKey] {
    var keys: [MapKey] = []
    keys.reserveCapacity(count)
    forEachKey { key in
      keys.append(key)
      return true
    }
    return keys
  }
}

/// An insertion-ordered map from ``MapKey`` to ``Value``, used for map literals.
public struct OrderedMap: MapValue {
  /// The keys in insertion order.
  public private(set) var keys: [MapKey]
  private var storage: [MapKey: Value]

  /// Creates an empty map.
  public init() {
    keys = []
    storage = [:]
  }

  /// Creates a map from key-value pairs; a later duplicate key replaces the earlier value.
  public init(_ entries: [(MapKey, Value)]) {
    self.init()
    for (key, value) in entries {
      self[key] = value
    }
  }

  /// The number of entries.
  public var count: Int { keys.count }

  /// Calls `body` with each key in insertion order until `body` returns `false`.
  public func forEachKey(_ body: (MapKey) throws -> Bool) rethrows {
    for key in keys {
      if try !body(key) {
        return
      }
    }
  }

  /// Returns the value stored under `key`, or `nil`.
  public func value(forKey key: MapKey) -> Value? {
    storage[key]
  }

  /// Accesses the value stored under `key`. Assigning `nil` removes the entry.
  public subscript(key: MapKey) -> Value? {
    get { storage[key] }
    set {
      if let newValue {
        if storage.updateValue(newValue, forKey: key) == nil {
          keys.append(key)
        }
      } else if storage.removeValue(forKey: key) != nil {
        keys.removeAll { $0 == key }
      }
    }
  }

  /// Inserts a new entry, returning `false` when the key is already present.
  @discardableResult
  public mutating func insert(_ value: Value, forKey key: MapKey) -> Bool {
    if storage[key] != nil {
      return false
    }
    storage[key] = value
    keys.append(key)
    return true
  }
}

// MARK: - CEL map operations (cel-go baseMap)

extension MapValue {
  /// The first non-nil result of `transform` applied to the keys in iteration order, or `nil`;
  /// the key-iteration counterpart of swift-algorithms' `firstNonNil(_:)`, for loops that stop
  /// with a result such as an error.
  package func firstNonNil<Result>(_ transform: (MapKey) -> Result?) -> Result? {
    var result: Result?
    forEachKey { key in
      result = transform(key)
      return result == nil
    }
    return result
  }

  /// Finds the value for a CEL key value, applying cross-numeric key equality: a `double` key
  /// matches an `int` or `uint` key with the same value, and `int` / `uint` keys match each other.
  ///
  /// Port of cel-go `refValMapAccessor.Find`.
  package func find(_ key: Value) -> Value? {
    if count == 0 {
      return nil
    }
    if let mapKey = MapKey(key), let value = value(forKey: mapKey) {
      return value
    }
    switch key {
    case .double(let d):
      if let i = doubleToInt64Lossless(d), let v = value(forKey: .int(i)) {
        return v
      }
      if let u = doubleToUint64Lossless(d) {
        return value(forKey: .uint(u))
      }
    case .int(let i):
      if let u = int64ToUint64Lossless(i) {
        return value(forKey: .uint(u))
      }
    case .uint(let u):
      if let i = uint64ToInt64Lossless(u) {
        return value(forKey: .int(i))
      }
    default:
      break
    }
    return nil
  }

  /// Returns the value for `key` or a `no such key` error. Port of cel-go `baseMap.Get`.
  package func get(_ key: Value) -> Value {
    if let value = find(key) {
      return value
    }
    return Value.valOrError(key, "no such key: \(formatGoValue(key))")
  }

  /// Whether the map contains `key`. Port of cel-go `baseMap.Contains`.
  package func containsKey(_ key: Value) -> Value {
    .bool(find(key) != nil)
  }

  /// CEL equality with another map. Port of cel-go `baseMap.Equal`.
  package func celEquals(_ other: any MapValue) -> Value {
    if count != other.count {
      return .bool(false)
    }
    var equal = true
    forEachKey { key in
      guard let mine = value(forKey: key), let theirs = other.find(key.value) else {
        equal = false
        return false
      }
      if case .bool(false) = mine.celEquals(theirs) {
        equal = false
        return false
      }
      return true
    }
    return .bool(equal)
  }
}

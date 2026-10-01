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
// Swift-native conversions for `Value`, the counterpart of cel-go's `types.DefaultTypeAdapter`
// (NativeToValue) and `ref.Val.Value()` / `ConvertToNative`. Clients read values through these
// accessors rather than switching over `Value` exhaustively.

extension Value {
  /// Creates an `int` value.
  public init(_ value: Int) {
    self = .int(Int64(value))
  }

  /// Creates an `int` value.
  public init(_ value: Int64) {
    self = .int(value)
  }

  /// Creates an `int` value.
  public init(_ value: Int32) {
    self = .int(Int64(value))
  }

  /// Creates a `uint` value.
  public init(_ value: UInt) {
    self = .uint(UInt64(value))
  }

  /// Creates a `uint` value.
  public init(_ value: UInt64) {
    self = .uint(value)
  }

  /// Creates a `uint` value.
  public init(_ value: UInt32) {
    self = .uint(UInt64(value))
  }

  /// Creates a `double` value.
  public init(_ value: Double) {
    self = .double(value)
  }

  /// Creates a `double` value.
  public init(_ value: Float) {
    self = .double(Double(value))
  }

  /// Creates a `bool` value.
  public init(_ value: Bool) {
    self = .bool(value)
  }

  /// Creates a `string` value.
  public init(_ value: String) {
    self = .string(value)
  }

  /// Creates a `bytes` value.
  public init(bytes: [UInt8]) {
    self = .bytes(bytes)
  }

  /// Creates a `list` value.
  public init(_ elements: [Value]) {
    self = .list(ArrayList(elements))
  }

  /// Creates a `map` value with string keys, in key order.
  public init(_ entries: [String: Value]) {
    var map = OrderedMap()
    for key in entries.keys.sorted() {
      map[.string(key)] = entries[key]
    }
    self = .map(map)
  }

  /// Creates a `google.protobuf.Duration` value from a Swift duration.
  ///
  /// Returns `nil` when the duration is outside the 64-bit nanosecond range (about ±292 years) or has
  /// sub-nanosecond precision that cannot be represented.
  public init?(_ duration: Swift.Duration) {
    let (seconds, attoseconds) = duration.components
    guard attoseconds % 1_000_000_000 == 0 else {
      return nil
    }
    guard let d = CELDuration(seconds: seconds, nanoseconds: attoseconds / 1_000_000_000) else {
      return nil
    }
    self = .duration(d)
  }

  /// Creates an optional value: `optional.of(value)` or, for `nil`, `optional.none()`.
  public init(optional value: Value?) {
    self = .optional(value)
  }

  // MARK: Accessors

  /// The payload of a `bool` value, `nil` for other values.
  public var asBool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }

  /// The payload of an `int` value, `nil` for other values.
  public var asInt: Int64? {
    if case .int(let v) = self { return v }
    return nil
  }

  /// The payload of a `uint` value, `nil` for other values.
  public var asUInt: UInt64? {
    if case .uint(let v) = self { return v }
    return nil
  }

  /// The payload of a `double` value, `nil` for other values.
  public var asDouble: Double? {
    if case .double(let v) = self { return v }
    return nil
  }

  /// The payload of a `string` value, `nil` for other values.
  public var asString: String? {
    if case .string(let v) = self { return v }
    return nil
  }

  /// The payload of a `bytes` value, `nil` for other values.
  public var asBytes: [UInt8]? {
    if case .bytes(let v) = self { return v }
    return nil
  }

  /// The elements of a `list` value, `nil` for other values.
  ///
  /// - Complexity: O(*n*); host lists adapted lazily are materialised.
  public var asList: [Value]? {
    guard case .list(let list) = self else { return nil }
    if let array = list as? ArrayList {
      return array.elements
    }
    return (0..<list.count).map { list.element(at: $0) }
  }

  /// The entries of a `map` value, `nil` for other values.
  ///
  /// - Complexity: O(*n*); host maps adapted lazily are materialised.
  public var asMap: [MapKey: Value]? {
    guard case .map(let map) = self else { return nil }
    var result: [MapKey: Value] = [:]
    for key in map.keys {
      result[key] = map.value(forKey: key)
    }
    return result
  }

  /// The payload of a `google.protobuf.Duration` value, `nil` for other values.
  public var asDuration: CELDuration? {
    if case .duration(let v) = self { return v }
    return nil
  }

  /// The payload of a `google.protobuf.Timestamp` value, `nil` for other values.
  public var asTimestamp: CELTimestamp? {
    if case .timestamp(let v) = self { return v }
    return nil
  }

  /// The type of a `type` value, `nil` for other values.
  public var asType: CELType? {
    if case .type(let v) = self { return v }
    return nil
  }

  /// The object of a message or native object value, `nil` for other values.
  public var asObject: (any ObjectValue)? {
    if case .object(let v) = self { return v }
    return nil
  }

  /// The error of an error value, `nil` for other values.
  public var asError: EvalError? {
    if case .error(let v) = self { return v }
    return nil
  }

  /// The unknown attributes of an unknown value, `nil` for other values.
  public var asUnknown: UnknownSet? {
    if case .unknown(let v) = self { return v }
    return nil
  }
}

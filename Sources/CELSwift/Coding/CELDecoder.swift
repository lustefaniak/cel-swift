// A `Decoder` reading CEL values, so an expression's result can be any `Decodable` type.
// Not a ported file.

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CEL

/// Decodes CEL values into `Decodable` Swift values.
///
/// The inverse of ``CELEncoder``: objects and maps decode as structs (fields looked up by their
/// CEL name, see ``CELCodingOptions/KeyStrategy``) or dictionaries, lists as arrays and sets,
/// timestamps as `Date`, durations as `Swift.Duration`, bytes as `Data`. `null`, `optional.none()`
/// and absent fields decode as `nil`; `optional.of(x)` decodes as `x`.
///
/// Numbers convert when the value fits: an `int` or `uint` decodes as any integer type that can
/// hold it and as `Double`; an integral `double` decodes as an integer.
///
/// ```swift
/// struct Decision: Decodable {
///   var rule: String
///   var verdict: String
///   var flag: Bool?
/// }
/// let decision = try CELDecoder().decode(Decision.self, from: result.value)
/// ```
public struct CELDecoder: Sendable {
  /// How field names are looked up; must match how the value was produced.
  public var options: CELCodingOptions

  /// Creates a decoder.
  ///
  /// - Parameter options: How field names are looked up.
  public init(options: CELCodingOptions = CELCodingOptions()) {
    self.options = options
  }

  /// Decodes a value of the given type.
  ///
  /// - Parameters:
  ///   - type: The type to decode.
  ///   - value: The CEL value, such as an evaluation result.
  /// - Returns: The decoded value.
  /// - Throws: `DecodingError` when the value does not have the shape of `type`, including error
  ///   and unknown values; any error the type's `init(from:)` throws.
  public func decode<T: Decodable>(_ type: T.Type, from value: Value) throws -> T {
    try decodeValue(T.self, from: value, options: options, codingPath: [])
  }
}

extension Value {
  /// Decodes the value as a `Decodable` type with ``CELDecoder``.
  ///
  /// - Parameters:
  ///   - type: The type to decode.
  ///   - options: How field names are looked up.
  /// - Throws: The errors of ``CELDecoder/decode(_:from:)``.
  public func decoded<T: Decodable>(as type: T.Type = T.self, options: CELCodingOptions = CELCodingOptions()) throws -> T {
    try CELDecoder(options: options).decode(T.self, from: self)
  }
}

// MARK: - Decoding machinery

func decodeValue<T: Decodable>(
  _ type: T.Type, from value: Value, options: CELCodingOptions, codingPath: [any CodingKey]
) throws -> T {
  var value = value
  if case .optional(let inner?) = value, !(T.self is any OptionalMarker.Type) {
    value = inner
  }
  switch value {
  case .error(let error):
    throw DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: codingPath, debugDescription: "evaluation error: \(error.message)"))
  case .unknown(let unknown):
    throw DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: codingPath, debugDescription: "unknown value: \(unknown)"))
  default:
    break
  }
  if let leaf = try decodeLeaf(T.self, from: value, codingPath: codingPath) {
    return leaf
  }
  return try T(from: ValueDecoder(value: value, options: options, codingPath: codingPath, type: T.self))
}

private func mismatch<T>(_ type: T.Type, _ value: Value, _ codingPath: [any CodingKey]) -> DecodingError {
  DecodingError.typeMismatch(
    T.self,
    DecodingError.Context(
      codingPath: codingPath, debugDescription: "expected \(T.self), found \(describe(value))"))
}

private func describe(_ value: Value) -> String {
  switch value {
  case .null: return "null"
  case .object(let object): return "a value of type \(object.celType)"
  default: return "a \(value.celType) value"
  }
}

/// Decodes the leaf types (scalars, dates, durations, data, URLs, ``CELValueRepresentable``);
/// `nil` when `T` is not one.
private func decodeLeaf<T>(_ type: T.Type, from value: Value, codingPath: [any CodingKey]) throws -> T? {
  if let representable = T.self as? any CELValueRepresentable.Type {
    do {
      return try representable.init(celValue: value) as? T
    } catch {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: codingPath, debugDescription: "\(error)", underlyingError: error))
    }
  }
  if let integer = T.self as? any FixedWidthInteger.Type {
    guard let decoded = decodeInteger(integer, from: value) else {
      throw mismatch(T.self, value, codingPath)
    }
    return decoded as? T
  }
  switch T.self {
  case is Bool.Type:
    guard case .bool(let v) = value else { throw mismatch(T.self, value, codingPath) }
    return v as? T
  case is String.Type:
    guard case .string(let v) = value else { throw mismatch(T.self, value, codingPath) }
    return v as? T
  case is Double.Type:
    guard let v = decodeDouble(value) else { throw mismatch(T.self, value, codingPath) }
    return v as? T
  case is Float.Type:
    guard let v = decodeDouble(value) else { throw mismatch(T.self, value, codingPath) }
    return Float(v) as? T
  case is Date.Type:
    guard case .timestamp(let v) = value else { throw mismatch(T.self, value, codingPath) }
    return v.date as? T
  case is Swift.Duration.Type:
    guard case .duration(let v) = value else { throw mismatch(T.self, value, codingPath) }
    return v.swiftDuration as? T
  case is Data.Type:
    guard case .bytes(let v) = value else { throw mismatch(T.self, value, codingPath) }
    return Data(v) as? T
  case is URL.Type:
    guard case .string(let v) = value else { throw mismatch(T.self, value, codingPath) }
    guard let url = URL(string: v) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: codingPath, debugDescription: "invalid URL: \(v)"))
    }
    return url as? T
  default:
    return nil
  }
}

private func decodeInteger<I: FixedWidthInteger>(_ type: I.Type, from value: Value) -> I? {
  switch value {
  case .int(let v): return I(exactly: v)
  case .uint(let v): return I(exactly: v)
  case .double(let v): return I(exactly: v)
  default: return nil
  }
}

private func decodeDouble(_ value: Value) -> Double? {
  switch value {
  case .double(let v): return v
  case .int(let v): return Double(v)
  case .uint(let v): return Double(v)
  default: return nil
  }
}

private func isNull(_ value: Value) -> Bool {
  switch value {
  case .null, .optional(nil): return true
  default: return false
  }
}

final class ValueDecoder: Decoder {
  let value: Value
  let options: CELCodingOptions
  let codingPath: [any CodingKey]
  /// Whether the value is decoded as a dictionary, whose keys are never converted.
  let isDictionary: Bool
  var userInfo: [CodingUserInfoKey: Any] { [:] }

  init(value: Value, options: CELCodingOptions, codingPath: [any CodingKey], type: Any.Type) {
    self.value = value
    self.options = options
    self.codingPath = codingPath
    self.isDictionary = type is any DictionaryMarker.Type
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    let fields: FieldSource
    switch value {
    case .map(let map): fields = .map(map)
    case .object(let object): fields = .object(object)
    default:
      throw DecodingError.typeMismatch(
        [String: Any].self,
        DecodingError.Context(
          codingPath: codingPath, debugDescription: "expected an object or a map, found \(describe(value))"))
    }
    return KeyedDecodingContainer(
      KeyedReader<Key>(
        fields: fields, options: options, codingPath: codingPath, convertsKeys: !isDictionary))
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    guard case .list(let list) = value else {
      throw DecodingError.typeMismatch(
        [Any].self,
        DecodingError.Context(codingPath: codingPath, debugDescription: "expected a list, found \(describe(value))"))
    }
    return UnkeyedReader(list: list, options: options, codingPath: codingPath)
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    SingleReader(value: value, options: options, codingPath: codingPath)
  }
}

/// The fields of a keyed value: a map's entries or an object's fields.
enum FieldSource {
  case map(any MapValue)
  case object(any ObjectValue)
}

struct KeyedReader<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let fields: FieldSource
  let options: CELCodingOptions
  let codingPath: [any CodingKey]
  /// `false` for dictionaries: their keys are data and are looked up as they are.
  let convertsKeys: Bool

  var allKeys: [Key] {
    switch fields {
    case .map(let map):
      return (Value.map(map).asMap ?? [:]).keys.compactMap { key in
        switch key {
        case .string(let s): return Key(stringValue: convertsKeys ? options.codingKey(forField: s) : s)
        case .int(let i): return Key(intValue: Int(i)) ?? Key(stringValue: String(i))
        case .uint(let u): return Int(exactly: u).flatMap(Key.init(intValue:)) ?? Key(stringValue: String(u))
        case .bool(let b): return Key(stringValue: String(b))
        }
      }
    case .object(let object as Record):
      return object.fieldNames.compactMap { Key(stringValue: convertsKeys ? options.codingKey(forField: $0) : $0) }
    case .object:
      return []
    }
  }

  private func name(_ key: Key) -> String {
    convertsKeys ? options.fieldName(key.stringValue) : key.stringValue
  }

  /// The value under a key, `nil` when absent.
  private func lookup(_ key: Key) -> Value? {
    switch fields {
    case .map(let map):
      if let value = map.value(forKey: .string(name(key))) {
        return value
      }
      guard !convertsKeys else { return nil }
      if let int = key.intValue {
        return map.value(forKey: .int(Int64(int))) ?? UInt64(exactly: int).flatMap { map.value(forKey: .uint($0)) }
      }
      if let bool = Bool(key.stringValue) {
        return map.value(forKey: .bool(bool))
      }
      return nil
    case .object(let object):
      let value = object.field(name(key))
      if case .error = value {
        return nil
      }
      return value
    }
  }

  private func require(_ key: Key) throws -> Value {
    guard let value = lookup(key) else {
      throw DecodingError.keyNotFound(
        key,
        DecodingError.Context(
          codingPath: codingPath, debugDescription: "no field or key named '\(name(key))'"))
    }
    return value
  }

  func contains(_ key: Key) -> Bool {
    lookup(key) != nil
  }

  func decodeNil(forKey key: Key) throws -> Bool {
    lookup(key).map(isNull) ?? true
  }

  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    try decode(T.self, key)
  }
  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decode(Bool.self as Bool.Type, key) }
  func decode(_ type: String.Type, forKey key: Key) throws -> String { try decode(String.self as String.Type, key) }
  func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decode(Double.self as Double.Type, key) }
  func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decode(Float.self as Float.Type, key) }
  func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decode(Int.self as Int.Type, key) }
  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decode(Int8.self as Int8.Type, key) }
  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decode(Int16.self as Int16.Type, key) }
  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decode(Int32.self as Int32.Type, key) }
  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decode(Int64.self as Int64.Type, key) }
  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decode(UInt.self as UInt.Type, key) }
  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decode(UInt8.self as UInt8.Type, key) }
  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decode(UInt16.self as UInt16.Type, key) }
  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decode(UInt32.self as UInt32.Type, key) }
  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decode(UInt64.self as UInt64.Type, key) }

  private func decode<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
    try decodeValue(T.self, from: try require(key), options: options, codingPath: codingPath + [key])
  }

  func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
    guard let value = lookup(key), !isNull(value) else { return nil }
    return try decodeValue(T.self, from: value, options: options, codingPath: codingPath + [key])
  }

  func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type, forKey key: Key
  ) throws -> KeyedDecodingContainer<NestedKey> {
    try ValueDecoder(value: try require(key), options: options, codingPath: codingPath + [key], type: Any.self)
      .container(keyedBy: NestedKey.self)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    try ValueDecoder(value: try require(key), options: options, codingPath: codingPath + [key], type: Any.self)
      .unkeyedContainer()
  }

  func superDecoder() throws -> any Decoder {
    ValueDecoder(
      value: Key(stringValue: "super").flatMap(lookup) ?? .null, options: options,
      codingPath: codingPath, type: Any.self)
  }

  func superDecoder(forKey key: Key) throws -> any Decoder {
    ValueDecoder(value: lookup(key) ?? .null, options: options, codingPath: codingPath + [key], type: Any.self)
  }
}

struct UnkeyedReader: UnkeyedDecodingContainer {
  let list: any ListValue
  let options: CELCodingOptions
  let codingPath: [any CodingKey]
  var currentIndex = 0

  init(list: any ListValue, options: CELCodingOptions, codingPath: [any CodingKey]) {
    self.list = list
    self.options = options
    self.codingPath = codingPath
  }

  var count: Int? { list.count }
  var isAtEnd: Bool { currentIndex >= list.count }

  private mutating func next<T>(_ type: T.Type) throws -> (Value, [any CodingKey]) {
    guard !isAtEnd else {
      throw DecodingError.valueNotFound(
        T.self,
        DecodingError.Context(
          codingPath: codingPath + [IndexKey(currentIndex)], debugDescription: "the list has no more elements"))
    }
    let path = codingPath + [IndexKey(currentIndex)]
    let value = list.element(at: currentIndex)
    currentIndex += 1
    return (value, path)
  }

  mutating func decodeNil() throws -> Bool {
    guard !isAtEnd else { return false }
    if isNull(list.element(at: currentIndex)) {
      currentIndex += 1
      return true
    }
    return false
  }

  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try decodeNext(T.self)
  }
  mutating func decode(_ type: Bool.Type) throws -> Bool { try decodeNext(Bool.self) }
  mutating func decode(_ type: String.Type) throws -> String { try decodeNext(String.self) }
  mutating func decode(_ type: Double.Type) throws -> Double { try decodeNext(Double.self) }
  mutating func decode(_ type: Float.Type) throws -> Float { try decodeNext(Float.self) }
  mutating func decode(_ type: Int.Type) throws -> Int { try decodeNext(Int.self) }
  mutating func decode(_ type: Int8.Type) throws -> Int8 { try decodeNext(Int8.self) }
  mutating func decode(_ type: Int16.Type) throws -> Int16 { try decodeNext(Int16.self) }
  mutating func decode(_ type: Int32.Type) throws -> Int32 { try decodeNext(Int32.self) }
  mutating func decode(_ type: Int64.Type) throws -> Int64 { try decodeNext(Int64.self) }
  mutating func decode(_ type: UInt.Type) throws -> UInt { try decodeNext(UInt.self) }
  mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeNext(UInt8.self) }
  mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeNext(UInt16.self) }
  mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeNext(UInt32.self) }
  mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeNext(UInt64.self) }

  private mutating func decodeNext<T: Decodable>(_ type: T.Type) throws -> T {
    let (value, path) = try next(T.self)
    return try decodeValue(T.self, from: value, options: options, codingPath: path)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
    let (value, path) = try next([String: Any].self)
    return try ValueDecoder(value: value, options: options, codingPath: path, type: Any.self).container(keyedBy: NestedKey.self)
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
    let (value, path) = try next([Any].self)
    return try ValueDecoder(value: value, options: options, codingPath: path, type: Any.self).unkeyedContainer()
  }

  mutating func superDecoder() throws -> any Decoder {
    let (value, path) = try next(Any.self)
    return ValueDecoder(value: value, options: options, codingPath: path, type: Any.self)
  }
}

struct SingleReader: SingleValueDecodingContainer {
  let value: Value
  let options: CELCodingOptions
  let codingPath: [any CodingKey]

  func decodeNil() -> Bool {
    isNull(value)
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try decodeValue(T.self, from: value, options: options, codingPath: codingPath)
  }

  func decode(_ type: Bool.Type) throws -> Bool { try decodeValue(Bool.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: String.Type) throws -> String { try decodeValue(String.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: Double.Type) throws -> Double { try decodeValue(Double.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: Float.Type) throws -> Float { try decodeValue(Float.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: Int.Type) throws -> Int { try decodeValue(Int.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: Int8.Type) throws -> Int8 { try decodeValue(Int8.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: Int16.Type) throws -> Int16 { try decodeValue(Int16.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: Int32.Type) throws -> Int32 { try decodeValue(Int32.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: Int64.Type) throws -> Int64 { try decodeValue(Int64.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: UInt.Type) throws -> UInt { try decodeValue(UInt.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeValue(UInt8.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeValue(UInt16.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeValue(UInt32.self, from: value, options: options, codingPath: codingPath) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeValue(UInt64.self, from: value, options: options, codingPath: codingPath) }
}

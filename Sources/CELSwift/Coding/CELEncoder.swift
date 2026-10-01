// An `Encoder` producing CEL values, so any `Encodable` value can be an expression's input.
// Not a ported file.

import CEL

/// Encodes `Encodable` values as CEL values.
///
/// Structs become CEL objects named after their type (or maps, see
/// ``CELCodingOptions/StructRepresentation``), arrays and sets become lists, dictionaries become
/// maps, and the types CEL has a native type for keep it:
///
/// | Swift | CEL |
/// |---|---|
/// | `Bool`, `String` | `bool`, `string` |
/// | `Int`, `Int8` ... `Int64` | `int` |
/// | `UInt`, `UInt8` ... `UInt64` | `uint` |
/// | `Double`, `Float` | `double` |
/// | `Date` | `google.protobuf.Timestamp`, to the nanosecond |
/// | `Swift.Duration` | `google.protobuf.Duration` |
/// | `Data` | `bytes` |
/// | `URL` | `string`, its absolute form |
/// | `nil` | `null` |
/// | enums with raw values | the raw value |
/// | ``CELValueRepresentable`` | its ``CELValueRepresentable/celValue`` |
///
/// ```swift
/// struct ChangeRequest: Codable {
///   var repo: String
///   var additions: Int
///   var labels: [String]
/// }
/// let variables = try CELEncoder().encodeVariables(
///   Facts(pr: ChangeRequest(repo: "acme/api", additions: 12, labels: ["bug"])))
/// // ["pr": ChangeRequest{repo: "acme/api", additions: 12, labels: ["bug"]}]
/// ```
public struct CELEncoder: Sendable {
  /// How field names and structs are represented; must match the options of the schema the
  /// expression was checked against.
  public var options: CELCodingOptions

  /// Creates an encoder.
  ///
  /// - Parameter options: How field names and structs are represented.
  public init(options: CELCodingOptions = CELCodingOptions()) {
    self.options = options
  }

  /// Encodes a value.
  ///
  /// - Parameter value: The value to encode.
  /// - Returns: The CEL value.
  /// - Throws: `EncodingError.invalidValue` for a date or duration outside CEL's range, or any
  ///   error the value's `encode(to:)` throws.
  public func encode<T: Encodable>(_ value: T) throws -> Value {
    try encodeValue(value, options: options, codingPath: [])
  }

  /// Encodes the stored properties of a struct as variables, one per coding key.
  ///
  /// Use it with environments declared by `Environment.Option.variables(from:options:)`:
  /// each property of the facts struct is a variable of the same name.
  ///
  /// - Parameter facts: A value whose encoding is keyed, such as a struct.
  /// - Returns: The encoded properties by CEL name; `nil` properties are `null`.
  /// - Throws: `EncodingError.invalidValue` when `facts` does not encode as keyed values, or any
  ///   error from encoding a property.
  public func encodeVariables<T: Encodable>(_ facts: T) throws -> [String: Value] {
    switch try encode(facts) {
    case .object(let object as Record):
      return object.fields
    case .map(let map):
      var variables: [String: Value] = [:]
      for (key, value) in Value.map(map).asMap ?? [:] {
        guard case .string(let name) = key else { continue }
        variables[name] = value
      }
      return variables
    default:
      throw EncodingError.invalidValue(
        facts,
        EncodingError.Context(
          codingPath: [],
          debugDescription: "variables must be encoded from a struct with keyed properties, not \(T.self)"))
    }
  }
}

extension Value {
  /// Encodes an `Encodable` value with ``CELEncoder``.
  ///
  /// - Parameters:
  ///   - value: The value to encode.
  ///   - options: How field names and structs are represented.
  /// - Throws: The errors of ``CELEncoder/encode(_:)``.
  public init(encoding value: some Encodable, options: CELCodingOptions = CELCodingOptions()) throws {
    self = try CELEncoder(options: options).encode(value)
  }
}

extension Variables {
  /// Variables from the stored properties of a struct, one per coding key
  /// (see ``CELEncoder/encodeVariables(_:)``).
  ///
  /// - Parameters:
  ///   - facts: A value whose encoding is keyed, such as a struct.
  ///   - options: How field names and structs are represented.
  /// - Throws: The errors of ``CELEncoder/encodeVariables(_:)``.
  public init(encoding facts: some Encodable, options: CELCodingOptions = CELCodingOptions()) throws {
    self.init(try CELEncoder(options: options).encodeVariables(facts))
  }
}

// MARK: - Encoding machinery

func encodeValue<T: Encodable>(_ value: T, options: CELCodingOptions, codingPath: [any CodingKey]) throws -> Value {
  if let leaf = try leafValue(value, codingPath: codingPath) {
    return leaf
  }
  let encoder = ValueEncoder(options: options, codingPath: codingPath, shape: EncodedShape(T.self))
  try value.encode(to: encoder)
  return try encoder.finish()
}

/// What a keyed container being encoded stands for.
enum EncodedShape {
  /// A struct or class, encoded as an object of this type name or as a map.
  case structure(typeName: String)
  /// A dictionary with keys of this CEL type.
  case dictionary(keyType: CELType)
  /// A nested container without a Swift type of its own.
  case anonymous

  init(_ type: Any.Type) {
    if let dictionary = type as? any DictionaryMarker.Type {
      self = .dictionary(keyType: mapKeyType(for: dictionary.keyType))
    } else if type is any OptionalMarker.Type || type is any SequenceMarker.Type {
      self = .anonymous
    } else {
      self = .structure(typeName: celTypeName(of: type))
    }
  }
}

final class ValueEncoder: Encoder {
  enum Storage {
    case keyed(KeyedStorage)
    case unkeyed(UnkeyedStorage)
    case single(Value)
  }

  let options: CELCodingOptions
  let codingPath: [any CodingKey]
  let shape: EncodedShape
  var userInfo: [CodingUserInfoKey: Any] { [:] }
  var storage: Storage?

  init(options: CELCodingOptions, codingPath: [any CodingKey], shape: EncodedShape) {
    self.options = options
    self.codingPath = codingPath
    self.shape = shape
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let keyed: KeyedStorage
    if case .keyed(let existing)? = storage {
      keyed = existing
    } else {
      keyed = KeyedStorage(shape: shape)
      storage = .keyed(keyed)
    }
    return KeyedEncodingContainer(KeyedContainer<Key>(encoder: self, storage: keyed, codingPath: codingPath))
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    let unkeyed: UnkeyedStorage
    if case .unkeyed(let existing)? = storage {
      unkeyed = existing
    } else {
      unkeyed = UnkeyedStorage()
      storage = .unkeyed(unkeyed)
    }
    return UnkeyedContainer(encoder: self, storage: unkeyed, codingPath: codingPath)
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    SingleContainer(encoder: self, codingPath: codingPath)
  }

  func finish() throws -> Value {
    switch storage {
    case nil:
      return try KeyedStorage(shape: shape).value(options: options)
    case .keyed(let keyed)?:
      return try keyed.value(options: options)
    case .unkeyed(let unkeyed)?:
      return try unkeyed.value(options: options)
    case .single(let value)?:
      return value
    }
  }
}

/// A value written into a container: final, or a nested container resolved when encoding ends.
enum Slot {
  case value(Value)
  case keyed(KeyedStorage)
  case unkeyed(UnkeyedStorage)
  case encoder(ValueEncoder)

  func value(options: CELCodingOptions) throws -> Value {
    switch self {
    case .value(let value): return value
    case .keyed(let storage): return try storage.value(options: options)
    case .unkeyed(let storage): return try storage.value(options: options)
    case .encoder(let encoder): return try encoder.finish()
    }
  }
}

final class KeyedStorage {
  let shape: EncodedShape
  private(set) var keys: [any CodingKey] = []
  private var slots: [String: Slot] = [:]

  init(shape: EncodedShape) {
    self.shape = shape
  }

  func set(_ slot: Slot, forKey key: any CodingKey) {
    if slots.updateValue(slot, forKey: key.stringValue) == nil {
      keys.append(key)
    }
  }

  func value(options: CELCodingOptions) throws -> Value {
    switch shape {
    case .dictionary(let keyType):
      var map = OrderedMap()
      for key in keys {
        guard let slot = slots[key.stringValue] else { continue }
        map[mapKey(key, type: keyType)] = try slot.value(options: options)
      }
      return .map(map)
    case .structure(let typeName) where options.structRepresentation == .objects:
      var entries: [(String, Value)] = []
      for key in keys {
        guard let slot = slots[key.stringValue] else { continue }
        entries.append((options.fieldName(key.stringValue), try slot.value(options: options)))
      }
      return .object(Record(typeName: typeName, entries: entries))
    case .structure, .anonymous:
      var map = OrderedMap()
      for key in keys {
        guard let slot = slots[key.stringValue] else { continue }
        map[.string(options.fieldName(key.stringValue))] = try slot.value(options: options)
      }
      return .map(map)
    }
  }

  private func mapKey(_ key: any CodingKey, type: CELType) -> MapKey {
    switch type {
    case .int:
      if let int = key.intValue ?? Int(key.stringValue) { return .int(Int64(int)) }
    case .uint:
      if let uint = key.intValue.flatMap(UInt64.init(exactly:)) ?? UInt64(key.stringValue) { return .uint(uint) }
    case .bool:
      if let bool = Bool(key.stringValue) { return .bool(bool) }
    default:
      break
    }
    return .string(key.stringValue)
  }
}

final class UnkeyedStorage {
  private(set) var slots: [Slot] = []

  func append(_ slot: Slot) {
    slots.append(slot)
  }

  func value(options: CELCodingOptions) throws -> Value {
    .list(ArrayList(try slots.map { try $0.value(options: options) }))
  }
}

struct IndexKey: CodingKey {
  let intValue: Int?
  let stringValue: String

  init(_ index: Int) {
    self.intValue = index
    self.stringValue = "Index \(index)"
  }

  init?(intValue: Int) {
    self.init(intValue)
  }

  init?(stringValue: String) {
    return nil
  }
}

struct NamedKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }

  init(_ name: String) {
    self.stringValue = name
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    return nil
  }
}

struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let encoder: ValueEncoder
  let storage: KeyedStorage
  let codingPath: [any CodingKey]

  private func put(_ value: Value, _ key: Key) {
    storage.set(.value(value), forKey: key)
  }

  mutating func encodeNil(forKey key: Key) throws { put(.null, key) }
  mutating func encode(_ value: Bool, forKey key: Key) throws { put(.bool(value), key) }
  mutating func encode(_ value: String, forKey key: Key) throws { put(.string(value), key) }
  mutating func encode(_ value: Double, forKey key: Key) throws { put(.double(value), key) }
  mutating func encode(_ value: Float, forKey key: Key) throws { put(.double(Double(value)), key) }
  mutating func encode(_ value: Int, forKey key: Key) throws { put(.int(Int64(value)), key) }
  mutating func encode(_ value: Int8, forKey key: Key) throws { put(.int(Int64(value)), key) }
  mutating func encode(_ value: Int16, forKey key: Key) throws { put(.int(Int64(value)), key) }
  mutating func encode(_ value: Int32, forKey key: Key) throws { put(.int(Int64(value)), key) }
  mutating func encode(_ value: Int64, forKey key: Key) throws { put(.int(value), key) }
  mutating func encode(_ value: UInt, forKey key: Key) throws { put(.uint(UInt64(value)), key) }
  mutating func encode(_ value: UInt8, forKey key: Key) throws { put(.uint(UInt64(value)), key) }
  mutating func encode(_ value: UInt16, forKey key: Key) throws { put(.uint(UInt64(value)), key) }
  mutating func encode(_ value: UInt32, forKey key: Key) throws { put(.uint(UInt64(value)), key) }
  mutating func encode(_ value: UInt64, forKey key: Key) throws { put(.uint(value), key) }

  mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    put(try encodeValue(value, options: encoder.options, codingPath: codingPath + [key]), key)
  }

  // Synthesized conformances skip `nil` optionals through `encodeIfPresent`; recording them as
  // `null` keeps every declared field present, so reading an unset field gives `null`.
  mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { try put(value, key) }
  mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws { try put(value, key) }

  private func put<T: Encodable>(_ value: T?, _ key: Key) throws {
    guard let value else {
      put(.null, key)
      return
    }
    put(try encodeValue(value, options: encoder.options, codingPath: codingPath + [key]), key)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type, forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    let nested = KeyedStorage(shape: .anonymous)
    storage.set(.keyed(nested), forKey: key)
    return KeyedEncodingContainer(
      KeyedContainer<NestedKey>(encoder: encoder, storage: nested, codingPath: codingPath + [key]))
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    let nested = UnkeyedStorage()
    storage.set(.unkeyed(nested), forKey: key)
    return UnkeyedContainer(encoder: encoder, storage: nested, codingPath: codingPath + [key])
  }

  mutating func superEncoder() -> any Encoder {
    makeSuperEncoder(NamedKey("super"))
  }

  mutating func superEncoder(forKey key: Key) -> any Encoder {
    makeSuperEncoder(key)
  }

  private func makeSuperEncoder(_ key: any CodingKey) -> any Encoder {
    let nested = ValueEncoder(options: encoder.options, codingPath: codingPath + [key], shape: .anonymous)
    storage.set(.encoder(nested), forKey: key)
    return nested
  }
}

struct UnkeyedContainer: UnkeyedEncodingContainer {
  let encoder: ValueEncoder
  let storage: UnkeyedStorage
  let codingPath: [any CodingKey]

  var count: Int { storage.slots.count }

  private var nextPath: [any CodingKey] { codingPath + [IndexKey(count)] }

  mutating func encodeNil() throws { storage.append(.value(.null)) }
  mutating func encode(_ value: Bool) throws { storage.append(.value(.bool(value))) }
  mutating func encode(_ value: String) throws { storage.append(.value(.string(value))) }
  mutating func encode(_ value: Double) throws { storage.append(.value(.double(value))) }
  mutating func encode(_ value: Float) throws { storage.append(.value(.double(Double(value)))) }
  mutating func encode(_ value: Int) throws { storage.append(.value(.int(Int64(value)))) }
  mutating func encode(_ value: Int8) throws { storage.append(.value(.int(Int64(value)))) }
  mutating func encode(_ value: Int16) throws { storage.append(.value(.int(Int64(value)))) }
  mutating func encode(_ value: Int32) throws { storage.append(.value(.int(Int64(value)))) }
  mutating func encode(_ value: Int64) throws { storage.append(.value(.int(value))) }
  mutating func encode(_ value: UInt) throws { storage.append(.value(.uint(UInt64(value)))) }
  mutating func encode(_ value: UInt8) throws { storage.append(.value(.uint(UInt64(value)))) }
  mutating func encode(_ value: UInt16) throws { storage.append(.value(.uint(UInt64(value)))) }
  mutating func encode(_ value: UInt32) throws { storage.append(.value(.uint(UInt64(value)))) }
  mutating func encode(_ value: UInt64) throws { storage.append(.value(.uint(value))) }

  mutating func encode<T: Encodable>(_ value: T) throws {
    storage.append(.value(try encodeValue(value, options: encoder.options, codingPath: nextPath)))
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
    let path = nextPath
    let nested = KeyedStorage(shape: .anonymous)
    storage.append(.keyed(nested))
    return KeyedEncodingContainer(KeyedContainer<NestedKey>(encoder: encoder, storage: nested, codingPath: path))
  }

  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    let path = nextPath
    let nested = UnkeyedStorage()
    storage.append(.unkeyed(nested))
    return UnkeyedContainer(encoder: encoder, storage: nested, codingPath: path)
  }

  mutating func superEncoder() -> any Encoder {
    let nested = ValueEncoder(options: encoder.options, codingPath: nextPath, shape: .anonymous)
    storage.append(.encoder(nested))
    return nested
  }
}

struct SingleContainer: SingleValueEncodingContainer {
  let encoder: ValueEncoder
  let codingPath: [any CodingKey]

  private func put(_ value: Value) {
    encoder.storage = .single(value)
  }

  mutating func encodeNil() throws { put(.null) }
  mutating func encode(_ value: Bool) throws { put(.bool(value)) }
  mutating func encode(_ value: String) throws { put(.string(value)) }
  mutating func encode(_ value: Double) throws { put(.double(value)) }
  mutating func encode(_ value: Float) throws { put(.double(Double(value))) }
  mutating func encode(_ value: Int) throws { put(.int(Int64(value))) }
  mutating func encode(_ value: Int8) throws { put(.int(Int64(value))) }
  mutating func encode(_ value: Int16) throws { put(.int(Int64(value))) }
  mutating func encode(_ value: Int32) throws { put(.int(Int64(value))) }
  mutating func encode(_ value: Int64) throws { put(.int(value)) }
  mutating func encode(_ value: UInt) throws { put(.uint(UInt64(value))) }
  mutating func encode(_ value: UInt8) throws { put(.uint(UInt64(value))) }
  mutating func encode(_ value: UInt16) throws { put(.uint(UInt64(value))) }
  mutating func encode(_ value: UInt32) throws { put(.uint(UInt64(value))) }
  mutating func encode(_ value: UInt64) throws { put(.uint(value)) }

  mutating func encode<T: Encodable>(_ value: T) throws {
    put(try encodeValue(value, options: encoder.options, codingPath: codingPath))
  }
}

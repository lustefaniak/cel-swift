// The schema-collecting decoder behind CELSchema: it answers every request of a type's
// `init(from:)` with a placeholder value and records the key and the type that was asked for.
// Not a ported file.

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CEL

/// Describes Swift types as CEL types, collecting the object types it meets.
final class SchemaBuilder {
  let options: CELCodingOptions
  /// The object types described so far, by name.
  var structs: [String: CELSchema.StructType] = [:]
  /// Object type names in the order they were first met.
  var order: [String] = []
  /// Structs whose decoding is running, to stop on a struct that contains itself.
  private var inProgress: Set<String> = []

  init(options: CELCodingOptions) {
    self.options = options
  }

  /// The CEL type of a Swift type, without an instance where the type alone says it.
  func celType(of type: Any.Type, path: String) throws -> CELType {
    if let leaf = leafType(of: type) {
      return leaf
    }
    if let optional = type as? any OptionalMarker.Type {
      return nullable(try self.celType(of: optional.wrappedType, path: path))
    }
    if let sequence = type as? any SequenceMarker.Type {
      return .list(try self.celType(of: sequence.elementType, path: path + "[]"))
    }
    if let dictionary = type as? any DictionaryMarker.Type {
      return .map(
        key: mapKeyType(for: dictionary.keyType),
        value: try self.celType(of: dictionary.valueType, path: path + "[]"))
    }
    if let raw = type as? any RawRepresentable.Type, let rawType = primitiveType(of: rawValueType(of: raw)) {
      // A raw-value enum needs no instance to have a type, only to be a non-optional field.
      return rawType
    }
    guard let decodable = type as? any Decodable.Type else {
      throw DeclarationError("\(path): \(type) is not Decodable")
    }
    return try describedType(decodable, path: path)
  }

  private func describedType<T: Decodable>(_ type: T.Type, path: String) throws -> CELType {
    let name = celTypeName(of: T.self)
    if structs[name] != nil || inProgress.contains(name) {
      // Already described, or a reference back to a struct being described (through an
      // optional or a collection, which need no instance).
      return options.structRepresentation == .objects ? .object(name) : .map(key: .string, value: .dyn)
    }
    return try sample(T.self, path: path).type
  }

  /// A placeholder instance of a type, its CEL type, and its fields when it decodes as keyed
  /// values.
  func sample<T: Decodable>(_ type: T.Type, path: String) throws -> (instance: T, type: CELType, fields: [CELSchema.Field]?) {
    if let representable = T.self as? any CELValueRepresentable.Type {
      let celType = representable.celType
      if let first = firstCase(of: T.self) {
        return (first, celType, nil)
      }
      do {
        guard let instance = try representable.init(celValue: zeroValue(of: celType)) as? T else {
          throw DeclarationError("\(path): cannot create a placeholder \(T.self)")
        }
        return (instance, celType, nil)
      } catch {
        throw DeclarationError(
          "\(path): \(T.self)(celValue: \(zeroValue(of: celType))) failed (\(error)); conform \(T.self) to CaseIterable so its first case can stand in"
        )
      }
    }
    if let placeholder = placeholder(of: T.self) {
      return (placeholder, try self.celType(of: T.self, path: path), nil)
    }
    if let first = firstCase(of: T.self) {
      return (first, try caseType(first, path: path), nil)
    }
    return try sampleStructure(T.self, path: path)
  }

  /// Placeholders for the types described without decoding: scalars, leaves, optionals,
  /// collections.
  private func placeholder<T>(of type: T.Type) -> T? {
    if let optional = T.self as? any OptionalMarker.Type {
      return optional.absent as? T
    }
    if let sequence = T.self as? any SequenceMarker.Type {
      return sequence.empty as? T
    }
    if let dictionary = T.self as? any DictionaryMarker.Type {
      return dictionary.empty as? T
    }
    let value: Any? =
      switch T.self {
      case is Bool.Type: false
      case is String.Type: ""
      case is Int.Type: 0 as Int
      case is Int8.Type: 0 as Int8
      case is Int16.Type: 0 as Int16
      case is Int32.Type: 0 as Int32
      case is Int64.Type: 0 as Int64
      case is UInt.Type: 0 as UInt
      case is UInt8.Type: 0 as UInt8
      case is UInt16.Type: 0 as UInt16
      case is UInt32.Type: 0 as UInt32
      case is UInt64.Type: 0 as UInt64
      case is Double.Type: 0 as Double
      case is Float.Type: 0 as Float
      case is Date.Type: Date(timeIntervalSince1970: 0)
      case is Swift.Duration.Type: Swift.Duration.zero
      case is Data.Type: Data()
      case is URL.Type: URL(string: "about:blank")
      case is UUID.Type: UUID()
      default: nil
      }
    return value as? T
  }

  /// The CEL type of an enum: the type of its first case's encoding, or of its raw value.
  private func caseType<T>(_ value: T, path: String) throws -> CELType {
    if let encodable = value as? any Encodable {
      let encoded = try encodeOpened(encodable)
      if let type = scalarType(of: encoded) {
        return type
      }
      throw DeclarationError("\(path): \(T.self) does not encode as a scalar; conform it to CELValueRepresentable")
    }
    if let raw = value as? any RawRepresentable, let type = primitiveType(of: rawType(raw)) {
      return type
    }
    throw DeclarationError("\(path): cannot tell the CEL type of \(T.self); conform it to CELValueRepresentable")
  }

  private func encodeOpened<E: Encodable>(_ value: E) throws -> Value {
    try encodeValue(value, options: options, codingPath: [])
  }

  private func rawType<R: RawRepresentable>(_ value: R) -> Any.Type {
    R.RawValue.self
  }

  private func rawValueType<R: RawRepresentable>(of type: R.Type) -> Any.Type {
    R.RawValue.self
  }

  private func sampleStructure<T: Decodable>(
    _ type: T.Type, path: String
  ) throws -> (instance: T, type: CELType, fields: [CELSchema.Field]?) {
    let name = celTypeName(of: T.self)
    if inProgress.contains(name) {
      throw DeclarationError("\(path): \(T.self) contains itself; refer to it through an optional or a collection")
    }
    inProgress.insert(name)
    defer { inProgress.remove(name) }
    let reservesSlot = options.structRepresentation == .objects && !order.contains(name)
    if reservesSlot {
      order.append(name)  // the struct comes before the types its fields use
    }
    let decoder = SchemaDecoder(builder: self, path: path)
    let instance: T
    do {
      instance = try T(from: decoder)
    } catch let error as DeclarationError {
      throw error
    } catch {
      throw DeclarationError(
        "\(path): \(T.self).init(from:) fails on placeholder values (\(error)); enums need CaseIterable or CELValueRepresentable"
      )
    }
    switch decoder.shape {
    case .keyed, .none:
      let fields = decoder.fields
      switch options.structRepresentation {
      case .objects:
        if structs[name] == nil {
          structs[name] = CELSchema.StructType(typeName: name, fields: fields)
        }
        return (instance, .object(name), fields)
      case .maps:
        let types = Set(fields.map(\.type))
        let valueType = types.count == 1 ? types.first ?? .dyn : .dyn
        return (instance, .map(key: .string, value: valueType), fields)
      }
    case .single(let type):
      if reservesSlot { order.removeAll { $0 == name } }
      return (instance, type ?? .dyn, nil)
    case .unkeyed(let element):
      if reservesSlot { order.removeAll { $0 == name } }
      return (instance, .list(element ?? .dyn), nil)
    }
  }
}

/// The first case of a `CaseIterable` type, `nil` for other types or an enum without cases.
private func firstCase<T>(of type: T.Type) -> T? {
  guard let iterable = T.self as? any CaseIterable.Type else { return nil }
  return firstCase(iterable) as? T
}

private func firstCase<C: CaseIterable>(_ type: C.Type) -> Any? {
  C.allCases.first
}

/// Records what a type's `init(from:)` asks for.
final class SchemaDecoder: Decoder {
  enum Shape {
    case none
    case keyed
    case single(CELType?)
    case unkeyed(CELType?)
  }

  let builder: SchemaBuilder
  let path: String
  var shape = Shape.none
  private(set) var fields: [CELSchema.Field] = []
  var codingPath: [any CodingKey] { [] }
  var userInfo: [CodingUserInfoKey: Any] { [:] }

  init(builder: SchemaBuilder, path: String) {
    self.builder = builder
    self.path = path
  }

  func record(_ key: any CodingKey, type: CELType, isOptional: Bool) {
    let name = builder.options.fieldName(key.stringValue)
    if let index = fields.firstIndex(where: { $0.name == name }) {
      fields[index] = CELSchema.Field(name: name, type: type, isOptional: isOptional)
    } else {
      fields.append(CELSchema.Field(name: name, type: type, isOptional: isOptional))
    }
  }

  func fieldPath(_ key: any CodingKey) -> String {
    "\(path).\(builder.options.fieldName(key.stringValue))"
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    shape = .keyed
    return KeyedDecodingContainer(SchemaKeyedContainer<Key>(decoder: self))
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    shape = .unkeyed(nil)
    return SchemaUnkeyedContainer(builder: builder, path: path + "[]") { [self] type in
      if case .unkeyed(nil) = shape {
        shape = .unkeyed(type)
      }
    }
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    SchemaSingleContainer(builder: builder, path: path) { [self] type in
      shape = .single(type)
    }
  }
}

struct SchemaKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let decoder: SchemaDecoder
  var codingPath: [any CodingKey] { [] }
  var allKeys: [Key] { [] }

  func contains(_ key: Key) -> Bool { true }
  func decodeNil(forKey key: Key) throws -> Bool { false }

  private func scalar<T>(_ value: T, _ type: CELType, _ key: Key) -> T {
    decoder.record(key, type: type, isOptional: false)
    return value
  }

  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { scalar(false, .bool, key) }
  func decode(_ type: String.Type, forKey key: Key) throws -> String { scalar("", .string, key) }
  func decode(_ type: Double.Type, forKey key: Key) throws -> Double { scalar(0, .double, key) }
  func decode(_ type: Float.Type, forKey key: Key) throws -> Float { scalar(0, .double, key) }
  func decode(_ type: Int.Type, forKey key: Key) throws -> Int { scalar(0, .int, key) }
  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { scalar(0, .int, key) }
  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { scalar(0, .int, key) }
  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { scalar(0, .int, key) }
  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { scalar(0, .int, key) }
  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { scalar(0, .uint, key) }
  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { scalar(0, .uint, key) }
  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { scalar(0, .uint, key) }
  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { scalar(0, .uint, key) }
  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { scalar(0, .uint, key) }

  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    let sample = try decoder.builder.sample(T.self, path: decoder.fieldPath(key))
    decoder.record(key, type: sample.type, isOptional: T.self is any OptionalMarker.Type)
    return sample.instance
  }

  private func absent<T>(_ type: T.Type, _ key: Key) throws -> T? {
    let celType = try decoder.builder.celType(of: T.self, path: decoder.fieldPath(key))
    decoder.record(key, type: nullable(celType), isOptional: true)
    return nil
  }

  func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try absent(type, key) }
  func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try absent(type, key) }
  func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try absent(type, key) }
  func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try absent(type, key) }
  func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try absent(type, key) }
  func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try absent(type, key) }
  func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try absent(type, key) }
  func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try absent(type, key) }
  func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try absent(type, key) }
  func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try absent(type, key) }
  func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try absent(type, key) }
  func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try absent(type, key) }
  func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try absent(type, key) }
  func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try absent(type, key) }
  func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? { try absent(type, key) }

  func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type, forKey key: Key
  ) throws -> KeyedDecodingContainer<NestedKey> {
    decoder.record(key, type: .map(key: .string, value: .dyn), isOptional: false)
    let nested = SchemaDecoder(builder: decoder.builder, path: decoder.fieldPath(key))
    return KeyedDecodingContainer(SchemaKeyedContainer<NestedKey>(decoder: nested))
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    decoder.record(key, type: .list(.dyn), isOptional: false)
    return SchemaUnkeyedContainer(builder: decoder.builder, path: decoder.fieldPath(key) + "[]") { _ in }
  }

  func superDecoder() throws -> any Decoder {
    try superDecoder(forKey: Key(stringValue: "super"))
  }

  func superDecoder(forKey key: Key) throws -> any Decoder {
    try superDecoder(forKey: Optional(key))
  }

  private func superDecoder(forKey key: Key?) throws -> any Decoder {
    // ``CELEncoder`` writes a superclass's encoding under `super`, as JSONEncoder does.
    if let key {
      decoder.record(key, type: .map(key: .string, value: .dyn), isOptional: false)
    }
    return SchemaDecoder(builder: decoder.builder, path: decoder.path + ".super")
  }
}

struct SchemaUnkeyedContainer: UnkeyedDecodingContainer {
  let builder: SchemaBuilder
  let path: String
  let recordElement: (CELType) -> Void
  var codingPath: [any CodingKey] { [] }
  var currentIndex = 0

  init(builder: SchemaBuilder, path: String, recordElement: @escaping (CELType) -> Void) {
    self.builder = builder
    self.path = path
    self.recordElement = recordElement
  }

  var count: Int? { nil }
  var isAtEnd: Bool { currentIndex > 0 }

  mutating func decodeNil() throws -> Bool { false }

  private mutating func scalar<T>(_ value: T, _ type: CELType) -> T {
    recordElement(type)
    currentIndex += 1
    return value
  }

  mutating func decode(_ type: Bool.Type) throws -> Bool { scalar(false, .bool) }
  mutating func decode(_ type: String.Type) throws -> String { scalar("", .string) }
  mutating func decode(_ type: Double.Type) throws -> Double { scalar(0, .double) }
  mutating func decode(_ type: Float.Type) throws -> Float { scalar(0, .double) }
  mutating func decode(_ type: Int.Type) throws -> Int { scalar(0, .int) }
  mutating func decode(_ type: Int8.Type) throws -> Int8 { scalar(0, .int) }
  mutating func decode(_ type: Int16.Type) throws -> Int16 { scalar(0, .int) }
  mutating func decode(_ type: Int32.Type) throws -> Int32 { scalar(0, .int) }
  mutating func decode(_ type: Int64.Type) throws -> Int64 { scalar(0, .int) }
  mutating func decode(_ type: UInt.Type) throws -> UInt { scalar(0, .uint) }
  mutating func decode(_ type: UInt8.Type) throws -> UInt8 { scalar(0, .uint) }
  mutating func decode(_ type: UInt16.Type) throws -> UInt16 { scalar(0, .uint) }
  mutating func decode(_ type: UInt32.Type) throws -> UInt32 { scalar(0, .uint) }
  mutating func decode(_ type: UInt64.Type) throws -> UInt64 { scalar(0, .uint) }

  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let sample = try builder.sample(T.self, path: path)
    return scalar(sample.instance, sample.type)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
    recordElement(.map(key: .string, value: .dyn))
    currentIndex += 1
    return KeyedDecodingContainer(SchemaKeyedContainer<NestedKey>(decoder: SchemaDecoder(builder: builder, path: path)))
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
    recordElement(.list(.dyn))
    currentIndex += 1
    return SchemaUnkeyedContainer(builder: builder, path: path + "[]") { _ in }
  }

  mutating func superDecoder() throws -> any Decoder {
    currentIndex += 1
    return SchemaDecoder(builder: builder, path: path)
  }
}

struct SchemaSingleContainer: SingleValueDecodingContainer {
  let builder: SchemaBuilder
  let path: String
  let recordType: (CELType) -> Void
  var codingPath: [any CodingKey] { [] }

  func decodeNil() -> Bool { false }

  private func scalar<T>(_ value: T, _ type: CELType) -> T {
    recordType(type)
    return value
  }

  func decode(_ type: Bool.Type) throws -> Bool { scalar(false, .bool) }
  func decode(_ type: String.Type) throws -> String { scalar("", .string) }
  func decode(_ type: Double.Type) throws -> Double { scalar(0, .double) }
  func decode(_ type: Float.Type) throws -> Float { scalar(0, .double) }
  func decode(_ type: Int.Type) throws -> Int { scalar(0, .int) }
  func decode(_ type: Int8.Type) throws -> Int8 { scalar(0, .int) }
  func decode(_ type: Int16.Type) throws -> Int16 { scalar(0, .int) }
  func decode(_ type: Int32.Type) throws -> Int32 { scalar(0, .int) }
  func decode(_ type: Int64.Type) throws -> Int64 { scalar(0, .int) }
  func decode(_ type: UInt.Type) throws -> UInt { scalar(0, .uint) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { scalar(0, .uint) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { scalar(0, .uint) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { scalar(0, .uint) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { scalar(0, .uint) }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let sample = try builder.sample(T.self, path: path)
    return scalar(sample.instance, sample.type)
  }
}

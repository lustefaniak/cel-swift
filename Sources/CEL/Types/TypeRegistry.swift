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
// Ported from cel-go common/types/provider.go (Registry), without the protobuf database: message
// types arrive as StructTypeDescriptors and enum values are registered by name.

/// The standard type provider: the built-in type identifiers, registered struct types and enum
/// values, and optionally another provider consulted for anything not found here.
///
/// A value type: copying a registry is cheap, and registering on a copy leaves the original
/// unchanged (cel-go's `Registry.Copy`).
public struct TypeRegistry: TypeProvider, TypeAdapter {
  private var revTypeMap: [String: CELType] = [:]
  private var structTypes: [String: any StructTypeDescriptor] = [:]
  private var enumValues: [String: Int64] = [:]
  private var fallbackProvider: (any TypeProvider)?
  private var fallbackAdapter: (any TypeAdapter)?
  /// Whether enum values are ``EnumValue``s rather than `int`s; see ``Environment/Option/strongEnums``.
  package private(set) var usesStrongEnums = false

  /// Creates a registry with the standard types registered (cel-go `NewProtoRegistry` without
  /// protobuf descriptors).
  public init() {
    for type in TypeRegistry.standardTypes {
      revTypeMap[type.runtimeTypeName] = type
    }
  }

  /// Creates a registry that consults `provider` and `adapter` for anything it does not know,
  /// as cel-go `ComposeTypes` does.
  public init(composing provider: (any TypeProvider)?, adapter: (any TypeAdapter)? = nil) {
    self.init()
    fallbackProvider = provider
    fallbackAdapter = adapter
  }

  /// A registry without any types, not even the standard ones (cel-go `NewEmptyRegistry`).
  public static var empty: TypeRegistry {
    var registry = TypeRegistry()
    registry.revTypeMap = [:]
    return registry
  }

  static let standardTypes: [CELType] = [
    .bool, .bytes, .double, .duration, .int, .listOfDyn, .mapOfDyn, .null, .string, .timestamp,
    .type(nil), .uint,
  ]

  // MARK: Registration

  /// Registers a type so its name resolves to a type value, such as an abstract type introduced
  /// by an extension.
  ///
  /// - Throws: ``DeclarationError`` if a different type is already registered under the name.
  public mutating func register(_ type: CELType) throws {
    let name = type.runtimeTypeName
    if let existing = revTypeMap[name] {
      if !existing.isEquivalentType(type) {
        throw DeclarationError("type registration conflict. found: \(existing), input: \(type)")
      }
      return
    }
    revTypeMap[name] = type
  }

  /// Registers a struct type, making it available to the checker, to object construction and as
  /// a type value.
  public mutating func register(_ descriptor: any StructTypeDescriptor) throws {
    // Well-known type names are not registered as type identifiers, since they map to CEL types
    // such as `map(string, dyn)` (cel-go `registerAllTypes`); their descriptors still are.
    if CELType.checkedWellKnowns[descriptor.typeName] == nil {
      try register(CELType.objectType(descriptor.typeName))
    }
    structTypes[descriptor.typeName] = descriptor
  }

  /// Registers an enum value under its fully qualified name, such as `pkg.Color.RED`.
  public mutating func registerEnumValue(_ qualifiedName: String, number: Int64) {
    enumValues[qualifiedName] = number
  }

  // MARK: TypeProvider

  /// The numeric value of an enum value name, or `unknown enum name 'x'`.
  public func enumValue(_ enumName: String) -> Value {
    if let number = enumValues[enumName] {
      return registeredEnumValue(enumName, number)
    }
    if let fallbackProvider {
      return fallbackProvider.enumValue(enumName)
    }
    return .error(message: "unknown enum name '\(enumName)'")
  }

  /// A registered type as a type value, or an enum constant.
  public func findIdent(_ identName: String) -> Value? {
    if let type = revTypeMap[identName] {
      return .type(type)
    }
    if let number = enumValues[identName] {
      return registeredEnumValue(identName, number)
    }
    if usesStrongEnums, ownEnumTypes[identName] != nil {
      return .type(.opaque(name: identName, parameters: []))
    }
    return fallbackProvider?.findIdent(identName)
  }

  /// `type(T)` for a registered struct type `T`.
  public func findStructType(_ structType: String) -> CELType? {
    let name = sanitizeStructTypeName(structType)
    if structTypes[name] != nil {
      return .type(.objectType(name))
    }
    return fallbackProvider?.findStructType(name)
  }

  /// The field names of a registered struct type.
  public func findStructFieldNames(_ structType: String) -> [String]? {
    let name = sanitizeStructTypeName(structType)
    if let descriptor = structTypes[name] {
      return descriptor.fieldNames
    }
    return fallbackProvider?.findStructFieldNames(name)
  }

  /// The type of a field of a registered struct type.
  public func findStructFieldType(_ structType: String, fieldName: String) -> StructFieldType? {
    let name = sanitizeStructTypeName(structType)
    if let descriptor = structTypes[name] {
      if let field = descriptor.fieldType(named: fieldName) {
        return field
      }
    }
    return fallbackProvider?.findStructFieldType(name, fieldName: fieldName)
  }

  /// Creates an object of a registered struct type, or `unknown type 'x'`.
  public func newValue(_ structType: String, fields: [String: Value]) -> Value {
    let name = sanitizeStructTypeName(structType)
    if let descriptor = structTypes[name] {
      return descriptor.newValue(fields: fields)
    }
    if let fallbackProvider {
      return fallbackProvider.newValue(name, fields: fields)
    }
    return .error(message: "unknown type '\(name)'")
  }

  // MARK: Strong enums

  /// A registered enum value: an `int`, or with strong enums a value of the enum its name is in.
  private func registeredEnumValue(_ name: String, _ number: Int64) -> Value {
    guard usesStrongEnums, let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")) else {
      return .int(number)
    }
    let typeName = String(decoding: name.utf8[..<dot], as: UTF8.self)
    return .object(EnumValue(typeName: typeName, number: Int32(truncatingIfNeeded: number)))
  }

  /// The enum types of the registered enum values: everything before the last dot of their names.
  private var ownEnumTypes: [String: [String: Int32]] {
    var types: [String: [String: Int32]] = [:]
    for (name, number) in enumValues {
      guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")) else { continue }
      let typeName = String(decoding: name.utf8[..<dot], as: UTF8.self)
      let valueName = String(decoding: name.utf8[name.utf8.index(after: dot)...], as: UTF8.self)
      types[typeName, default: [:]][valueName] = Int32(truncatingIfNeeded: number)
    }
    return types
  }

  // MARK: TypeAdapter

  /// Converts a host value to a CEL value.
  ///
  /// Supported: ``Value`` itself; `Bool`; signed and unsigned integers; `Double` and `Float`;
  /// `String`; `[UInt8]`; ``CELDuration``; ``CELTimestamp``; ``ListValue``, ``MapValue`` and
  /// ``ObjectValue`` conformances; `nil`; and arrays and dictionaries (with `Bool`, integer or
  /// `String` keys) of supported values, which are converted eagerly. Anything else goes to the
  /// composed adapter, or becomes an `unsupported conversion` error.
  public func nativeToValue(_ value: Any) -> Value {
    if let converted = TypeRegistry.convertNative(value, using: self) {
      return converted
    }
    if let fallbackAdapter {
      return fallbackAdapter.nativeToValue(value)
    }
    return .error(message: "unsupported conversion to ref.Val: (\(Swift.type(of: value)))\(value)")
  }

  private static func convertNative(_ value: Any, using adapter: TypeRegistry) -> Value? {
    switch value {
    case let v as Value: return v
    case let v as Bool: return .bool(v)
    case let v as Int: return .int(Int64(v))
    case let v as Int64: return .int(v)
    case let v as Int32: return .int(Int64(v))
    case let v as Int16: return .int(Int64(v))
    case let v as Int8: return .int(Int64(v))
    case let v as UInt: return .uint(UInt64(v))
    case let v as UInt64: return .uint(v)
    case let v as UInt32: return .uint(UInt64(v))
    case let v as UInt16: return .uint(UInt64(v))
    case let v as Double: return .double(v)
    case let v as Float: return .double(Double(v))
    case let v as String: return .string(v)
    case let v as Substring: return .string(String(v))
    case let v as [UInt8]: return .bytes(v)
    case let v as CELDuration: return .duration(v)
    case let v as CELTimestamp: return .timestamp(v)
    case let v as CELType: return .type(v)
    case let v as any ListValue: return .list(v)
    case let v as any MapValue: return .map(v)
    case let v as any ObjectValue: return .object(v)
    case let v as [Any]:
      return .list(ArrayList(v.map { adapter.nativeToValue($0) }))
    case let v as [String: Any]:
      var map = OrderedMap()
      for key in v.keys.sorted(by: { compareUTF8($0, $1) < 0 }) {
        map[.string(key)] = adapter.nativeToValue(v[key] as Any)
      }
      return .map(map)
    case let v as [AnyHashable: Any]:
      var map = OrderedMap()
      for (key, element) in v {
        guard let mapKey = MapKey(adapter.nativeToValue(key.base)) else {
          return .error(message: "unsupported map key type: \(Swift.type(of: key.base))")
        }
        map[mapKey] = adapter.nativeToValue(element)
      }
      return .map(map)
    default:
      if isNil(value) {
        return .null
      }
      return nil
    }
  }
}

/// Whether an `Any` holds `Optional.none`.
private func isNil(_ value: Any) -> Bool {
  if case Optional<Any>.none = value {
    return true
  }
  let mirror = Mirror(reflecting: value)
  return mirror.displayStyle == .optional && mirror.children.isEmpty
}

/// Removes a leading dot from a struct type name.
private func sanitizeStructTypeName(_ structType: String) -> String {
  if structType.utf8.first == UInt8(ascii: ".") {
    return String(decoding: structType.utf8.dropFirst(), as: UTF8.self)
  }
  return structType
}

extension TypeRegistry: StrongEnumProvider {
  /// The enum types of the registered enum values and of the composed provider, if it supports
  /// strong enums.
  package var strongEnumTypes: [String: [String: Int32]] {
    var types = (fallbackProvider as? any StrongEnumProvider)?.strongEnumTypes ?? [:]
    types.merge(ownEnumTypes) { _, own in own }
    return types
  }

  /// The registry with strong enums enabled or disabled, here and in the composed provider and
  /// adapter.
  package func settingStrongEnums(_ enabled: Bool) -> TypeRegistry {
    var registry = self
    registry.usesStrongEnums = enabled
    if let provider = fallbackProvider as? any StrongEnumProvider {
      registry.fallbackProvider = provider.settingStrongEnums(enabled)
    }
    if let adapter = fallbackAdapter as? any StrongEnumProvider {
      registry.fallbackAdapter = adapter.settingStrongEnums(enabled) as? any TypeAdapter
    }
    return registry
  }
}

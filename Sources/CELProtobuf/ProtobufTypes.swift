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
// Ported from cel-go common/types/pb/pb.go (Db), common/types/provider.go (the protobuf parts of
// Registry: EnumValue, FindIdent, FindStructType, FindStructFieldNames, FindStructFieldType,
// NewValue, NativeToValue for messages) and common/types/pb/equal.go (Equal).

import CEL
import SwiftProtobuf

/// The protobuf message, enum and extension types known to CEL: the port of cel-go's `pb.Db`
/// together with the protobuf half of its type registry.
///
/// Build it from the ``ProtobufFile`` constants that `protoc-gen-cel-swift` generates, one per
/// `.proto` file; the well-known types (`google/protobuf/{any,duration,empty,field_mask,struct,
/// timestamp,wrappers}.proto`) are always included, and registering a file registers the files
/// it imports.
///
/// ```swift
/// let protos = ProtobufTypes(files: [My_Package_Messages_CELFile])
/// let registry = TypeRegistry(composing: protos, adapter: protos)
/// let value = protos.value(of: myMessage)   // a CEL value for an activation
/// ```
///
/// A value type: registering on a copy leaves the original unchanged. Objects created from it
/// keep the types they were created with, for `Any` unpacking and nested messages.
public struct ProtobufTypes: TypeProvider, TypeAdapter {
  final class Storage: Sendable {
    let files: [ProtobufFile]
    let messageTypes: [String: ProtobufMessageType]
    let messageTypesByMetatype: [ObjectIdentifier: ProtobufMessageType]
    let enumValues: [String: Int32]
    /// The enum types except `google.protobuf.NullValue`, with their values: the strong enum types.
    let enumTypes: [String: [String: Int32]]
    let extensions: [String: [ErasedField]]
    let extensionsByName: [String: [String: ErasedField]]
    let extensionMap: SimpleExtensionMap

    init(files: [ProtobufFile]) {
      var ordered: [ProtobufFile] = []
      var seen: Set<String> = []
      func visit(_ file: ProtobufFile) {
        if !seen.insert(file.path).inserted {
          return
        }
        for dependency in file.dependencies {
          visit(dependency)
        }
        ordered.append(file)
      }
      for file in WellKnownTypes.files + files {
        visit(file)
      }
      var messageTypes: [String: ProtobufMessageType] = [:]
      var byMetatype: [ObjectIdentifier: ProtobufMessageType] = [:]
      var enumValues: [String: Int32] = [:]
      var enumTypes: [String: [String: Int32]] = [:]
      var extensions: [String: [ErasedField]] = [:]
      var extensionsByName: [String: [String: ErasedField]] = [:]
      var extensionMap = SimpleExtensionMap()
      for file in ordered {
        for messageType in file.messageTypes {
          messageTypes[messageType.name] = messageType
          byMetatype[ObjectIdentifier(messageType.messageType)] = messageType
        }
        for enumType in file.enumTypes {
          for value in enumType.values {
            enumValues[enumType.name + "." + value.name] = value.number
          }
          if enumType.name != "google.protobuf.NullValue" {
            enumTypes[enumType.name] = Dictionary(
              enumType.values.map { ($0.name, $0.number) }, uniquingKeysWith: { first, _ in first })
          }
        }
        for ext in file.extensions {
          if extensionsByName[ext.extendedMessageName]?[ext.name] == nil {
            extensions[ext.extendedMessageName, default: []].append(ext.field)
          }
          extensionsByName[ext.extendedMessageName, default: [:]][ext.name] = ext.field
        }
        extensionMap.formUnion(file.extensionMap)
      }
      self.files = ordered
      self.messageTypes = messageTypes
      self.messageTypesByMetatype = byMetatype
      self.enumValues = enumValues
      self.enumTypes = enumTypes
      self.extensions = extensions
      self.extensionsByName = extensionsByName
      self.extensionMap = extensionMap
    }
  }

  var storage: Storage

  /// Whether fields are selected by their JSON names (`singleInt32`) instead of their proto
  /// names (`single_int32`); proto names still resolve when no JSON name matches.
  ///
  /// The port of cel-go's `JSONFieldNames` registry option.
  public let usesJSONFieldNames: Bool

  /// Whether enum values, enum constants and enum fields are values of their enum type
  /// (``EnumValue``) instead of `int`s.
  ///
  /// ``Environment/Option/strongEnums`` sets it on the environment's types; set it here for message
  /// values created outside the environment, such as activation values, so they read the same way.
  /// `google.protobuf.NullValue` stays an `int`.
  public private(set) var usesStrongEnums: Bool

  /// Creates the types of the given files, their dependencies and the well-known types.
  ///
  /// - Parameters:
  ///   - files: Generated file descriptions.
  ///   - jsonFieldNames: Whether fields are selected by their JSON names.
  ///   - strongEnums: Whether enum values are values of their enum type instead of `int`s.
  public init(files: [ProtobufFile] = [], jsonFieldNames: Bool = false, strongEnums: Bool = false) {
    storage = Storage(files: files)
    usesJSONFieldNames = jsonFieldNames
    usesStrongEnums = strongEnums
  }

  /// Adds the types of a file and its dependencies.
  public mutating func register(_ file: ProtobufFile) {
    storage = Storage(files: storage.files + [file])
  }

  /// The paths of the registered files, dependencies first.
  public var filePaths: [String] {
    storage.files.map(\.path)
  }

  /// The swift-protobuf extension map of every registered extension, for decoding messages
  /// with extensions.
  public var extensionMap: SimpleExtensionMap {
    storage.extensionMap
  }

  /// The registered message type with the given fully qualified name.
  public func messageType(named name: String) -> ProtobufMessageType? {
    storage.messageTypes[sanitizeProtoName(name)]
  }

  func messageType(of message: any SwiftProtobuf.Message) -> ProtobufMessageType? {
    storage.messageTypesByMetatype[ObjectIdentifier(type(of: message))]
  }

  func extensionFields(of messageName: String) -> [ErasedField] {
    storage.extensions[messageName] ?? []
  }

  /// cel-go `TypeDescription.FieldByName`: JSON names first when enabled, then proto names, then
  /// extensions by fully qualified name.
  func field(named name: String, in messageType: ProtobufMessageType) -> ErasedField? {
    if usesJSONFieldNames, let index = messageType.fieldsByJSONName[name] {
      return messageType.fields[index]
    }
    if let index = messageType.fieldsByName[name] {
      return messageType.fields[index]
    }
    return storage.extensionsByName[messageType.name]?[name]
  }

  // MARK: Values

  /// Converts a protobuf message to a CEL value.
  ///
  /// Well-known types become their CEL equivalents (wrappers become primitives, `Struct` a map,
  /// `Any` its unpacked content, and so on); other messages become ``ProtobufObject`` values.
  /// Messages of unregistered types are an `unknown type` error value.
  public func value(of message: any SwiftProtobuf.Message) -> Value {
    if let wellKnown = WellKnownTypes.value(of: message, types: self) {
      return wellKnown
    }
    guard let messageType = messageType(of: message) else {
      return .error(EvalError("unknown type: '\(type(of: message).protoMessageName)'"))
    }
    return .object(ProtobufObject(message: message, messageType: messageType, types: self))
  }

  /// Converts a CEL value to a protobuf message of type `M`, as assigning it to a field of that
  /// type would: wrappers from primitives, `Any` by packing, `Value` / `Struct` / `ListValue`
  /// by the JSON mapping, `Duration` and `Timestamp` from CEL durations and timestamps, and
  /// other messages from objects of the same type. The port of cel-go `ConvertToNative` for
  /// protobuf targets.
  ///
  /// - Throws: ``EvalError`` if the value cannot be converted, including `null` for messages
  ///   that have no null form.
  public func message<M: SwiftProtobuf.Message>(from value: Value, as type: M.Type) throws -> M {
    switch WellKnownTypes.convert(value, to: type, types: self) {
    case .success(let message?):
      return message
    case .success(nil):
      throw EvalError("type conversion error from 'null_type' to '\(M.protoMessageName)'")
    case .failure(let error):
      throw error
    }
  }

  /// Unpacks an `Any` with the registered types.
  func unpack(_ any: Google_Protobuf_Any) -> Result<any SwiftProtobuf.Message, EvalError> {
    let name = typeName(fromURL: any.typeURL)
    guard let messageType = storage.messageTypes[name] else {
      return .failure(
        EvalError("anypb.UnmarshalNew() failed for type \"\(any.typeURL)\": proto: not found"))
    }
    do {
      return .success(try messageType.unpack(any, storage.extensionMap))
    } catch {
      return .failure(
        EvalError("anypb.UnmarshalNew() failed for type \"\(any.typeURL)\": \(error)"))
    }
  }

  /// Protobuf equality, the port of cel-go `pb.Equal`: messages of the same type with equal set
  /// fields; NaN is unequal to itself; `Any` values are compared after unpacking.
  func messagesEqual(_ x: any SwiftProtobuf.Message, _ y: any SwiftProtobuf.Message) -> Bool {
    if type(of: x) != type(of: y) {
      return false
    }
    if let ax = x as? Google_Protobuf_Any, let ay = y as? Google_Protobuf_Any {
      if ax.typeURL != ay.typeURL {
        return false
      }
      if ax.value == ay.value {
        return true
      }
      guard case .success(let ux) = unpack(ax), case .success(let uy) = unpack(ay) else {
        return false
      }
      return messagesEqual(ux, uy)
    }
    guard let messageType = messageType(of: x) else {
      return x.isEqualTo(message: y)
    }
    return messageType.equal(x, y, self)
  }

  /// Corrects the JSON swift-protobuf wrote for a message to what protojson (and so cel-go) writes:
  /// every `google.protobuf.NullValue` is `null`, in nested messages too.
  func patchJSON(of message: any SwiftProtobuf.Message, _ json: inout Google_Protobuf_Value) {
    guard let messageType = messageType(of: message), case .structValue(var object)? = json.kind else {
      return
    }
    var changed = false
    for field in messageType.fields {
      guard let patch = field.patchJSON else { continue }
      var element = object.fields[field.jsonName]
      patch(message, &element, self)
      object.fields[field.jsonName] = element
      changed = true
    }
    if changed {
      json.structValue = object
    }
  }

  // MARK: TypeProvider

  /// The number of an enum value given its fully qualified name, or an `unknown enum name` error.
  public func enumValue(_ enumName: String) -> Value {
    let name = sanitizeProtoName(enumName)
    if let number = storage.enumValues[name] {
      return enumConstant(name, number)
    }
    return .error(EvalError("unknown enum name '\(enumName)'"))
  }

  /// An enum constant: an `int`, or with strong enums a value of its enum type.
  private func enumConstant(_ name: String, _ number: Int32) -> Value {
    guard usesStrongEnums, let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")) else {
      return .int(Int64(number))
    }
    let typeName = String(decoding: name.utf8[..<dot], as: UTF8.self)
    guard storage.enumTypes[typeName] != nil else {
      return .int(Int64(number))
    }
    return .object(EnumValue(typeName: typeName, number: number))
  }

  /// A message type name as a type value, or an enum value as an `int`; with strong enums, an enum
  /// type name as a type value and an enum value as a value of its enum.
  ///
  /// Well-known types with CEL equivalents (wrappers, `Any`, `Struct`, ...) are not identifiers
  /// here, as in cel-go.
  public func findIdent(_ identName: String) -> Value? {
    if storage.messageTypes[identName] != nil {
      let type = CELType.objectType(identName)
      if case .object = type {
        return .type(type)
      }
    }
    if let number = storage.enumValues[identName] {
      return enumConstant(identName, number)
    }
    if usesStrongEnums, storage.enumTypes[identName] != nil {
      return .type(.opaque(name: identName, parameters: []))
    }
    return nil
  }

  /// `type(T)` for a registered message type `T`; well-known types map to their CEL types.
  public func findStructType(_ structType: String) -> CELType? {
    let name = sanitizeProtoName(structType)
    guard storage.messageTypes[name] != nil else { return nil }
    return .type(CELType.objectType(name))
  }

  /// The field names of a registered message type (JSON names when enabled).
  public func findStructFieldNames(_ structType: String) -> [String]? {
    guard let messageType = messageType(named: structType) else { return nil }
    return messageType.fields.map { usesJSONFieldNames ? $0.jsonName : $0.name }
  }

  /// The type of a field or extension of a registered message type.
  public func findStructFieldType(_ structType: String, fieldName: String) -> StructFieldType? {
    guard let messageType = messageType(named: structType),
      let field = field(named: fieldName, in: messageType)
    else { return nil }
    let strongEnums = usesStrongEnums
    return StructFieldType(
      name: field.name,
      type: strongEnums ? field.strongEnumType ?? field.type : field.type,
      isJSONField: usesJSONFieldNames && !field.isExtension && fieldName == field.jsonName,
      isSet: { object in
        guard let proto = object as? ProtobufObject else {
          return object.isFieldSet(field.name) == .bool(true)
        }
        return field.isSet(proto.message)
      },
      getFrom: { object in
        guard let proto = object as? ProtobufObject else {
          return object.field(field.name)
        }
        // The field's checked type follows this provider's enums, whatever the object's types do.
        return field.get(proto.message, proto.types.settingStrongEnums(strongEnums))
      }
    )
  }

  /// Creates a message from field values; well-known types are returned as their CEL values.
  ///
  /// Values are converted as cel-go does: `int` to 32-bit fields with a range check, `null`
  /// leaves message fields unset, lists and maps become JSON values where the field is a
  /// `google.protobuf.Value`, any value is packed into `google.protobuf.Any` fields.
  public func newValue(_ structType: String, fields: [String: Value]) -> Value {
    let name = sanitizeProtoName(structType)
    guard let messageType = storage.messageTypes[name] else {
      return .error(EvalError("unknown type '\(name)'"))
    }
    var assignments: [(field: ErasedField, value: Value)] = []
    assignments.reserveCapacity(fields.count)
    for (fieldName, value) in fields {
      guard let field = field(named: fieldName, in: messageType) else {
        return .error(EvalError("no such field: \(fieldName)"))
      }
      assignments.append((field, value))
    }
    assignments.sort { $0.field.number < $1.field.number }
    switch messageType.build(assignments, self) {
    case .success(let message):
      return value(of: message)
    case .failure(let error):
      return .error(error)
    }
  }

  // MARK: TypeAdapter

  /// Converts a protobuf message (any swift-protobuf `Message`) to a CEL value, or returns an
  /// `unsupported conversion` error for anything else.
  public func nativeToValue(_ value: Any) -> Value {
    if let message = value as? any SwiftProtobuf.Message {
      return self.value(of: message)
    }
    return .error(EvalError("unsupported conversion to ref.Val: (\(type(of: value)))\(value)"))
  }
}

extension ProtobufTypes: StrongEnumProvider {
  /// The enum types of the registered files, except `google.protobuf.NullValue`.
  package var strongEnumTypes: [String: [String: Int32]] {
    storage.enumTypes
  }

  /// The types with strong enums enabled or disabled; see ``usesStrongEnums``.
  package func settingStrongEnums(_ enabled: Bool) -> ProtobufTypes {
    if usesStrongEnums == enabled {
      return self
    }
    var types = self
    types.usesStrongEnums = enabled
    return types
  }
}

/// Removes a leading dot from a proto name.
func sanitizeProtoName(_ name: String) -> String {
  if name.utf8.first == UInt8(ascii: ".") {
    return String(decoding: name.utf8.dropFirst(), as: UTF8.self)
  }
  return name
}

/// The message name of a type URL: everything after the last `/`.
func typeName(fromURL url: String) -> String {
  guard let slash = url.utf8.lastIndex(of: UInt8(ascii: "/")) else {
    return url
  }
  return String(decoding: url.utf8[url.utf8.index(after: slash)...], as: UTF8.self)
}

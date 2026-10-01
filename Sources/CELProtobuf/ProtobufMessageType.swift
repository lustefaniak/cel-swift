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
// Ported from cel-go common/types/pb/type.go (TypeDescription), common/types/pb/enum.go
// (EnumValueDescription), common/types/pb/file.go (FileDescription) and
// common/types/pb/equal.go (equalMessage, equalUnknown).

import CEL
import SwiftProtobuf

/// A protobuf message type described to CEL: its fully qualified name, its fields, and how to
/// create, unpack and compare its messages.
///
/// Created by generated message adapters with ``init(_:fields:)``; the Swift message type is
/// erased so types of different messages can be stored together.
public struct ProtobufMessageType: Sendable {
  /// The fully qualified message name, such as `cel.expr.conformance.proto3.TestAllTypes`.
  public let name: String
  /// The fields in declaration order.
  let fields: [ErasedField]
  let fieldsByName: [String: Int]
  let fieldsByJSONName: [String: Int]
  let messageType: any SwiftProtobuf.Message.Type
  let makeEmpty: @Sendable () -> any SwiftProtobuf.Message
  let unpack: @Sendable (Google_Protobuf_Any, (any ExtensionMap)?) throws -> any SwiftProtobuf.Message
  let isDefault: @Sendable (any SwiftProtobuf.Message) -> Bool
  /// Sets fields on a message of this type; extension fields come from `ProtobufTypes`.
  let build:
    @Sendable ([(field: ErasedField, value: Value)], ProtobufTypes) -> Result<
      any SwiftProtobuf.Message, EvalError
    >
  let equal: @Sendable (any SwiftProtobuf.Message, any SwiftProtobuf.Message, ProtobufTypes) -> Bool

  /// Describes the message type `M` with its fields.
  ///
  /// - Parameters:
  ///   - type: The swift-protobuf message type.
  ///   - fields: The regular (non-extension) fields, in declaration order.
  public init<M: SwiftProtobuf.Message>(_ type: M.Type, fields: [ProtobufField<M>]) {
    let erased = fields.map { ErasedField($0, isExtension: false) }
    name = M.protoMessageName
    self.fields = erased
    var byName: [String: Int] = [:]
    var byJSONName: [String: Int] = [:]
    for (index, field) in erased.enumerated() {
      byName[field.name] = index
      byJSONName[field.jsonName] = index
    }
    fieldsByName = byName
    fieldsByJSONName = byJSONName
    messageType = M.self
    makeEmpty = { M() }
    unpack = { any, extensions in try M(unpackingAny: any, extensions: extensions) }
    isDefault = { message in
      guard let m = message as? M else { return false }
      return m.isEqualTo(message: M())
    }
    let name = M.protoMessageName
    build = { assignments, types in
      var m = M()
      for (field, value) in assignments {
        guard let typed = field.typed as? ProtobufField<M> else {
          return .failure(EvalError("no such field: \(field.name)"))
        }
        if let error = typed.set(&m, value, types) {
          return .failure(error)
        }
      }
      return .success(m)
    }
    equal = { x, y, types in
      guard let a = x as? M, let b = y as? M else { return false }
      for field in fields where !field.equal(a, b, types) {
        return false
      }
      for ext in types.extensionFields(of: name) {
        guard let typed = ext.typed as? ProtobufField<M> else { continue }
        if !typed.equal(a, b, types) {
          return false
        }
      }
      return equalUnknown(Array(a.unknownFields.data), Array(b.unknownFields.data))
    }
  }

  /// The field names, in declaration order.
  public var fieldNames: [String] {
    fields.map(\.name)
  }
}

/// A type-erased ``ProtobufField``.
struct ErasedField: Sendable {
  let name: String
  let jsonName: String
  let number: Int32
  let type: CELType
  /// See ``ProtobufField/strongEnumType``.
  let strongEnumType: CELType?
  let isExtension: Bool
  /// The `ProtobufField<M>`, cast back where `M` is known.
  let typed: any Sendable
  let get: @Sendable (any SwiftProtobuf.Message, ProtobufTypes) -> Value
  let isSet: @Sendable (any SwiftProtobuf.Message) -> Bool
  /// See ``ProtobufField/patchJSON``.
  let patchJSON: (@Sendable (any SwiftProtobuf.Message, inout Google_Protobuf_Value?, ProtobufTypes) -> Void)?

  init<M>(_ field: ProtobufField<M>, isExtension: Bool) {
    name = field.name
    jsonName = field.jsonName
    number = field.number
    type = field.type
    strongEnumType = field.strongEnumType
    self.isExtension = isExtension
    typed = field
    get = { message, types in
      guard let m = message as? M else {
        return .error(EvalError("unsupported field selection target: \(Swift.type(of: message))"))
      }
      return field.get(m, types)
    }
    isSet = { message in
      guard let m = message as? M else { return false }
      return field.isSet(m)
    }
    if let patch = field.patchJSON {
      patchJSON = { message, json, types in
        guard let m = message as? M else { return }
        patch(m, &json, types)
      }
    } else {
      patchJSON = nil
    }
  }
}

/// A protobuf extension field, selected in CEL by its fully qualified name.
public struct ProtobufExtension: Sendable {
  /// The fully qualified name of the extended message.
  public let extendedMessageName: String
  let field: ErasedField

  /// Describes an extension of the message type `M`.
  ///
  /// - Parameter field: The extension field, named by its fully qualified name, built on the
  ///   extension's swift-protobuf accessor properties.
  public init<M: SwiftProtobuf.Message>(_ field: ProtobufField<M>) {
    extendedMessageName = M.protoMessageName
    self.field = ErasedField(field, isExtension: true)
  }

  /// The fully qualified extension name, such as `cel.expr.conformance.proto2.int32_ext`.
  public var name: String { field.name }
}

/// A protobuf enum type: its fully qualified name and its values.
public struct ProtobufEnumType: Sendable {
  /// The fully qualified enum name, such as `cel.expr.conformance.proto3.GlobalEnum`.
  public let name: String
  /// The values as (name, number) pairs, in declaration order.
  public let values: [(name: String, number: Int32)]

  /// Describes an enum type.
  ///
  /// - Parameters:
  ///   - name: The fully qualified enum name.
  ///   - values: The value names (unqualified) and numbers.
  public init(_ name: String, values: [(name: String, number: Int32)]) {
    self.name = name
    self.values = values
  }
}

/// The CEL description of one `.proto` file: its message types, enums and extensions, and the
/// files it imports. Generated by `protoc-gen-cel-swift` as a global constant per file.
public struct ProtobufFile: Sendable {
  /// The path of the `.proto` file, such as `google/protobuf/struct.proto`.
  public let path: String
  /// The message types declared in the file, including nested ones.
  public let messageTypes: [ProtobufMessageType]
  /// The enum types declared in the file, including nested ones.
  public let enumTypes: [ProtobufEnumType]
  /// The extensions declared in the file, including those scoped in messages.
  public let extensions: [ProtobufExtension]
  /// The swift-protobuf extension map for the file's extensions, used to decode them from `Any`.
  public let extensionMap: SimpleExtensionMap
  /// The files this file imports, so that registering a file also registers its dependencies.
  public let dependencies: [ProtobufFile]

  /// Describes a `.proto` file.
  public init(
    path: String,
    messageTypes: [ProtobufMessageType] = [],
    enumTypes: [ProtobufEnumType] = [],
    extensions: [ProtobufExtension] = [],
    extensionMap: SimpleExtensionMap = SimpleExtensionMap(),
    dependencies: [ProtobufFile] = []
  ) {
    self.path = path
    self.messageTypes = messageTypes
    self.enumTypes = enumTypes
    self.extensions = extensions
    self.extensionMap = extensionMap
    self.dependencies = dependencies
  }
}

// MARK: - Unknown fields

/// Compares unknown fields: byte-equal, or equal after grouping the records by field number.
/// Port of cel-go `equalUnknown`.
func equalUnknown(_ x: [UInt8], _ y: [UInt8]) -> Bool {
  if x.count != y.count {
    return false
  }
  if x.isEmpty || x == y {
    return true
  }
  guard let mx = groupUnknownFields(x), let my = groupUnknownFields(y) else {
    return false
  }
  return mx == my
}

private func groupUnknownFields(_ bytes: [UInt8]) -> [UInt64: [UInt8]]? {
  var result: [UInt64: [UInt8]] = [:]
  var index = 0
  while index < bytes.count {
    let start = index
    guard let (fieldNumber, end) = consumeField(bytes, at: index) else { return nil }
    result[fieldNumber, default: []].append(contentsOf: bytes[start..<end])
    index = end
  }
  return result
}

/// Consumes one wire-format record and returns its field number and the index after it.
private func consumeField(_ bytes: [UInt8], at start: Int) -> (UInt64, Int)? {
  guard let (tag, afterTag) = consumeVarint(bytes, at: start) else { return nil }
  let fieldNumber = tag >> 3
  guard let end = consumeFieldValue(bytes, at: afterTag, fieldNumber: fieldNumber, wireType: tag & 7)
  else { return nil }
  return (fieldNumber, end)
}

private func consumeFieldValue(_ bytes: [UInt8], at index: Int, fieldNumber: UInt64, wireType: UInt64)
  -> Int?
{
  switch wireType {
  case 0:
    return consumeVarint(bytes, at: index)?.1
  case 1:
    return index + 8 <= bytes.count ? index + 8 : nil
  case 2:
    guard let (length, after) = consumeVarint(bytes, at: index),
      length <= UInt64(bytes.count - after)
    else { return nil }
    return after + Int(length)
  case 3:
    // A group: records until the matching end-group tag.
    var i = index
    while i < bytes.count {
      guard let (tag, afterTag) = consumeVarint(bytes, at: i) else { return nil }
      if tag & 7 == 4 {
        return tag >> 3 == fieldNumber ? afterTag : nil
      }
      guard let end = consumeFieldValue(bytes, at: afterTag, fieldNumber: tag >> 3, wireType: tag & 7)
      else { return nil }
      i = end
    }
    return nil
  case 5:
    return index + 4 <= bytes.count ? index + 4 : nil
  default:
    return nil
  }
}

private func consumeVarint(_ bytes: [UInt8], at start: Int) -> (UInt64, Int)? {
  var result: UInt64 = 0
  var shift: UInt64 = 0
  var index = start
  while index < bytes.count, shift < 64 {
    let byte = bytes[index]
    result |= UInt64(byte & 0x7F) << shift
    index += 1
    if byte & 0x80 == 0 {
      return (result, index)
    }
    shift += 7
  }
  return nil
}

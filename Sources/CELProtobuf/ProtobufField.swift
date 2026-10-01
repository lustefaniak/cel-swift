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
// Ported from cel-go common/types/pb/type.go (FieldDescription: IsSet, GetFrom, CheckedType),
// common/types/pb/equal.go (equalField, equalList, equalMap) and common/types/provider.go
// (msgSetField, msgSetListField, msgSetMapField, fieldDescToCELType).

import CEL
import SwiftProtobuf

/// A field of a protobuf message type `M`, as described to CEL by a generated message adapter.
///
/// Generated code builds fields with ``singular(_:number:jsonName:_:_:presence:)``,
/// ``repeated(_:number:jsonName:_:_:)`` and ``map(_:number:jsonName:_:key:value:)``, passing a
/// key path to the swift-protobuf property and the ``ProtobufValueKind`` of its values.
public struct ProtobufField<M: SwiftProtobuf.Message>: Sendable {
  /// The proto field name (`single_int32`), or the fully qualified name of an extension.
  public let name: String
  /// The JSON name of the field (`singleInt32` unless the proto sets `json_name`).
  public let jsonName: String
  /// The field number.
  public let number: Int32
  /// The CEL type of the field, as the type checker sees it.
  public let type: CELType
  /// The CEL type of the field with strong enums, when it differs from ``type``: enum fields have
  /// their enum type.
  let strongEnumType: CELType?

  let get: @Sendable (M, ProtobufTypes) -> Value
  let isSet: @Sendable (M) -> Bool
  let set: @Sendable (inout M, Value, ProtobufTypes) -> EvalError?
  let equal: @Sendable (M, M, ProtobufTypes) -> Bool
  /// Corrects the field's JSON as swift-protobuf wrote it (`nil` when the field was left out) to
  /// protojson's; `nil` when the two always agree. See ``ProtobufValueKind/patchJSON``.
  var patchJSON: (@Sendable (M, inout Google_Protobuf_Value?, ProtobufTypes) -> Void)? = nil

  /// How a singular field tracks presence, which decides `has()`.
  public enum Presence: Sendable {
    /// proto3 fields without `optional`: set when not the zero value.
    case implicit
    /// Fields with a `has` accessor: proto2 `optional`, proto3 `optional`, message fields and
    /// extensions.
    case explicit(KeyPath<M, Bool> & Sendable)
    /// Members of a `oneof`: set when the oneof holds this member.
    case oneof(@Sendable (M) -> Bool)
  }

  /// A singular (non-repeated) field.
  ///
  /// - Parameters:
  ///   - name: The proto field name, or the fully qualified name of an extension.
  ///   - number: The field number.
  ///   - jsonName: The JSON name; defaults to the lower camel case form of `name`.
  ///   - keyPath: The swift-protobuf property holding the field.
  ///   - kind: How values convert to and from CEL.
  ///   - presence: How the field tracks presence.
  public static func singular<V>(
    _ name: String,
    number: Int32,
    jsonName: String? = nil,
    _ keyPath: WritableKeyPath<M, V> & Sendable,
    _ kind: ProtobufValueKind<V>,
    presence: Presence = .implicit
  ) -> ProtobufField<M> {
    let isSet: @Sendable (M) -> Bool
    switch presence {
    case .implicit:
      isSet = { m in !kind.isZero(m[keyPath: keyPath]) }
    case .explicit(let hasKeyPath):
      isSet = { m in m[keyPath: hasKeyPath] }
    case .oneof(let test):
      isSet = test
    }
    let unsetValue = kind.unsetValue
    return ProtobufField(
      name: name,
      jsonName: jsonName ?? defaultJSONName(name),
      number: number,
      type: kind.celType,
      strongEnumType: kind.enumTypeName.map { _ in kind.celType(strongEnums: true) },
      get: { m, types in
        if let unsetValue, !isSet(m) {
          return unsetValue
        }
        return kind.toValue(m[keyPath: keyPath], types)
      },
      isSet: isSet,
      set: { m, value, types in
        switch kind.fromValue(value, types) {
        case .success(let converted?):
          m[keyPath: keyPath] = converted
          return nil
        case .success(nil):
          return nil
        case .failure(let error):
          return fieldTypeConversionError(M.self, name, error)
        }
      },
      equal: { a, b, types in
        let aSet = isSet(a)
        if aSet != isSet(b) {
          return false
        }
        return !aSet || kind.equal(a[keyPath: keyPath], b[keyPath: keyPath], types)
      },
      patchJSON: singularJSONPatch(keyPath, kind)
    )
  }

  /// A repeated field.
  ///
  /// - Parameters:
  ///   - name: The proto field name, or the fully qualified name of an extension.
  ///   - number: The field number.
  ///   - jsonName: The JSON name; defaults to the lower camel case form of `name`.
  ///   - keyPath: The swift-protobuf property holding the elements.
  ///   - kind: How elements convert to and from CEL.
  public static func repeated<V>(
    _ name: String,
    number: Int32,
    jsonName: String? = nil,
    _ keyPath: WritableKeyPath<M, [V]> & Sendable,
    _ kind: ProtobufValueKind<V>
  ) -> ProtobufField<M> {
    ProtobufField(
      name: name,
      jsonName: jsonName ?? defaultJSONName(name),
      number: number,
      type: .list(kind.celType),
      strongEnumType: kind.enumTypeName.map { _ in .list(kind.celType(strongEnums: true)) },
      get: { m, types in
        .list(ProtobufRepeatedList(elements: m[keyPath: keyPath], kind: kind, types: types))
      },
      isSet: { m in !m[keyPath: keyPath].isEmpty },
      set: { m, value, types in
        guard case .list(let list) = value else {
          return unsupportedFieldTypeError(M.self, name, value)
        }
        var elements: [V] = []
        elements.reserveCapacity(list.count)
        for i in 0..<list.count {
          switch kind.fromValue(list.element(at: i), types) {
          case .success(let element?): elements.append(element)
          case .success(nil): continue
          case .failure(let error): return fieldTypeConversionError(M.self, name, error)
          }
        }
        m[keyPath: keyPath] = elements
        return nil
      },
      equal: { a, b, types in
        let x = a[keyPath: keyPath]
        let y = b[keyPath: keyPath]
        guard x.count == y.count else { return false }
        for (ex, ey) in zip(x, y) where !kind.equal(ex, ey, types) {
          return false
        }
        return true
      },
      patchJSON: repeatedJSONPatch(keyPath, kind)
    )
  }

  /// A map field.
  ///
  /// - Parameters:
  ///   - name: The proto field name.
  ///   - number: The field number.
  ///   - jsonName: The JSON name; defaults to the lower camel case form of `name`.
  ///   - keyPath: The swift-protobuf property holding the entries.
  ///   - key: How keys convert to and from CEL.
  ///   - value: How values convert to and from CEL.
  public static func map<K: Hashable, V>(
    _ name: String,
    number: Int32,
    jsonName: String? = nil,
    _ keyPath: WritableKeyPath<M, [K: V]> & Sendable,
    key: ProtobufValueKind<K>,
    value: ProtobufValueKind<V>
  ) -> ProtobufField<M> {
    ProtobufField(
      name: name,
      jsonName: jsonName ?? defaultJSONName(name),
      number: number,
      type: .map(key: key.celType, value: value.celType),
      strongEnumType: value.enumTypeName.map { _ in
        .map(key: key.celType, value: value.celType(strongEnums: true))
      },
      get: { m, types in
        .map(
          ProtobufMap(entries: m[keyPath: keyPath], keyKind: key, valueKind: value, types: types))
      },
      isSet: { m in !m[keyPath: keyPath].isEmpty },
      set: { m, mapValue, types in
        guard case .map(let source) = mapValue else {
          return unsupportedFieldTypeError(M.self, name, mapValue)
        }
        var entries: [K: V] = [:]
        entries.reserveCapacity(source.count)
        for sourceKey in source.keys {
          let k: K
          switch key.fromValue(sourceKey.value, types) {
          case .success(let converted?): k = converted
          case .success(nil): continue
          case .failure(let error): return fieldTypeConversionError(M.self, name, error)
          }
          let element = source.value(forKey: sourceKey) ?? .null
          switch value.fromValue(element, types) {
          case .success(let converted?): entries[k] = converted
          case .success(nil): continue
          case .failure(let error): return fieldTypeConversionError(M.self, name, error)
          }
        }
        m[keyPath: keyPath] = entries
        return nil
      },
      equal: { a, b, types in
        let x = a[keyPath: keyPath]
        let y = b[keyPath: keyPath]
        guard x.count == y.count else { return false }
        for (k, vx) in x {
          guard let vy = y[k], value.equal(vx, vy, types) else { return false }
        }
        return true
      },
      patchJSON: mapJSONPatch(keyPath, key, value)
    )
  }
}

extension ProtobufField {
  typealias JSONPatch = @Sendable (M, inout Google_Protobuf_Value?, ProtobufTypes) -> Void

  static func singularJSONPatch<V>(
    _ keyPath: WritableKeyPath<M, V> & Sendable, _ kind: ProtobufValueKind<V>
  ) -> JSONPatch? {
    guard let patch = kind.patchJSON else { return nil }
    return { m, json, types in
      guard var present = json else { return }
      patch(m[keyPath: keyPath], &present, types)
      json = present
    }
  }

  static func repeatedJSONPatch<V>(
    _ keyPath: WritableKeyPath<M, [V]> & Sendable, _ kind: ProtobufValueKind<V>
  ) -> JSONPatch? {
    guard let patch = kind.patchJSON else { return nil }
    return { m, json, types in
      guard case .listValue(var list)? = json?.kind else { return }
      for (index, element) in m[keyPath: keyPath].enumerated() where index < list.values.count {
        patch(element, &list.values[index], types)
      }
      json?.listValue = list
    }
  }

  static func mapJSONPatch<K: Hashable, V>(
    _ keyPath: WritableKeyPath<M, [K: V]> & Sendable, _ key: ProtobufValueKind<K>,
    _ value: ProtobufValueKind<V>
  ) -> JSONPatch? {
    guard let patch = value.patchJSON, let toMapKey = key.toMapKey else { return nil }
    return { m, json, types in
      guard case .structValue(var object)? = json?.kind else { return }
      for (k, v) in m[keyPath: keyPath] {
        let name = jsonMapKey(toMapKey(k))
        guard var element = object.fields[name] else { continue }
        patch(v, &element, types)
        object.fields[name] = element
      }
      json?.structValue = object
    }
  }
}

/// A map key as a JSON object member name, as protojson writes it.
func jsonMapKey(_ key: MapKey) -> String {
  switch key.value {
  case .bool(let b): return b ? "true" : "false"
  case .int(let i): return String(i)
  case .uint(let u): return String(u)
  case .string(let s): return s
  default: return ""
  }
}

/// The JSON name protoc derives from a field name: lower camel case at underscores.
func defaultJSONName(_ name: String) -> String {
  var result = ""
  var capitalizeNext = false
  for scalar in name.unicodeScalars {
    if scalar == "_" {
      capitalizeNext = true
    } else if capitalizeNext {
      result.unicodeScalars.append(contentsOf: String(scalar).uppercased().unicodeScalars)
      capitalizeNext = false
    } else {
      result.unicodeScalars.append(scalar)
    }
  }
  return result
}

/// cel-go `fieldTypeConversionError`.
func fieldTypeConversionError<M: SwiftProtobuf.Message>(
  _: M.Type, _ field: String, _ error: EvalError
) -> EvalError {
  EvalError(
    "field type conversion error for \(M.protoMessageName).\(field) value type: \(error.message)")
}

/// cel-go `unsupportedTypeConversionError`.
func unsupportedFieldTypeError<M: SwiftProtobuf.Message>(
  _: M.Type, _ field: String, _ value: Value
) -> EvalError {
  EvalError("unsupported field type for \(M.protoMessageName).\(field): \(value.runtimeTypeName)")
}

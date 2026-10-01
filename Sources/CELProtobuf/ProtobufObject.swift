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
// Ported from cel-go common/types/object.go (protoObj).

import CEL
import SwiftProtobuf

/// A protobuf message as a CEL object value.
///
/// Field selection unwraps well-known types and follows proto2 / proto3 defaults; `has()`
/// follows protobuf presence (non-empty for repeated and map fields, the `has` accessor for
/// fields with explicit presence, non-zero for proto3 scalars). Equality is protobuf equality.
public struct ProtobufObject: ObjectValue, CustomStringConvertible {
  /// The message.
  public let message: any SwiftProtobuf.Message
  /// The type of the message.
  public let messageType: ProtobufMessageType
  let types: ProtobufTypes

  init(message: any SwiftProtobuf.Message, messageType: ProtobufMessageType, types: ProtobufTypes) {
    self.message = message
    self.messageType = messageType
    self.types = types
  }

  /// The message type, `CELType.object(name)`.
  public var celType: CELType {
    .object(messageType.name)
  }

  /// The value of a field, the default value when unset, or `no such field 'x'`.
  public func field(_ name: String) -> Value {
    guard let field = types.field(named: name, in: messageType) else {
      return .error(EvalError("no such field '\(name)'"))
    }
    return field.get(message, types)
  }

  /// Whether a field is set, or `no such field 'x'`.
  public func isFieldSet(_ name: String) -> Value {
    guard let field = types.field(named: name, in: messageType) else {
      return .error(EvalError("no such field '\(name)'"))
    }
    return .bool(field.isSet(message))
  }

  /// Protobuf equality with another message object.
  public func isEqual(to other: any ObjectValue) -> Bool {
    guard let other = other as? ProtobufObject else { return false }
    return types.messagesEqual(message, other.message)
  }

  /// Whether the message equals the default instance of its type.
  public var isZeroValue: Bool {
    messageType.isDefault(message)
  }

  /// cel-go's format: `pkg.Msg{field: value, ...}` with the set fields in field number order,
  /// extensions quoted with backticks.
  public var description: String {
    var set = messageType.fields.filter { $0.isSet(message) }
    set += types.extensionFields(of: messageType.name).filter { $0.isSet(message) }
    set.sort { $0.number < $1.number }
    var out = messageType.name + "{"
    for (i, field) in set.enumerated() {
      if i > 0 {
        out += ", "
      }
      out += field.isExtension ? "`\(field.name)`: " : "\(field.name): "
      out += field.get(message, types).description
    }
    return out + "}"
  }
}

// MARK: - Repeated and map fields

/// A repeated field as a CEL list, converting elements on access.
struct ProtobufRepeatedList<V: Sendable>: ListValue {
  let elements: [V]
  let kind: ProtobufValueKind<V>
  let types: ProtobufTypes

  var count: Int { elements.count }

  func element(at index: Int) -> Value {
    kind.toValue(elements[index], types)
  }
}

/// A map field as a CEL map, converting entries on access. Keys iterate in sorted order.
struct ProtobufMap<K: Hashable & Sendable, V: Sendable>: MapValue {
  let entries: [K: V]
  let keyKind: ProtobufValueKind<K>
  let valueKind: ProtobufValueKind<V>
  let types: ProtobufTypes

  var count: Int { entries.count }

  func forEachKey(_ body: (MapKey) throws -> Bool) rethrows {
    guard let toMapKey = keyKind.toMapKey else { return }
    for key in entries.keys.map(toMapKey).sorted(by: mapKeyPrecedes) {
      if try !body(key) {
        return
      }
    }
  }

  func value(forKey key: MapKey) -> Value? {
    guard let k = keyKind.fromMapKey?(key), let v = entries[k] else { return nil }
    return valueKind.toValue(v, types)
  }
}

/// A total order on map keys, for deterministic iteration.
func mapKeyPrecedes(_ a: MapKey, _ b: MapKey) -> Bool {
  switch (a, b) {
  case (.bool(let x), .bool(let y)): return !x && y
  case (.int(let x), .int(let y)): return x < y
  case (.uint(let x), .uint(let y)): return x < y
  case (.string(let x), .string(let y)): return x.utf8.lexicographicallyPrecedes(y.utf8)
  default: return rank(a) < rank(b)
  }
}

private func rank(_ key: MapKey) -> Int {
  switch key {
  case .bool: return 0
  case .int: return 1
  case .uint: return 2
  case .string: return 3
  }
}

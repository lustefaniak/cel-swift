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
// Ported from cel-go common/types/pb/checked.go (CheckedPrimitives), common/types/provider.go
// (ProtoCELPrimitives, NativeToValue for scalars) and the ConvertToNative methods of
// common/types/{int,uint,double,bool,string,bytes}.go for protobuf field targets.

import CEL
import Foundation
import SwiftProtobuf

/// How a protobuf field value of Swift type `V` converts to and from CEL values.
///
/// Generated message adapters (`protoc-gen-cel-swift`) pass one of the static members (`.int32`,
/// `.string`, `.enumeration`, `.message`, ...) for each field; there is no need to create kinds
/// by hand. `sint32`, `sfixed32` and `int32` fields all use ``int32``, and so on.
public struct ProtobufValueKind<V: Sendable>: Sendable {
  /// The CEL type of a value of this kind.
  let celType: CELType
  /// Converts a field value to a CEL value.
  let toValue: @Sendable (V, ProtobufTypes) -> Value
  /// Converts a CEL value to a field value; `nil` leaves the field unset (null assigned to a
  /// message field).
  let fromValue: @Sendable (Value, ProtobufTypes) -> Result<V?, EvalError>
  /// Whether the value is the proto3 zero value (an unset implicit-presence field).
  let isZero: @Sendable (V) -> Bool
  /// Protobuf equality (`pb.Equal` semantics: NaN is unequal, `Any` is compared unpacked).
  let equal: @Sendable (V, V, ProtobufTypes) -> Bool
  /// The CEL value of an unset singular field of this kind when it is not the default instance:
  /// `null` for wrappers, `Any` and `Value`.
  let unsetValue: Value?
  /// Map key conversions, for the kinds that can be map keys.
  let toMapKey: (@Sendable (V) -> MapKey)?
  let fromMapKey: (@Sendable (MapKey) -> V?)?
}

extension ProtobufValueKind {
  fileprivate static func scalar(
    _ celType: CELType,
    protoType: String,
    toValue: @escaping @Sendable (V) -> Value,
    fromValue: @escaping @Sendable (Value) -> Result<V, EvalError>?,
    isZero: @escaping @Sendable (V) -> Bool,
    equal: @escaping @Sendable (V, V) -> Bool,
    toMapKey: (@Sendable (V) -> MapKey)? = nil,
    fromMapKey: (@Sendable (MapKey) -> V?)? = nil
  ) -> Self {
    Self(
      celType: celType,
      toValue: { v, _ in toValue(v) },
      fromValue: { value, _ in
        if let converted = fromValue(value) {
          return converted.map { $0 }
        }
        return .failure(
          EvalError("unsupported type conversion from '\(value.runtimeTypeName)' to \(protoType)"))
      },
      isZero: isZero,
      equal: { a, b, _ in equal(a, b) },
      unsetValue: nil,
      toMapKey: toMapKey,
      fromMapKey: fromMapKey
    )
  }
}

extension ProtobufValueKind where V == Int32 {
  /// `int32`, `sint32` and `sfixed32` fields: CEL `int`, assignment checks the 32-bit range.
  public static var int32: Self {
    .scalar(
      .int, protoType: "int32",
      toValue: { .int(Int64($0)) },
      fromValue: { value in
        guard case .int(let i) = value else { return nil }
        guard let narrowed = Int32(exactly: i) else { return .failure(.intOverflow) }
        return .success(narrowed)
      },
      isZero: { $0 == 0 },
      equal: { $0 == $1 },
      toMapKey: { .int(Int64($0)) },
      fromMapKey: { key in
        guard case .int(let i) = key else { return nil }
        return Int32(exactly: i)
      }
    )
  }
}

extension ProtobufValueKind where V == Int64 {
  /// `int64`, `sint64` and `sfixed64` fields: CEL `int`.
  public static var int64: Self {
    .scalar(
      .int, protoType: "int64",
      toValue: { .int($0) },
      fromValue: { value in
        guard case .int(let i) = value else { return nil }
        return .success(i)
      },
      isZero: { $0 == 0 },
      equal: { $0 == $1 },
      toMapKey: { .int($0) },
      fromMapKey: { key in
        guard case .int(let i) = key else { return nil }
        return i
      }
    )
  }
}

extension ProtobufValueKind where V == UInt32 {
  /// `uint32` and `fixed32` fields: CEL `uint`, assignment checks the 32-bit range.
  public static var uint32: Self {
    .scalar(
      .uint, protoType: "uint32",
      toValue: { .uint(UInt64($0)) },
      fromValue: { value in
        guard case .uint(let u) = value else { return nil }
        guard let narrowed = UInt32(exactly: u) else { return .failure(.uintOverflow) }
        return .success(narrowed)
      },
      isZero: { $0 == 0 },
      equal: { $0 == $1 },
      toMapKey: { .uint(UInt64($0)) },
      fromMapKey: { key in
        guard case .uint(let u) = key else { return nil }
        return UInt32(exactly: u)
      }
    )
  }
}

extension ProtobufValueKind where V == UInt64 {
  /// `uint64` and `fixed64` fields: CEL `uint`.
  public static var uint64: Self {
    .scalar(
      .uint, protoType: "uint64",
      toValue: { .uint($0) },
      fromValue: { value in
        guard case .uint(let u) = value else { return nil }
        return .success(u)
      },
      isZero: { $0 == 0 },
      equal: { $0 == $1 },
      toMapKey: { .uint($0) },
      fromMapKey: { key in
        guard case .uint(let u) = key else { return nil }
        return u
      }
    )
  }
}

extension ProtobufValueKind where V == Float {
  /// `float` fields: CEL `double`, assignment rounds to single precision.
  public static var float: Self {
    .scalar(
      .double, protoType: "float32",
      toValue: { .double(Double($0)) },
      fromValue: { value in
        guard case .double(let d) = value else { return nil }
        return .success(Float(d))
      },
      // Go's protoreflect treats -0.0 as set: presence is "any bit set".
      isZero: { $0.bitPattern == 0 },
      equal: { $0 == $1 }
    )
  }
}

extension ProtobufValueKind where V == Double {
  /// `double` fields: CEL `double`.
  public static var double: Self {
    .scalar(
      .double, protoType: "float64",
      toValue: { .double($0) },
      fromValue: { value in
        guard case .double(let d) = value else { return nil }
        return .success(d)
      },
      isZero: { $0.bitPattern == 0 },
      equal: { $0 == $1 }
    )
  }
}

extension ProtobufValueKind where V == Bool {
  /// `bool` fields.
  public static var bool: Self {
    .scalar(
      .bool, protoType: "bool",
      toValue: { .bool($0) },
      fromValue: { value in
        guard case .bool(let b) = value else { return nil }
        return .success(b)
      },
      isZero: { !$0 },
      equal: { $0 == $1 },
      toMapKey: { .bool($0) },
      fromMapKey: { key in
        guard case .bool(let b) = key else { return nil }
        return b
      }
    )
  }
}

extension ProtobufValueKind where V == String {
  /// `string` fields. Strings compare by their UTF-8 bytes, as protobuf does.
  public static var string: Self {
    .scalar(
      .string, protoType: "string",
      toValue: { .string($0) },
      fromValue: { value in
        guard case .string(let s) = value else { return nil }
        return .success(s)
      },
      isZero: { $0.utf8.isEmpty },
      equal: { $0.utf8.elementsEqual($1.utf8) },
      toMapKey: { .string($0) },
      fromMapKey: { key in
        guard case .string(let s) = key else { return nil }
        return s
      }
    )
  }
}

extension ProtobufValueKind where V == Data {
  /// `bytes` fields.
  public static var bytes: Self {
    .scalar(
      .bytes, protoType: "[]uint8",
      toValue: { .bytes([UInt8]($0)) },
      fromValue: { value in
        guard case .bytes(let b) = value else { return nil }
        return .success(Data(b))
      },
      isZero: { $0.isEmpty },
      equal: { $0 == $1 }
    )
  }
}

extension ProtobufValueKind where V: SwiftProtobuf.Enum, V.RawValue == Int {
  /// Enum fields: CEL `int` (strong enum types are not supported, as in cel-go).
  ///
  /// Assignment checks the 32-bit range. Closed (proto2) enums cannot hold numbers they do not
  /// declare in Swift, so assigning one is an error.
  public static var enumeration: Self {
    Self(
      celType: .int,
      toValue: { v, _ in .int(Int64(v.rawValue)) },
      fromValue: { value, _ in
        guard case .int(let i) = value else {
          return .failure(
            EvalError("unsupported type conversion from '\(value.runtimeTypeName)' to int32"))
        }
        guard let narrowed = Int32(exactly: i) else { return .failure(.intOverflow) }
        guard let e = V(rawValue: Int(narrowed)) else {
          return .failure(EvalError("invalid enum value \(narrowed) for \(String(describing: V.self))"))
        }
        return .success(e)
      },
      isZero: { $0.rawValue == 0 },
      equal: { a, b, _ in a.rawValue == b.rawValue },
      unsetValue: nil,
      toMapKey: nil,
      fromMapKey: nil
    )
  }
}

extension ProtobufValueKind where V: SwiftProtobuf.Message {
  /// Message fields. Well-known types are unwrapped to their CEL equivalents: wrappers to
  /// nullable primitives, `Struct` / `Value` / `ListValue` to JSON maps, values and lists, `Any`
  /// to its unpacked content, `Duration` and `Timestamp` to CEL durations and timestamps.
  public static var message: Self {
    let name = V.protoMessageName
    return Self(
      celType: CELType.objectType(name),
      toValue: { v, types in types.value(of: v) },
      fromValue: { value, types in WellKnownTypes.convert(value, to: V.self, types: types) },
      isZero: { _ in false },
      equal: { a, b, types in types.messagesEqual(a, b) },
      unsetValue: WellKnownTypes.isNullWhenUnset(name) ? .null : nil,
      toMapKey: nil,
      fromMapKey: nil
    )
  }
}

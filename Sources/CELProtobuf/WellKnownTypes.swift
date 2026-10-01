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
// Ported from cel-go common/types/pb/type.go (unwrap, unwrapDynamic, zeroValueMap),
// common/types/json_value.go, common/types/map.go and list.go (jsonStruct / jsonList access and
// the JSON conversions of ConvertToNative), and the ConvertToNative methods of
// common/types/{int,uint,double,bool,string,bytes,null,duration,timestamp,list,map,object}.go
// for well-known type targets (wrappers, Any, Value, ListValue, Struct, Duration, Timestamp).

import CEL
import Foundation
import SwiftProtobuf

/// Conversions between the protobuf well-known types and CEL values.
enum WellKnownTypes {
  /// The generated descriptions of the well-known type files, always registered.
  static let files: [ProtobufFile] = [
    Google_Protobuf_Any_CELFile,
    Google_Protobuf_Duration_CELFile,
    Google_Protobuf_Empty_CELFile,
    Google_Protobuf_FieldMask_CELFile,
    Google_Protobuf_Struct_CELFile,
    Google_Protobuf_Timestamp_CELFile,
    Google_Protobuf_Wrappers_CELFile,
  ]

  /// Whether an unset singular field of the message type reads as `null` rather than as the
  /// default instance: wrappers, `Any` (cel-go's zero `Any` holds a `Value`) and `Value`.
  static func isNullWhenUnset(_ messageName: String) -> Bool {
    switch messageName {
    case "google.protobuf.Any", "google.protobuf.Value", "google.protobuf.BoolValue",
      "google.protobuf.BytesValue", "google.protobuf.DoubleValue", "google.protobuf.FloatValue",
      "google.protobuf.Int32Value", "google.protobuf.Int64Value", "google.protobuf.StringValue",
      "google.protobuf.UInt32Value", "google.protobuf.UInt64Value":
      return true
    default:
      return false
    }
  }

  // MARK: Message to CEL

  /// The CEL value of a well-known type message, or `nil` for other messages (including `Empty`
  /// and `FieldMask`, which are ordinary objects).
  static func value(of message: any SwiftProtobuf.Message, types: ProtobufTypes) -> Value? {
    switch message {
    case let m as Google_Protobuf_Any:
      switch types.unpack(m) {
      case .success(let unpacked): return types.value(of: unpacked)
      case .failure(let error): return .error(error)
      }
    case let m as Google_Protobuf_Duration:
      return .duration(duration(from: m))
    case let m as Google_Protobuf_Timestamp:
      guard let t = CELTimestamp(secondsSinceEpoch: m.seconds, carryingNanoseconds: Int64(m.nanos)) else {
        return .error(.timestampOverflow)
      }
      return .timestamp(t)
    case let m as Google_Protobuf_Value:
      return value(ofJSON: m)
    case let m as Google_Protobuf_Struct:
      return .map(JSONStructValue(fields: m.fields))
    case let m as Google_Protobuf_ListValue:
      return .list(JSONListValue(values: m.values))
    case let m as Google_Protobuf_BoolValue: return .bool(m.value)
    case let m as Google_Protobuf_BytesValue: return .bytes([UInt8](m.value))
    case let m as Google_Protobuf_DoubleValue: return .double(m.value)
    case let m as Google_Protobuf_FloatValue: return .double(Double(m.value))
    case let m as Google_Protobuf_Int32Value: return .int(Int64(m.value))
    case let m as Google_Protobuf_Int64Value: return .int(m.value)
    case let m as Google_Protobuf_StringValue: return .string(m.value)
    case let m as Google_Protobuf_UInt32Value: return .uint(UInt64(m.value))
    case let m as Google_Protobuf_UInt64Value: return .uint(m.value)
    default: return nil
    }
  }

  /// A `google.protobuf.Value` as a CEL value; an unset kind is `null`.
  static func value(ofJSON json: Google_Protobuf_Value) -> Value {
    switch json.kind {
    case nil, .nullValue: return .null
    case .numberValue(let d): return .double(d)
    case .stringValue(let s): return .string(s)
    case .boolValue(let b): return .bool(b)
    case .structValue(let s): return .map(JSONStructValue(fields: s.fields))
    case .listValue(let l): return .list(JSONListValue(values: l.values))
    }
  }

  /// Go `durationpb.AsDuration`: saturates at the 64-bit nanosecond range.
  static func duration(from d: Google_Protobuf_Duration) -> CELDuration {
    if let result = CELDuration(seconds: d.seconds, nanoseconds: Int64(d.nanos)) {
      return result
    }
    return CELDuration(nanoseconds: d.seconds < 0 ? Int64.min : Int64.max)
  }

  static func protoDuration(_ d: CELDuration) -> Google_Protobuf_Duration {
    Google_Protobuf_Duration(
      seconds: d.nanoseconds / 1_000_000_000, nanos: Int32(d.nanoseconds % 1_000_000_000))
  }

  static func protoTimestamp(_ t: CELTimestamp) -> Google_Protobuf_Timestamp {
    Google_Protobuf_Timestamp(seconds: t.secondsSinceEpoch, nanos: t.nanoseconds)
  }

  // MARK: CEL to message

  /// Converts a CEL value for assignment to a message-typed field of type `V`; `nil` leaves the
  /// field unset.
  static func convert<V: SwiftProtobuf.Message>(
    _ value: Value, to type: V.Type, types: ProtobufTypes
  ) -> Result<V?, EvalError> {
    switch convertErased(value, to: type, types: types) {
    case .success(nil):
      return .success(nil)
    case .success(let message?):
      guard let typed = message as? V else {
        return .failure(conversionError(value, type))
      }
      return .success(typed)
    case .failure(let error):
      return .failure(error)
    }
  }

  /// cel-go `Optional.ConvertToNative` of `optional.none()`.
  static let optionalNoneDereference = EvalError("optional.none() dereference")

  private static func conversionError(_ value: Value, _ type: any SwiftProtobuf.Message.Type)
    -> EvalError
  {
    EvalError(
      "type conversion error from '\(value.runtimeTypeName)' to '\(type.protoMessageName)'")
  }

  private static func convertErased(
    _ value: Value, to type: any SwiftProtobuf.Message.Type, types: ProtobufTypes
  ) -> Result<(any SwiftProtobuf.Message)?, EvalError> {
    if case .error(let error) = value {
      return .failure(error)
    }
    if case .optional(let wrapped) = value {
      // cel-go `Optional.ConvertToNative`: the wrapped value converts, none is an error.
      guard let wrapped else { return .failure(optionalNoneDereference) }
      return convertErased(wrapped, to: type, types: types)
    }
    func scalar(_ message: (any SwiftProtobuf.Message)?) -> Result<
      (any SwiftProtobuf.Message)?, EvalError
    > {
      if let message {
        return .success(message)
      }
      return .failure(conversionError(value, type))
    }
    switch type {
    case is Google_Protobuf_Any.Type:
      return packAny(value, types: types).map { $0 }
    case is Google_Protobuf_Value.Type:
      return jsonValue(value, types: types).map { $0 }
    case is Google_Protobuf_ListValue.Type:
      guard case .list(let list) = value else { return .failure(conversionError(value, type)) }
      return jsonList(list, types: types).map { $0 }
    case is Google_Protobuf_Struct.Type:
      guard case .map(let map) = value else { return .failure(conversionError(value, type)) }
      return jsonStruct(map, types: types).map { $0 }
    default:
      break
    }
    if case .null = value {
      return .success(nil)
    }
    switch type {
    case is Google_Protobuf_Duration.Type:
      guard case .duration(let d) = value else { return scalar(nil) }
      return scalar(protoDuration(d))
    case is Google_Protobuf_Timestamp.Type:
      guard case .timestamp(let t) = value else { return scalar(nil) }
      return scalar(protoTimestamp(t))
    case is Google_Protobuf_BoolValue.Type:
      guard case .bool(let b) = value else { return scalar(nil) }
      return scalar(Google_Protobuf_BoolValue(b))
    case is Google_Protobuf_BytesValue.Type:
      guard case .bytes(let b) = value else { return scalar(nil) }
      return scalar(Google_Protobuf_BytesValue(Data(b)))
    case is Google_Protobuf_DoubleValue.Type:
      guard case .double(let d) = value else { return scalar(nil) }
      return scalar(Google_Protobuf_DoubleValue(d))
    case is Google_Protobuf_FloatValue.Type:
      guard case .double(let d) = value else { return scalar(nil) }
      return scalar(Google_Protobuf_FloatValue(Float(d)))
    case is Google_Protobuf_Int32Value.Type:
      guard case .int(let i) = value else { return scalar(nil) }
      guard let narrowed = Int32(exactly: i) else { return .failure(.intOverflow) }
      return scalar(Google_Protobuf_Int32Value(narrowed))
    case is Google_Protobuf_Int64Value.Type:
      guard case .int(let i) = value else { return scalar(nil) }
      return scalar(Google_Protobuf_Int64Value(i))
    case is Google_Protobuf_StringValue.Type:
      guard case .string(let s) = value else { return scalar(nil) }
      return scalar(Google_Protobuf_StringValue(s))
    case is Google_Protobuf_UInt32Value.Type:
      guard case .uint(let u) = value else { return scalar(nil) }
      guard let narrowed = UInt32(exactly: u) else { return .failure(.uintOverflow) }
      return scalar(Google_Protobuf_UInt32Value(narrowed))
    case is Google_Protobuf_UInt64Value.Type:
      guard case .uint(let u) = value else { return scalar(nil) }
      return scalar(Google_Protobuf_UInt64Value(u))
    default:
      guard case .object(let object) = value, let proto = object as? ProtobufObject,
        Swift.type(of: proto.message) == type
      else { return .failure(conversionError(value, type)) }
      return .success(proto.message)
    }
  }

  /// Packs a CEL value into an `Any`: primitives as wrappers, lists and maps as JSON, messages
  /// as themselves. Port of the `anyValueType` cases of cel-go's `ConvertToNative`.
  static func packAny(_ value: Value, types: ProtobufTypes) -> Result<Google_Protobuf_Any, EvalError> {
    let message: any SwiftProtobuf.Message
    switch value {
    case .optional(let wrapped):
      guard let wrapped else { return .failure(optionalNoneDereference) }
      return packAny(wrapped, types: types)
    case .bool(let b): message = Google_Protobuf_BoolValue(b)
    case .int(let i): message = Google_Protobuf_Int64Value(i)
    case .uint(let u): message = Google_Protobuf_UInt64Value(u)
    case .double(let d): message = Google_Protobuf_DoubleValue(d)
    case .string(let s): message = Google_Protobuf_StringValue(s)
    case .bytes(let b): message = Google_Protobuf_BytesValue(Data(b))
    case .duration(let d): message = protoDuration(d)
    case .timestamp(let t): message = protoTimestamp(t)
    case .null, .list, .map:
      switch jsonValue(value, types: types) {
      case .success(let json):
        switch json.kind {
        case .listValue(let l)?: message = l
        case .structValue(let s)?: message = s
        default: message = json
        }
      case .failure(let error): return .failure(error)
      }
    case .object(let object):
      guard let proto = object as? ProtobufObject else {
        return .failure(conversionError(value, Google_Protobuf_Any.self))
      }
      if let any = proto.message as? Google_Protobuf_Any {
        return .success(any)
      }
      message = proto.message
    case .error(let error):
      return .failure(error)
    case .type, .unknown:
      return .failure(conversionError(value, Google_Protobuf_Any.self))
    }
    do {
      return .success(try Google_Protobuf_Any(message: message, partial: true))
    } catch {
      return .failure(EvalError("\(error)"))
    }
  }

  /// cel-go `maxIntJSON`: the largest integer a JSON number holds exactly.
  static let maxIntJSON: Int64 = (1 << 53) - 1

  /// Converts a CEL value to a JSON `google.protobuf.Value`, following the proto3 JSON mapping.
  static func jsonValue(_ value: Value, types: ProtobufTypes) -> Result<Google_Protobuf_Value, EvalError> {
    var json = Google_Protobuf_Value()
    switch value {
    case .null:
      json.nullValue = .nullValue
    case .bool(let b):
      json.boolValue = b
    case .int(let i):
      if i >= -maxIntJSON && i <= maxIntJSON {
        json.numberValue = Double(i)
      } else {
        json.stringValue = String(i)
      }
    case .uint(let u):
      if u <= UInt64(maxIntJSON) {
        json.numberValue = Double(u)
      } else {
        json.stringValue = String(u)
      }
    case .double(let d):
      json.numberValue = d
    case .string(let s):
      json.stringValue = s
    case .bytes(let b):
      json.stringValue = Data(b).base64EncodedString()
    case .duration(let d):
      json.stringValue = d.celString
    case .timestamp(let t):
      json.stringValue = t.celString
    case .list(let list):
      switch jsonList(list, types: types) {
      case .success(let l): json.listValue = l
      case .failure(let error): return .failure(error)
      }
    case .map(let map):
      switch jsonStruct(map, types: types) {
      case .success(let s): json.structValue = s
      case .failure(let error): return .failure(error)
      }
    case .object(let object):
      guard let proto = object as? ProtobufObject else {
        return .failure(conversionError(value, Google_Protobuf_Value.self))
      }
      do {
        let data = try proto.message.jsonUTF8Data()
        json = try Google_Protobuf_Value(jsonUTF8Data: data)
        proto.types.patchJSON(of: proto.message, &json)
      } catch {
        return .failure(EvalError("\(error)"))
      }
    case .optional(let wrapped):
      guard let wrapped else { return .failure(optionalNoneDereference) }
      return jsonValue(wrapped, types: types)
    case .error(let error):
      return .failure(error)
    case .type, .unknown:
      return .failure(conversionError(value, Google_Protobuf_Value.self))
    }
    return .success(json)
  }

  static func jsonList(_ list: any ListValue, types: ProtobufTypes) -> Result<
    Google_Protobuf_ListValue, EvalError
  > {
    var result = Google_Protobuf_ListValue()
    result.values.reserveCapacity(list.count)
    for i in 0..<list.count {
      switch jsonValue(list.element(at: i), types: types) {
      case .success(let json): result.values.append(json)
      case .failure(let error): return .failure(error)
      }
    }
    return .success(result)
  }

  static func jsonStruct(_ map: any MapValue, types: ProtobufTypes) -> Result<
    Google_Protobuf_Struct, EvalError
  > {
    var result = Google_Protobuf_Struct()
    for key in map.keys {
      guard case .string(let name) = key else {
        // The key's ConvertToNative message: cel-go `Bool` words it unlike `Int` and `Uint`.
        if case .bool = key {
          return .failure(EvalError("type conversion error from bool to 'string'"))
        }
        return .failure(
          EvalError("unsupported type conversion from '\(key.value.runtimeTypeName)' to string"))
      }
      switch jsonValue(map.value(forKey: key) ?? .null, types: types) {
      case .success(let json): result.fields[name] = json
      case .failure(let error): return .failure(error)
      }
    }
    return .success(result)
  }
}

// MARK: - JSON collections

/// A `google.protobuf.ListValue` as a CEL list.
struct JSONListValue: ListValue {
  let values: [Google_Protobuf_Value]

  var count: Int { values.count }

  func element(at index: Int) -> Value {
    WellKnownTypes.value(ofJSON: values[index])
  }
}

/// A `google.protobuf.Struct` as a CEL map with string keys, iterated in sorted key order.
struct JSONStructValue: MapValue {
  let fields: [String: Google_Protobuf_Value]

  var count: Int { fields.count }

  var keys: [MapKey] {
    fields.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { .string($0) }
  }

  func value(forKey key: MapKey) -> Value? {
    guard case .string(let name) = key, let json = fields[name] else { return nil }
    return WellKnownTypes.value(ofJSON: json)
  }
}

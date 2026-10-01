// Copyright 2019 Google LLC
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
// Hand-written (not generated). Ported from cel-go cel/io.go: ProtoAsValue, ValueAsProto and
// ExprValueAsProto, the conversions between CEL values and cel.expr.Value / cel.expr.ExprValue.

import CEL
import CELProtobuf
import Foundation
import SwiftProtobuf

extension CELSpecProtos {
  /// The CEL types of the conformance test messages (proto2 and proto3 `TestAllTypes`, the proto2
  /// extensions) plus the well-known types.
  package static let protobufTypes = ProtobufTypes(files: [
    Cel_Expr_Conformance_Proto2_TestAllTypes_CELFile,
    Cel_Expr_Conformance_Proto2_TestAllTypesExtensions_CELFile,
    Cel_Expr_Conformance_Proto3_TestAllTypes_CELFile,
  ])
}

/// Type value names with a CEL type of their own; anything else is a message type name.
private let typeNameToType: [String: CELType] = [
  "bool": .bool, "bytes": .bytes, "double": .double, "null_type": .null, "int": .int,
  "list": .listOfDyn, "map": .mapOfDyn, "string": .string, "type": .type(nil), "uint": .uint,
]

extension Cel_Expr_Value {
  /// Converts the value to a CEL value. Port of cel-go `ProtoAsValue`: `object_value` is unpacked
  /// with `types` (well-known types become their CEL equivalents), `type_value` names a type, and
  /// `enum_value` is an `int`, or an ``EnumValue`` when `types` has strong enums.
  ///
  /// - Throws: ``EvalError`` for an unset kind, an unpackable object, or an invalid map key.
  package func celValue(types: ProtobufTypes) throws -> Value {
    switch kind {
    case .nullValue?: return .null
    case .boolValue(let b)?: return .bool(b)
    case .int64Value(let i)?: return .int(i)
    case .uint64Value(let u)?: return .uint(u)
    case .doubleValue(let d)?: return .double(d)
    case .stringValue(let s)?: return .string(s)
    case .bytesValue(let b)?: return .bytes([UInt8](b))
    case .enumValue(let e)?:
      if types.usesStrongEnums {
        return .object(EnumValue(typeName: e.type, number: e.value))
      }
      return .int(Int64(e.value))
    case .objectValue(let any)?:
      let value = types.value(of: any)
      if case .error(let error) = value {
        throw error
      }
      return value
    case .mapValue(let m)?:
      var map = OrderedMap()
      for entry in m.entries {
        let key = try entry.key.celValue(types: types)
        guard let mapKey = MapKey(key) else {
          throw EvalError("unsupported map key type: \(key.runtimeTypeName)")
        }
        map[mapKey] = try entry.value.celValue(types: types)
      }
      return .map(map)
    case .listValue(let l)?:
      return .list(ArrayList(try l.values.map { try $0.celValue(types: types) }))
    case .typeValue(let name)?:
      return .type(typeNameToType[name] ?? .object(name))
    case nil:
      throw EvalError("unknown value")
    }
  }

  /// Converts a CEL value. Port of cel-go `ValueAsProto`: durations, timestamps and messages
  /// become `object_value`s packed in `Any`.
  ///
  /// - Throws: ``EvalError`` for errors, unknowns, optionals and other values without a proto
  ///   form.
  package init(celValue: Value, types: ProtobufTypes) throws {
    self.init()
    switch celValue {
    case .null: nullValue = .nullValue
    case .bool(let b): boolValue = b
    case .int(let i): int64Value = i
    case .uint(let u): uint64Value = u
    case .double(let d): doubleValue = d
    case .string(let s): stringValue = s
    case .bytes(let b): bytesValue = Data(b)
    case .type(let t): typeValue = t.runtimeTypeName
    case .list(let list):
      var result = Cel_Expr_ListValue()
      result.values.reserveCapacity(list.count)
      for i in 0..<list.count {
        result.values.append(try Cel_Expr_Value(celValue: list.element(at: i), types: types))
      }
      listValue = result
    case .map(let map):
      var result = Cel_Expr_MapValue()
      try map.forEachKey { key in
        var entry = Cel_Expr_MapValue.Entry()
        entry.key = try Cel_Expr_Value(celValue: key.value, types: types)
        entry.value = try Cel_Expr_Value(celValue: map.value(forKey: key) ?? .null, types: types)
        result.entries.append(entry)
        return true
      }
      mapValue = result
    case .error(let error):
      throw error
    case .object(let e as EnumValue):
      var value = Cel_Expr_EnumValue()
      value.type = e.typeName
      value.value = e.number
      enumValue = value
    default:
      objectValue = try types.message(from: celValue, as: Google_Protobuf_Any.self)
    }
  }
}

extension Cel_Expr_ExprValue {
  /// Converts an evaluation result. Port of cel-go `ExprValueAsProto`: errors become an error set
  /// with code 2 (UNKNOWN), unknowns an unknown set of expression ids.
  ///
  /// - Throws: ``EvalError`` if a value has no proto form.
  package init(celValue: Value, types: ProtobufTypes) throws {
    self.init()
    switch celValue {
    case .error(let error):
      var status = Cel_Expr_Status()
      status.code = 2
      status.message = error.message
      var set = Cel_Expr_ErrorSet()
      set.errors = [status]
      self.error = set
    case .unknown(let unknown):
      var set = Cel_Expr_UnknownSet()
      set.exprs = unknown.expressionIDs
      self.unknown = set
    default:
      value = try Cel_Expr_Value(celValue: celValue, types: types)
    }
  }
}

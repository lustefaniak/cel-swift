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
// Ported from cel-go interpreter/interpreter_test.go: the testData cases with protobuf messages (and
// `select_relative`, which needs a JSON decoder), run by InterpreterTests in every mode. Message inputs
// and expected messages are built with CEL message literals instead of Go structs. Not ported:
// `literal_pb3_msg` (google.api.expr.v1alpha1.Expr has no generated cel-swift types). The
// `select_custom_pb3_*` cases use cel-go's `custAttrFactory`, a test attribute factory with a
// hand-written qualifier for `NestedMessage.bb`; they run here with the default factory.

import Foundation
import Testing

@testable import CEL

/// Evaluates a message literal with cel-go's proto2 / proto3 test types.
private func message(_ expr: String, container: String = "google.expr.proto3.test") -> Value {
  do {
    let env = ProgramEnvironment(container: try Container(.name(container)), provider: testTypeRegistry())
    let value = try env.program(env.parse(expr)).eval(MapActivation([:])).value
    if case .error(let e) = value {
      fatalError("\(expr): \(e)")
    }
    return value
  } catch {
    fatalError("\(expr): \(error)")
  }
}

/// Go's `json.Unmarshal` into `map[string]any`, then `NativeToValue`: numbers are doubles.
private func jsonValue(_ json: Any) -> Value {
  switch json {
  case let s as String: return .string(s)
  case let n as NSNumber:
    if String(cString: n.objCType) == "c" {
      return .bool(n.boolValue)
    }
    return .double(n.doubleValue)
  case let a as [Any]: return .list(ArrayList(a.map(jsonValue)))
  case let d as [String: Any]:
    return .map(OrderedMap(d.sorted { $0.key < $1.key }.map { (MapKey.string($0.key), jsonValue($0.value)) }))
  default: return .null
  }
}

private let jsonFunction: FunctionDecl = {
  do {
    return try FunctionDecl(
      "json",
      .overload(
        "json_string", argTypes: [.string], resultType: .dyn,
        .unaryBinding { val in
          guard case .string(let s) = val else { return Value.maybeNoSuchOverload(val) }
          do {
            return jsonValue(try JSONSerialization.jsonObject(with: Data(s.utf8)))
          } catch {
            return .error(EvalError("invalid json: \(error)"))
          }
        }))
  } catch {
    fatalError("\(error)")
  }
}()

private let proto3 = "google.expr.proto3.test"
private let proto2 = "google.expr.proto2.test"
private let pb3Type = CELType.object("google.expr.proto3.test.TestAllTypes")
private let pb2Type = CELType.object("google.expr.proto2.test.TestAllTypes")

private let hasFieldInput = """
  TestAllTypes{repeated_bool: [false], map_int64_nested_type: {1: NestedTestAllTypes{}}, map_string_string: {}}
  """

private func unknown(_ id: Int64, _ variable: String) -> UnknownSet {
  UnknownSet(exprID: id, attribute: AttributeTrail(variable: variable))
}

let interpreterProtoCases: [InterpreterCase] = [
  .init(
    name: "literal_pb_enum",
    expr: """
      TestAllTypes{
      				repeated_nested_enum: [
      					0,
      					TestAllTypes.NestedEnum.BAZ,
      					TestAllTypes.NestedEnum.BAR],
      				repeated_int32: [
      					TestAllTypes.NestedEnum.FOO,
      					TestAllTypes.NestedEnum.BAZ]}
      """, container: proto3, protos: true,
    out: message("TestAllTypes{repeated_nested_enum: [0, 2, 1], repeated_int32: [0, 2]}")),
  .init(
    name: "literal_pb_wrapper_assign",
    expr: """
      TestAllTypes{
      				single_int64_wrapper: 10,
      				single_int32_wrapper: TestAllTypes{}.single_int32_wrapper,
      			}
      """, container: proto3, protos: true, out: message("TestAllTypes{single_int64_wrapper: 10}")),
  .init(
    name: "literal_pb_wrapper_assign_roundtrip",
    expr: """
      TestAllTypes{
      				single_int32_wrapper: TestAllTypes{}.single_int32_wrapper,
      			}.single_int32_wrapper == null
      """, container: proto3, protos: true),
  .init(
    name: "literal_pb_list_assign_null_wrapper",
    expr: """
      TestAllTypes{
      				repeated_int32: [123, 456, TestAllTypes{}.single_int32_wrapper],
      			}
      """, container: proto3, protos: true, err: "field type conversion error"),
  .init(
    name: "literal_pb_map_assign_null_entry_value",
    expr: """
      TestAllTypes{
      				map_string_string: {
      					'hello': 'world',
      					'goodbye': TestAllTypes{}.single_string_wrapper,
      				},
      			}
      """, container: proto3, protos: true, err: "field type conversion error"),
  .init(
    name: "unset_wrapper_access", expr: "TestAllTypes{}.single_string_wrapper", container: proto3, protos: true,
    out: .null),
  .init(
    name: "macro_has_pb2_field_undefined", expr: "has(TestAllTypes{}.invalid_field)", container: proto2,
    unchecked: true, protos: true, err: "no such field 'invalid_field'"),
  .init(
    name: "macro_has_pb2_field",
    expr: """
      has(TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.BAR}.standalone_enum)
      			&& has(TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.FOO}.standalone_enum)
      			&& !has(TestAllTypes{single_nested_enum: TestAllTypes.NestedEnum.FOO}.single_nested_message)
      			&& has(TestAllTypes{single_nested_enum: TestAllTypes.NestedEnum.FOO}.single_nested_enum)
      			&& !has(TestAllTypes{}.standalone_enum)
      			&& !has(pb2.single_int64)
      			&& has(pb2.repeated_bool)
      			&& !has(pb2.repeated_int32)
      			&& has(pb2.map_int64_nested_type)
      			&& !has(pb2.map_string_string)
      """, container: proto2, vars: [VariableDecl(name: "pb2", type: pb2Type)],
    input: ["pb2": message(hasFieldInput, container: proto2)], protos: true),
  .init(
    name: "macro_has_pb2_field_json",
    expr: """
      has(TestAllTypes{standaloneEnum: TestAllTypes.NestedEnum.BAR}.standaloneEnum)
      			&& has(TestAllTypes{standaloneEnum: TestAllTypes.NestedEnum.FOO}.standaloneEnum)
      			&& !has(TestAllTypes{singleNestedEnum: TestAllTypes.NestedEnum.FOO}.singleNestedMessage)
      			&& has(TestAllTypes{singleNestedEnum: TestAllTypes.NestedEnum.FOO}.singleNestedEnum)
      			&& !has(TestAllTypes{}.singleNestedMessage)
      			&& has(TestAllTypes{singleNestedMessage: TestAllTypes.NestedMessage{}}.singleNestedMessage)
      			&& !has(TestAllTypes{}.standaloneEnum)
      			&& !has(pb2.singleInt64)
      			&& has(pb2.repeatedBool)
      			&& !has(pb2.repeatedInt32)
      			&& has(pb2.mapInt64NestedType)
      			&& !has(pb2.mapStringString)
      """, container: proto2, vars: [VariableDecl(name: "pb2", type: pb2Type)],
    input: ["pb2": message(hasFieldInput, container: proto2)], protos: true, jsonFieldNames: true),
  .init(
    name: "macro_has_pb3_field",
    expr: """
      has(TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.BAR}.standalone_enum)
      			&& !has(TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.FOO}.standalone_enum)
      			&& !has(TestAllTypes{single_nested_enum: TestAllTypes.NestedEnum.FOO}.single_nested_message)
      			&& has(TestAllTypes{single_nested_enum: TestAllTypes.NestedEnum.FOO}.single_nested_enum)
      			&& !has(TestAllTypes{}.single_nested_message)
      			&& has(TestAllTypes{single_nested_message: TestAllTypes.NestedMessage{}}.single_nested_message)
      			&& !has(TestAllTypes{}.standalone_enum)
      			&& !has(pb3.single_int64)
      			&& has(pb3.repeated_bool)
      			&& !has(pb3.repeated_int32)
      			&& has(pb3.map_int64_nested_type)
      			&& !has(pb3.map_string_string)
      """, container: proto3, vars: [VariableDecl(name: "pb3", type: pb3Type)],
    input: ["pb3": message(hasFieldInput)], protos: true),
  .init(
    name: "macro_has_pb3_field_json",
    expr: """
      has(TestAllTypes{standaloneEnum: TestAllTypes.NestedEnum.BAR}.standaloneEnum)
      			&& !has(TestAllTypes{standaloneEnum: TestAllTypes.NestedEnum.FOO}.standaloneEnum)
      			&& !has(TestAllTypes{singleNestedEnum: TestAllTypes.NestedEnum.FOO}.singleNestedMessage)
      			&& has(TestAllTypes{singleNestedEnum: TestAllTypes.NestedEnum.FOO}.singleNestedEnum)
      			&& !has(TestAllTypes{}.singleNestedMessage)
      			&& has(TestAllTypes{singleNestedMessage: TestAllTypes.NestedMessage{}}.singleNestedMessage)
      			&& !has(TestAllTypes{}.standaloneEnum)
      			&& !has(pb3.singleInt64)
      			&& has(pb3.repeatedBool)
      			&& !has(pb3.repeatedInt32)
      			&& has(pb3.mapInt64NestedType)
      			&& !has(pb3.mapStringString)
      """, container: proto3, vars: [VariableDecl(name: "pb3", type: pb3Type)],
    input: ["pb3": message(hasFieldInput)], protos: true, jsonFieldNames: true),
  .init(
    name: "nested_proto_field", expr: "pb3.single_nested_message.bb", vars: [VariableDecl(name: "pb3", type: pb3Type)],
    input: ["pb3": message("TestAllTypes{single_nested_message: TestAllTypes.NestedMessage{bb: 1234}}")],
    protos: true, out: 1234),
  .init(
    name: "nested_proto_field_with_index", expr: "pb3.map_int64_nested_type[0].child.payload.single_int32 == 1",
    vars: [VariableDecl(name: "pb3", type: pb3Type)],
    input: [
      "pb3": message(
        "TestAllTypes{map_int64_nested_type: {0: NestedTestAllTypes{child: NestedTestAllTypes{payload: TestAllTypes{single_int32: 1}}}}}"
      )
    ], protos: true),
  .init(
    name: "select_field",
    expr: """
      a.b.c
      				&& pb3.repeated_nested_enum[0] == test.TestAllTypes.NestedEnum.BAR
      				&& json.list[0] == 'world'
      """, container: "google.expr.proto3",
    vars: [
      VariableDecl(name: "a.b", type: .map(key: .string, value: .bool)), VariableDecl(name: "pb3", type: pb3Type),
      VariableDecl(name: "json", type: .map(key: .string, value: .dyn)),
    ],
    input: [
      "a.b": ["c": true],
      "pb3": message("TestAllTypes{repeated_nested_enum: [TestAllTypes.NestedEnum.BAR]}"),
      "json": message(
        "google.protobuf.Value{struct_value: google.protobuf.Struct{fields: {'list': ['world']}}}", container: ""),
    ], protos: true),
  .init(
    name: "select_pb2_primitive_fields",
    expr: """
      !has(a.single_int32)
      			&& a.single_int32 == -32
      			&& a.single_int64 == -64
      			&& a.single_uint32 == 32u
      			&& a.single_uint64 == 64u
      			&& a.single_float == 3.0
      			&& a.single_double == 6.4
      			&& a.single_bool
      			&& "empty" == a.single_string
      """, vars: [VariableDecl(name: "a", type: pb2Type)],
    input: ["a": message("TestAllTypes{}", container: proto2)], protos: true),
  .init(
    name: "select_pb3_wrapper_fields",
    expr: """
      !has(a.single_int32_wrapper) && a.single_int32_wrapper == null
      				&& has(a.single_int64_wrapper) && a.single_int64_wrapper == 0
      				&& has(a.single_string_wrapper) && a.single_string_wrapper == "hello"
      				&& a.single_int64_wrapper == Int32Value{value: 0}
      """, abbrevs: ["google.protobuf.Int32Value"], vars: [VariableDecl(name: "a", type: pb3Type)],
    input: ["a": message("TestAllTypes{single_int64_wrapper: 0, single_string_wrapper: 'hello'}")], protos: true),
  .init(
    name: "select_pb3_compare", expr: "a.single_uint64 > 3u", container: proto3,
    vars: [VariableDecl(name: "a", type: pb3Type)], input: ["a": message("TestAllTypes{single_uint64: 10u}")],
    protos: true),
  .init(
    name: "select_custom_pb3_compare", expr: "a.bb > 100", container: proto3,
    vars: [VariableDecl(name: "a", type: .object("google.expr.proto3.test.TestAllTypes.NestedMessage"))],
    input: ["a": message("TestAllTypes.NestedMessage{bb: 101}")], protos: true),
  .init(
    name: "select_custom_pb3_optional_field", expr: "a.?bb", container: proto3,
    vars: [VariableDecl(name: "a", type: .object("google.expr.proto3.test.TestAllTypes.NestedMessage"))],
    input: ["a": message("TestAllTypes.NestedMessage{bb: 101}")], protos: true, out: .optional(101)),
  .init(name: "select_relative", expr: #"json('{"hi":"world"}').hi == 'world'"#, funcs: [jsonFunction]),
  .init(
    name: "select_empty_repeated_nested", expr: "TestAllTypes{}.repeated_nested_message.size() == 0",
    container: proto3, protos: true),
  .init(
    name: "literal_pb_optional_field",
    expr: "TestAllTypes{?single_int32: {'value': 1}.?value, ?single_string: {}.?missing}", container: proto3,
    protos: true, out: message("TestAllTypes{single_int32: 1}")),
  .init(
    name: "literal_pb_optional_field_bad_init", expr: "TestAllTypes{?single_int32: 1}", container: proto3,
    unchecked: true, protos: true, err: "cannot initialize optional entry 'single_int32' from non-optional"),
  .init(
    name: "unknown_optional_pb", expr: "TestAllTypes{?single_int32: a}", container: proto3,
    vars: [VariableDecl(name: "a", type: .optional(.int))], unknowns: [AttributePattern("a")], protos: true,
    out: .unknown(unknown(3, "a"))),
  .init(
    name: "unknown_optional_nested_aggregate",
    expr: "TestAllTypes{?single_int32: a, repeated_int32: [?b], map_string_string: {?'key': c}}", container: proto3,
    vars: [
      VariableDecl(name: "a", type: .optional(.int)), VariableDecl(name: "b", type: .optional(.int)),
      VariableDecl(name: "c", type: .optional(.string)),
    ], unknowns: [AttributePattern("a"), AttributePattern("b"), AttributePattern("c")], protos: true,
    out: .unknown(unknown(3, "a").merging(unknown(6, "b").merging(unknown(11, "c"))))),
  .init(
    name: "unknown_optional_pb_multiple", expr: "TestAllTypes{?single_int32: a, ?single_int64: b}", container: proto3,
    vars: [VariableDecl(name: "a", type: .optional(.int)), VariableDecl(name: "b", type: .optional(.int))],
    unknowns: [AttributePattern("a"), AttributePattern("b")], protos: true,
    out: .unknown(unknown(3, "a").merging(unknown(5, "b")))),
  .init(
    name: "unknown_optional_pb_invalid_type_precedence", expr: "TestAllTypes{?single_int32: a, ?single_int64: 1}",
    container: proto3, vars: [VariableDecl(name: "a", type: .optional(.int))], unchecked: true,
    unknowns: [AttributePattern("a")], protos: true,
    err: "cannot initialize optional entry 'single_int64' from non-optional value 1"),
]

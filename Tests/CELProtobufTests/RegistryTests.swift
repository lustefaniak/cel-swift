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
// Ported from cel-go common/types/provider_test.go (the protobuf cases) and object_test.go.

import CEL
import CELGoTestProtos
import CELProtobuf
import Foundation
import SwiftProtobuf
import Testing

struct RegistryTests {
  let types = testTypes()
  let testAllTypes = "google.expr.proto3.test.TestAllTypes"

  @Test func enumValue() {
    #expect(types.enumValue("google.expr.proto3.test.GlobalEnum.GOO") == .int(0))
    #expect(types.findIdent("google.expr.proto3.test.GlobalEnum.GAZ") == .int(2))
    #expect(types.enumValue("google.expr.proto3.test.GlobalEnum.NOPE").errorMessage
      == "unknown enum name 'google.expr.proto3.test.GlobalEnum.NOPE'")
  }

  @Test func findIdent() {
    #expect(types.findIdent(testAllTypes) == .type(.object(testAllTypes)))
    // Well-known types with a CEL equivalent are not identifiers of the protobuf types.
    #expect(types.findIdent("google.protobuf.Int32Value") == nil)
    #expect(types.findIdent("google.protobuf.Empty") == .type(.object("google.protobuf.Empty")))
    #expect(types.findIdent("google.expr.proto3.test.Undefined") == nil)
  }

  @Test func findStructType() {
    #expect(types.findStructType("." + testAllTypes) == .type(.object(testAllTypes)))
    #expect(types.findStructType(testAllTypes + "Undefined") == nil)
    #expect(types.findStructType("google.protobuf.Int32Value") == .type(.wrapper(.int)))
    #expect(types.findStructType("google.protobuf.Struct") == .type(.map(key: .string, value: .dyn)))
  }

  @Test(arguments: [
    ("single_bool", true), ("single_nested_message", true), ("standalone_enum", true),
    ("single_duration", true), ("single_timestamp", true), ("single_any", true),
    ("single_int64_wrapper", true), ("repeated_bool", true), ("map_string_string", true),
    ("double_bool", false),
  ])
  func findStructFieldType(_ field: String, _ found: Bool) {
    #expect((types.findStructFieldType("." + testAllTypes, fieldName: field) != nil) == found)
    #expect(types.findStructFieldType(testAllTypes + "Undefined", fieldName: field) == nil)
  }

  @Test func findStructFieldTypeJSONNames() throws {
    let json = testTypes(jsonFieldNames: true)
    #expect(json.findStructFieldType(testAllTypes, fieldName: "mapStringString") != nil)
    #expect(json.findStructFieldType(testAllTypes, fieldName: "map_string_string") != nil)
    #expect(types.findStructFieldType(testAllTypes, fieldName: "mapStringString") == nil)
    let names = try #require(json.findStructFieldNames("google.expr.proto3.test.TestJsonNames"))
    #expect(
      Set(names) == [
        "int32_snake_case_json_name", "int64CamelCaseJsonName", "uint32DefaultJsonName",
        "uint64-custom-json-name", "single_string", "singleString",
      ])
  }

  @Test func jsonNameShadowing() throws {
    // `string_json_name_shadows` has json_name "single_string"; with JSON names the JSON name wins.
    let json = testTypes(jsonFieldNames: true)
    let message = Google_Expr_Proto3_Test_TestJsonNames.with {
      $0.stringJsonNameShadows = "shadow"
      $0.singleString = "real"
    }
    let object = try #require(json.value(of: message).protobufObject)
    #expect(object.field("single_string") == "shadow")
    #expect(object.field("singleString") == "real")
  }

  @Test func fieldTypeAccessors() throws {
    let field = try #require(types.findStructFieldType(testAllTypes, fieldName: "single_int32"))
    let object = try #require(types.value(of: Proto3.with { $0.singleInt32 = 7 }).protobufObject)
    #expect(field.isSet(object))
    #expect(field.getFrom(object) == .int(7))
  }

  struct NewValueCase: Sendable, CustomTestStringConvertible {
    var name: String
    var fields: [String: Value]
    var expected: Proto3
    var testDescription: String { name }
  }

  static let newValueCases: [NewValueCase] = [
    NewValueCase(name: "empty", fields: [:], expected: Proto3()),
    NewValueCase(name: "enum", fields: ["standalone_enum": 1], expected: .with { $0.standaloneEnum = .bar }),
    NewValueCase(
      name: "wrappers", fields: ["single_int32_wrapper": 123, "single_int64_wrapper": .null],
      expected: .with { $0.singleInt32Wrapper = Google_Protobuf_Int32Value(123) }),
    NewValueCase(name: "repeated", fields: ["repeated_int64": [3, 2, 1]], expected: .with { $0.repeatedInt64 = [3, 2, 1] }),
    NewValueCase(name: "oneof enum", fields: ["single_nested_enum": 2], expected: .with { $0.singleNestedEnum = .baz }),
    NewValueCase(name: "json bool", fields: ["single_value": true], expected: .with { $0.singleValue = jsonValue(.boolValue(true)) }),
    NewValueCase(
      name: "json list", fields: ["single_value": ["hello", 10.2]],
      expected: .with {
        $0.singleValue = jsonValue(
          .listValue(Google_Protobuf_ListValue(values: [jsonValue(.stringValue("hello")), jsonValue(.numberValue(10.2))])))
      }),
    NewValueCase(
      name: "json big int", fields: ["single_value": .int(1 << 60)],
      expected: .with { $0.singleValue = jsonValue(.stringValue("1152921504606846976")) }),
    NewValueCase(
      name: "json bytes", fields: ["single_value": .bytes(Array("hi".utf8))],
      expected: .with { $0.singleValue = jsonValue(.stringValue("aGk=")) }),
    NewValueCase(
      name: "json duration", fields: ["single_value": .duration(CELDuration(nanoseconds: 1_500_000_000))],
      expected: .with { $0.singleValue = jsonValue(.stringValue("1.5s")) }),
    NewValueCase(
      name: "struct", fields: ["single_struct": ["a": 1]],
      expected: .with { $0.singleStruct = Google_Protobuf_Struct(fields: ["a": jsonValue(.numberValue(1))]) }),
    NewValueCase(
      name: "any int", fields: ["single_any": 5],
      expected: .with { $0.singleAny = try! packAny(Google_Protobuf_Int64Value(5)) }),
    NewValueCase(
      name: "duration", fields: ["single_duration": .duration(CELDuration(nanoseconds: -1_500_000_000))],
      expected: .with { $0.singleDuration = Google_Protobuf_Duration(seconds: -1, nanos: -500_000_000) }),
    NewValueCase(name: "null message", fields: ["single_nested_message": .null], expected: Proto3()),
    NewValueCase(name: "float", fields: ["single_float": 1.25], expected: .with { $0.singleFloat = 1.25 }),
  ]

  @Test(arguments: newValueCases)
  func newValue(_ test: NewValueCase) throws {
    let value = types.newValue(testAllTypes, fields: test.fields)
    let object = try #require(value.protobufObject, "\(value)")
    let expected = try #require(types.value(of: test.expected).protobufObject)
    #expect(object.isEqual(to: expected), "got \(object), want \(expected)")
  }

  @Test func newValueNestedMessages() throws {
    let nested = types.value(of: Proto3.NestedMessage.with { $0.bb = 123 })
    let payload = types.value(of: Proto3Nested.with { $0.payload = .with { $0.singleInt32 = 1234 } })
    let value = types.newValue(
      testAllTypes,
      fields: [
        "repeated_nested_message": .list(ArrayList([nested])),
        "map_int64_nested_type": .map(OrderedMap([(.int(1234), payload)])),
      ])
    let object = try #require(value.protobufObject)
    let message = try #require(object.message as? Proto3)
    #expect(message.repeatedNestedMessage == [.with { $0.bb = 123 }])
    #expect(message.mapInt64NestedType[1234]?.payload.singleInt32 == 1234)
  }

  @Test(arguments: [
    ("google.expr.proto3.test.TestAllType", ["single_int32": Value.int(1)], "unknown type"),
    ("google.expr.proto3.test.TestAllTypes", ["undefined": 1], "no such field"),
    ("google.expr.proto3.test.TestAllTypes", ["single_int32_wrapper": true], "type conversion error"),
    ("google.expr.proto3.test.TestAllTypes", ["repeated_int64": [1.0, 2.3]], "type conversion error"),
    ("google.expr.proto3.test.TestAllTypes", ["repeated_int64": 10], "unsupported field type"),
    ("google.expr.proto3.test.TestAllTypes", ["map_string_string": .null], "unsupported field type"),
    ("google.expr.proto3.test.TestAllTypes", ["map_string_string": ["hello": 1]], "type conversion error"),
    ("google.expr.proto3.test.TestAllTypes", ["map_string_string": [1: 1]], "type conversion error"),
    ("google.expr.proto3.test.TestAllTypes", ["single_int32": .int(1 << 40)], "integer overflow"),
    ("google.expr.proto3.test.TestAllTypes", ["single_uint32": .uint(1 << 40)], "unsigned integer overflow"),
    ("google.expr.proto3.test.TestAllTypes", ["single_int32_wrapper": .int(-(1 << 40))], "integer overflow"),
    ("google.expr.proto3.test.TestAllTypes", ["standalone_enum": .int(1 << 33)], "integer overflow"),
    ("google.expr.proto3.test.TestAllTypes", ["single_int64": .uint(1)], "type conversion"),
    ("google.expr.proto3.test.TestAllTypes", ["single_int64": .null], "type conversion"),
    ("google.expr.proto3.test.TestAllTypes", ["single_struct": ["a": .type(.int)]], "type conversion error"),
    ("google.expr.proto3.test.TestAllTypes", ["single_nested_message": 1], "type conversion error"),
  ] as [(String, [String: Value], String)])
  func newValueErrors(_ typeName: String, _ fields: [String: Value], _ error: String) throws {
    let message = try #require(types.newValue(typeName, fields: fields).errorMessage)
    #expect(message.contains(error), "\(message)")
  }

  @Test func wellKnownConstruction() {
    #expect(types.newValue("google.protobuf.Int32Value", fields: ["value": 5]) == .int(5))
    #expect(types.newValue("google.protobuf.Int32Value", fields: [:]) == .int(0))
    #expect(types.newValue("google.protobuf.Value", fields: [:]) == .null)
    #expect(types.newValue("google.protobuf.Value", fields: ["string_value": "x"]) == .string("x"))
    #expect(types.newValue("google.protobuf.Struct", fields: ["fields": ["a": true]]) == ["a": true])
    #expect(types.newValue("google.protobuf.ListValue", fields: ["values": [1, "a"]]) == [.double(1), "a"])
    #expect(
      types.newValue("google.protobuf.Duration", fields: ["seconds": 10, "nanos": 1])
        == .duration(CELDuration(nanoseconds: 10_000_000_001)))
    #expect(
      types.newValue("google.protobuf.Timestamp", fields: ["seconds": 10])
        == .timestamp(CELTimestamp(secondsSinceEpoch: 10)))
    #expect(types.newValue("google.protobuf.Int32Value", fields: ["value": .int(1 << 40)]).isError)
    let empty = types.newValue("google.protobuf.Empty", fields: [:]).protobufObject
    #expect(empty?.celType == .object("google.protobuf.Empty"))
    #expect(empty?.isZeroValue == true)
    let mask = types.newValue("google.protobuf.FieldMask", fields: ["paths": ["a", "b"]])
    #expect(mask.protobufObject?.field("paths") == ["a", "b"])
    // An Any constructed in CEL unpacks to its content.
    let packed = try! Google_Protobuf_Int64Value(7).serializedBytes() as [UInt8]
    #expect(
      types.newValue(
        "google.protobuf.Any",
        fields: ["type_url": "type.googleapis.com/google.protobuf.Int64Value", "value": .bytes(packed)])
        == .int(7))
  }

  @Test func jsonValueOfMessages() throws {
    let empty = try #require(types.newValue("google.protobuf.Empty", fields: [:]).protobufObject)
    let mask = types.newValue("google.protobuf.FieldMask", fields: ["paths": ["foo", "bar"]])
    let value = types.newValue(testAllTypes, fields: ["single_value": mask])
    #expect(value.protobufObject?.field("single_value") == "foo,bar")
    let emptyValue = types.newValue(testAllTypes, fields: ["single_value": .object(empty)])
    #expect(emptyValue.protobufObject?.field("single_value") == .map(OrderedMap()))
  }

  @Test func unsetWellKnownFields() throws {
    let object = try #require(types.value(of: Proto3()).protobufObject)
    #expect(object.field("single_any") == .null)
    #expect(object.field("single_value") == .null)
    #expect(object.field("single_int32_wrapper") == .null)
    #expect(object.field("single_struct") == .map(OrderedMap()))
    #expect(object.field("single_duration") == .duration(CELDuration(nanoseconds: 0)))
    #expect(object.field("single_timestamp") == .timestamp(CELTimestamp(secondsSinceEpoch: 0)))
    let nested = try #require(object.field("single_nested_message").protobufObject)
    #expect(nested.isZeroValue)
    #expect(object.field("repeated_int32") == .list(ArrayList()))
  }

  @Test func repeatedAndMapAccess() throws {
    let object = try #require(
      types.value(of: Proto3.with {
        $0.repeatedFloat = [1.5]
        $0.repeatedNestedEnum = [.baz]
        $0.mapStringString = ["b": "2", "a": "1"]
        $0.mapInt64NestedType = [5: .with { $0.payload = .with { $0.singleBool = true } }]
      }).protobufObject)
    #expect(object.field("repeated_float") == [1.5])
    #expect(object.field("repeated_nested_enum") == [2])
    guard case .map(let map) = object.field("map_string_string") else {
      Issue.record("not a map")
      return
    }
    #expect(map.keys == ["a", "b"])
    #expect(map.value(forKey: "a") == "1")
    #expect(map.value(forKey: "z") == nil)
    guard case .map(let nested) = object.field("map_int64_nested_type") else {
      Issue.record("not a map")
      return
    }
    #expect(nested.value(forKey: .uint(5)) == nil)
    let entry = try #require(nested.value(forKey: .int(5))?.protobufObject)
    #expect(entry.field("payload").protobufObject?.field("single_bool") == true)
  }

  @Test func extensionFields() throws {
    let name = "google.expr.proto2.test.ExampleType"
    let value = types.newValue(
      name, fields: ["name": "n", "google.expr.proto2.test.int32_ext": 5, "google.expr.proto2.test.int32_wrapper_ext": 6])
    let object = try #require(value.protobufObject, "\(value)")
    #expect(object.field("google.expr.proto2.test.int32_ext") == .int(5))
    #expect(object.field("google.expr.proto2.test.int32_wrapper_ext") == .int(6))
    #expect(object.isFieldSet("google.expr.proto2.test.ExternalMessageType.int64_ext") == false)
    #expect(object.field("google.expr.proto2.test.ExternalMessageType.int64_ext") == .int(0))
    #expect(object.description == "google.expr.proto2.test.ExampleType{name: \"n\", `google.expr.proto2.test.int32_ext`: 5, `google.expr.proto2.test.int32_wrapper_ext`: 6}")
    // Extension values take part in equality.
    let other = try #require(
      types.newValue(name, fields: ["name": "n", "google.expr.proto2.test.int32_ext": 5]).protobufObject)
    #expect(!object.isEqual(to: other))
  }

  @Test func extensionsSurviveAnyRoundTrip() throws {
    let message = Google_Expr_Proto2_Test_ExampleType.with {
      $0.Google_Expr_Proto2_Test_int32Ext = 42
    }
    let value = types.value(of: try serializedAny(message))
    #expect(value.protobufObject?.field("google.expr.proto2.test.int32_ext") == .int(42))
  }

  @Test func objectBasics() throws {
    let object = try #require(types.value(of: Proto3.with { $0.singleInt32 = 1; $0.singleString = "x" }).protobufObject)
    #expect(object.celType == .object(testAllTypes))
    #expect(!object.isZeroValue)
    #expect(object.description == "google.expr.proto3.test.TestAllTypes{single_int32: 1, single_string: \"x\"}")
    #expect(Value.object(object).runtimeTypeName == testAllTypes)
  }

  @Test func nativeToValue() {
    #expect(types.nativeToValue(Google_Protobuf_BoolValue(true)) == .bool(true))
    #expect(types.nativeToValue(jsonValue(.nullValue(.nullValue))) == .null)
    #expect(types.nativeToValue(42).isError)
    #expect(ProtobufTypes().value(of: Proto3()).errorMessage == "unknown type: 'google.expr.proto3.test.TestAllTypes'")
    #expect(
      types.value(of: try! serializedAny(Proto3(), typeURL: "type.googleapis.com/Bad")).errorMessage?
        .contains("anypb.UnmarshalNew() failed") == true)
  }

  @Test func composedRegistry() {
    let registry = TypeRegistry(composing: types, adapter: types)
    #expect(registry.findIdent(testAllTypes) == .type(.object(testAllTypes)))
    #expect(registry.findIdent("int") == .type(.int))
    #expect(registry.enumValue("google.expr.proto3.test.GlobalEnum.GAR") == .int(1))
    #expect(registry.nativeToValue(Google_Protobuf_Int32Value(3)) == .int(3))
    #expect(registry.newValue(testAllTypes, fields: ["single_int32": 3]).protobufObject != nil)
  }

  @Test func registerIsValueSemantics() {
    var copy = ProtobufTypes()
    let original = copy
    copy.register(Google_Expr_Proto3_Test_TestAllTypes_CELFile)
    #expect(copy.messageType(named: testAllTypes) != nil)
    #expect(original.messageType(named: testAllTypes) == nil)
  }

  @Test func messageConversion() throws {
    let any = try types.message(from: .string("x"), as: Google_Protobuf_Any.self)
    #expect(types.value(of: any) == "x")
    let wrapper = try types.message(from: 5, as: Google_Protobuf_Int64Value.self)
    #expect(wrapper.value == 5)
    #expect(throws: EvalError.self) { try types.message(from: .null, as: Google_Protobuf_Int64Value.self) }
    let nullJSON = try types.message(from: .null, as: Google_Protobuf_Value.self)
    #expect(nullJSON.kind == .nullValue(.nullValue))
  }
}

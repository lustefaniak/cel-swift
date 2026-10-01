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
// Ported from cel-go common/types/pb/type_test.go, file_test.go and pb_test.go.

import CEL
import CELGoTestProtos
import CELProtobuf
import Foundation
import SwiftProtobuf
import Testing

struct TypeDescriptionTests {
  @Test(arguments: [
    ".google.protobuf.Any", ".google.protobuf.BoolValue", ".google.protobuf.BytesValue",
    ".google.protobuf.DoubleValue", ".google.protobuf.FloatValue", ".google.protobuf.Int32Value",
    ".google.protobuf.Int64Value", ".google.protobuf.ListValue", ".google.protobuf.Struct",
    ".google.protobuf.Value", "google.protobuf.Empty", "google.protobuf.FieldMask",
    "google.protobuf.Duration", "google.protobuf.Timestamp",
  ])
  func wellKnownTypesAreAlwaysRegistered(_ name: String) {
    #expect(ProtobufTypes().messageType(named: name) != nil)
  }

  @Test func jsonFieldNames() throws {
    let types = testTypes(jsonFieldNames: true)
    let field = try #require(
      types.findStructFieldType("google.expr.proto2.test.TestAllTypes", fieldName: "singleBoolWrapper"))
    #expect(field.isJSONField)
    #expect(field.type == .wrapper(.bool))
    #expect(types.enumValue("google.expr.proto2.test.TestAllTypes.NestedEnum.BAR") == .int(1))
    // Proto names still resolve.
    let protoName = try #require(
      types.findStructFieldType("google.expr.proto2.test.TestAllTypes", fieldName: "single_bool_wrapper"))
    #expect(!protoName.isJSONField)
  }

  @Test func groupFields() throws {
    let types = testTypes()
    let field = try #require(
      types.findStructFieldType("google.expr.proto2.test.TestAllTypes", fieldName: "nestedgroup"))
    #expect(field.type == .object("google.expr.proto2.test.TestAllTypes.NestedGroup"))
    let names = try #require(
      types.findStructFieldNames("google.expr.proto2.test.TestAllTypes.NestedGroup"))
    #expect(Set(names) == ["nested_id", "nested_name"])
  }

  @Test func fieldMap() throws {
    let names = try #require(testTypes().findStructFieldNames("google.expr.proto3.test.NestedTestAllTypes"))
    #expect(names.count == 2)
  }

  @Test func fileEnumNames() {
    let types = testTypes()
    for (name, number) in [
      ("google.expr.proto3.test.GlobalEnum.GOO", 0), ("google.expr.proto3.test.GlobalEnum.GAR", 1),
      ("google.expr.proto3.test.GlobalEnum.GAZ", 2), ("google.expr.proto3.test.TestAllTypes.NestedEnum.FOO", 0),
      ("google.expr.proto3.test.TestAllTypes.NestedEnum.BAR", 1),
      ("google.expr.proto3.test.TestAllTypes.NestedEnum.BAZ", 2),
      // Registered through the import of test_import.proto.
      ("google.expr.proto3.test.ImportedGlobalEnum.IMPORT_FOO", 0),
      ("google.expr.proto3.test.ImportedGlobalEnum.IMPORT_BAZ", 2),
      ("google.protobuf.NullValue.NULL_VALUE", 0),
    ] {
      #expect(types.enumValue(name) == .int(Int64(number)), "\(name)")
    }
    #expect(types.filePaths.contains("test/proto3pb/test_import.proto"))
  }

  @Test func extensions() throws {
    let types = testTypes()
    let message = "google.expr.proto2.test.ExampleType"
    for name in [
      "google.expr.proto2.test.int32_ext", "google.expr.proto2.test.nested_example",
      "google.expr.proto2.test.ExtendedExampleType.extended_examples",
      "google.expr.proto2.test.ExternalMessageType.int64_ext",
      "google.expr.proto2.test.ExtendedExampleType.enum_ext", "google.expr.proto2.test.int32_wrapper_ext",
    ] {
      #expect(types.findStructFieldType(message, fieldName: name) != nil, "\(name)")
    }
    // Extensions are not regular field names.
    #expect(types.findStructFieldNames(message)?.contains("google.expr.proto2.test.int32_ext") == false)
  }

  @Test func fieldGetFrom() throws {
    let types = testTypes()
    var message = Proto3()
    message.singleUint64 = 12
    message.singleDuration = Google_Protobuf_Duration(seconds: 0, nanos: 1234)
    message.singleTimestamp = Google_Protobuf_Timestamp(seconds: 12345, nanos: 0)
    message.singleBoolWrapper = Google_Protobuf_BoolValue(false)
    message.singleInt32Wrapper = Google_Protobuf_Int32Value(42)
    message.standaloneEnum = .bar
    message.singleNestedMessage = .with { $0.bb = 123 }
    message.singleValue = jsonValue(.stringValue("hello world"))
    message.singleStruct = Google_Protobuf_Struct(fields: ["null": jsonValue(.nullValue(.nullValue))])
    let object = try #require(types.value(of: message).protobufObject)
    #expect(object.field("single_uint64") == .uint(12))
    #expect(object.field("single_duration") == .duration(CELDuration(nanoseconds: 1234)))
    #expect(object.field("single_timestamp") == .timestamp(CELTimestamp(secondsSinceEpoch: 12345)))
    #expect(object.field("single_bool_wrapper") == .bool(false))
    #expect(object.field("single_int32_wrapper") == .int(42))
    #expect(object.field("single_int64_wrapper") == .null)
    #expect(object.field("standalone_enum") == .int(1))
    #expect(object.field("single_value") == .string("hello world"))
    #expect(object.field("single_struct") == ["null": .null])
    let nested = try #require(object.field("single_nested_message").protobufObject)
    #expect(nested.field("bb") == .int(123))
    #expect(object.field("undefined").errorMessage == "no such field 'undefined'")
  }

  @Test func fieldIsSet() throws {
    let types = testTypes()
    let set = try #require(types.value(of: Proto3.with { $0.singleBool = true }).protobufObject)
    let unset = try #require(types.value(of: Proto3.with { $0.singleBool = false }).protobufObject)
    #expect(set.isFieldSet("single_bool") == .bool(true))
    #expect(unset.isFieldSet("single_bool") == .bool(false))
    #expect(unset.isFieldSet("single_any") == .bool(false))
    #expect(unset.isFieldSet("undefined").errorMessage == "no such field 'undefined'")
  }

  @Test func presence() throws {
    let types = testTypes()
    let proto2 = try #require(types.value(of: Proto2.with { $0.singleInt32 = 0 }).protobufObject)
    // proto2 optional scalars have explicit presence, even at their default.
    #expect(proto2.isFieldSet("single_int32") == .bool(true))
    #expect(proto2.isFieldSet("single_int64") == .bool(false))
    let empty = try #require(types.value(of: Proto3()).protobufObject)
    for field in ["repeated_int32", "map_string_string", "single_nested_message", "single_nested_enum"] {
      #expect(empty.isFieldSet(field) == .bool(false), "\(field)")
    }
    let oneof = try #require(types.value(of: Proto3.with { $0.singleNestedEnum = .foo }).protobufObject)
    #expect(oneof.isFieldSet("single_nested_enum") == .bool(true))
    #expect(oneof.isFieldSet("single_nested_message") == .bool(false))
    let lists = try #require(
      types.value(of: Proto3.with {
        $0.repeatedInt32 = [1]
        $0.mapStringString = ["a": "b"]
      }).protobufObject)
    #expect(lists.isFieldSet("repeated_int32") == .bool(true))
    #expect(lists.isFieldSet("map_string_string") == .bool(true))
  }

  @Test func proto2Defaults() throws {
    let types = testTypes()
    let object = try #require(types.value(of: Proto2()).protobufObject)
    // proto2 [default = ...] values are returned for unset fields.
    let defaults = Proto2()
    #expect(object.field("single_int32") == .int(Int64(defaults.singleInt32)))
    #expect(object.field("single_string") == .string(defaults.singleString))
  }

  struct UnwrapCase: Sendable, CustomTestStringConvertible {
    var message: any SwiftProtobuf.Message
    var value: Value
    var testDescription: String { "\(type(of: message).protoMessageName) \(value)" }
  }

  static let unwrapCases: [UnwrapCase] = [
    UnwrapCase(message: Google_Protobuf_Value(), value: .null),
    UnwrapCase(message: try! packAny(Google_Protobuf_BoolValue(true)), value: .bool(true)),
    UnwrapCase(message: try! packAny(jsonValue(.numberValue(4.5))), value: .double(4.5)),
    UnwrapCase(message: try! serializedAny(jsonValue(.numberValue(4.5))), value: .double(4.5)),
    UnwrapCase(message: Google_Protobuf_ListValue(), value: .list(ArrayList())),
    UnwrapCase(message: jsonValue(.boolValue(true)), value: .bool(true)),
    UnwrapCase(message: jsonValue(.boolValue(false)), value: .bool(false)),
    UnwrapCase(message: jsonValue(.nullValue(.nullValue)), value: .null),
    UnwrapCase(message: jsonValue(.numberValue(1.5)), value: .double(1.5)),
    UnwrapCase(message: jsonValue(.stringValue("hello world")), value: .string("hello world")),
    UnwrapCase(
      message: jsonValue(
        .listValue(Google_Protobuf_ListValue(values: [jsonValue(.boolValue(true)), jsonValue(.numberValue(1))]))),
      value: [.bool(true), .double(1)]),
    UnwrapCase(
      message: jsonValue(.structValue(Google_Protobuf_Struct(fields: ["hello": jsonValue(.stringValue("world"))]))),
      value: ["hello": "world"]),
    UnwrapCase(message: Google_Protobuf_BoolValue(false), value: .bool(false)),
    UnwrapCase(message: Google_Protobuf_BoolValue(true), value: .bool(true)),
    UnwrapCase(message: Google_Protobuf_BytesValue(Data("hello".utf8)), value: .bytes(Array("hello".utf8))),
    UnwrapCase(message: Google_Protobuf_DoubleValue(-4.2), value: .double(-4.2)),
    UnwrapCase(message: Google_Protobuf_FloatValue(4.5), value: .double(4.5)),
    UnwrapCase(message: Google_Protobuf_Int32Value(123), value: .int(123)),
    UnwrapCase(message: Google_Protobuf_Int64Value(456), value: .int(456)),
    UnwrapCase(message: Google_Protobuf_StringValue("goodbye"), value: .string("goodbye")),
    UnwrapCase(message: Google_Protobuf_UInt32Value(1234), value: .uint(1234)),
    UnwrapCase(message: Google_Protobuf_UInt64Value(5678), value: .uint(5678)),
    UnwrapCase(
      message: Google_Protobuf_Timestamp(seconds: 12345, nanos: 0),
      value: .timestamp(CELTimestamp(secondsSinceEpoch: 12345))),
    UnwrapCase(message: Google_Protobuf_Duration(seconds: 0, nanos: 345), value: .duration(CELDuration(nanoseconds: 345))),
  ]

  /// cel-go `TestTypeDescriptionMaybeUnwrap`: well-known types unwrap to CEL values.
  @Test(arguments: unwrapCases)
  func maybeUnwrap(_ test: UnwrapCase) {
    #expect(testTypes().value(of: test.message) == test.value)
  }

  @Test func unwrapAnyMessage() throws {
    let types = testTypes()
    let inner = Proto3.with { $0.singleFloat = 123 }
    let object = try #require(types.value(of: try serializedAny(inner)).protobufObject)
    #expect(object.message.isEqualTo(message: inner))
  }

  @Test func durationSaturates() {
    #expect(
      ProtobufTypes().value(of: Google_Protobuf_Duration(seconds: Int64.max, nanos: 0))
        == .duration(CELDuration(nanoseconds: Int64.max)))
    #expect(
      ProtobufTypes().value(of: Google_Protobuf_Duration(seconds: Int64.min, nanos: 0))
        == .duration(CELDuration(nanoseconds: Int64.min)))
  }

  @Test func checkedTypes() throws {
    let types = testTypes()
    let name = "google.expr.proto3.test.TestAllTypes"
    let expected: [(String, CELType)] = [
      ("map_string_string", .map(key: .string, value: .string)),
      ("repeated_nested_message", .list(.object("google.expr.proto3.test.TestAllTypes.NestedMessage"))),
      ("single_int32", .int), ("single_uint32", .uint), ("single_sint64", .int), ("single_fixed32", .uint),
      ("single_float", .double), ("single_bytes", .bytes), ("standalone_enum", .int),
      ("single_any", .any), ("single_duration", .duration), ("single_timestamp", .timestamp),
      ("single_struct", .map(key: .string, value: .dyn)), ("single_value", .dyn),
      ("single_int64_wrapper", .wrapper(.int)), ("single_float_wrapper", .wrapper(.double)),
      ("repeated_bool", .list(.bool)), ("imported_enums", .list(.int)),
      ("map_int64_nested_type", .map(key: .int, value: .object("google.expr.proto3.test.NestedTestAllTypes"))),
    ]
    for (field, type) in expected {
      let fieldType = try #require(types.findStructFieldType(name, fieldName: field), "\(field)")
      #expect(fieldType.type == type, "\(field)")
    }
  }
}

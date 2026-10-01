// Enum fields of the cel-spec conformance messages: NullValue fields in JSON, undeclared numbers in proto2 enums.
// Not a ported file: the expected values are what cel-go (protoreflect, protojson) does.

import CEL
import CELProtobuf
import CELSpecProtos
import Foundation
import SwiftProtobuf
import Testing

struct EnumFieldTests {
  let types = CELSpecProtos.protobufTypes
  let proto3 = "cel.expr.conformance.proto3.TestAllTypes"
  let proto2 = "cel.expr.conformance.proto2.TestAllTypes"

  /// The message converted to a JSON `google.protobuf.Value`, as `google.protobuf.Struct{...}` does.
  func json(_ value: Value) throws -> Google_Protobuf_Value {
    try types.message(from: value, as: Google_Protobuf_Value.self)
  }

  /// A `google.protobuf.NullValue` field holding any number is `null` in JSON: protojson writes every
  /// NullValue as `null`, whatever number the field holds (cel-go stores the number). SwiftProtobuf
  /// does so for singular and repeated fields, but writes the number for map values.
  @Test(arguments: ["cel.expr.conformance.proto3.TestAllTypes", "cel.expr.conformance.proto2.TestAllTypes"])
  func nullValueNumbersAreNullInJSON(message: String) throws {
    let value = types.newValue(
      message,
      fields: [
        "null_value": 3,
        "repeated_null_value": [0, 5],
        "map_string_null_value": ["foo": 3, "bar": 0],
      ])
    let json = try json(value)
    let fields = json.structValue.fields
    #expect(fields["nullValue"] == Google_Protobuf_Value(nilLiteral: ()))
    #expect(
      fields["repeatedNullValue"]
        == Google_Protobuf_Value(listValue: Google_Protobuf_ListValue(values: [nil, nil])))
    #expect(
      fields["mapStringNullValue"]
        == Google_Protobuf_Value(structValue: Google_Protobuf_Struct(fields: ["foo": nil, "bar": nil])))
  }

  // MARK: Undeclared numbers in proto2 (closed) enum fields

  /// The field of a proto2 message created with `fields`.
  func proto2Field(_ name: String, _ fields: [String: Value]) throws -> Value {
    let value = types.newValue(proto2, fields: fields)
    let object = try #require(value.protobufObject)
    return object.field(name)
  }

  /// cel-go stores any 32-bit number in a proto2 enum field, declared or not (Go enums are int32s);
  /// swift-protobuf's closed enums cannot hold an undeclared one.
  @Test func proto2EnumFieldsHoldUndeclaredNumbers() throws {
    #expect(try proto2Field("standalone_enum", ["standalone_enum": 10]) == 10)
    #expect(try proto2Field("standalone_enum", ["standalone_enum": -3]) == -3)
    #expect(try proto2Field("single_nested_enum", ["single_nested_enum": 10]) == 10)
    #expect(try proto2Field("repeated_nested_enum", ["repeated_nested_enum": [1, 10, 2]]) == [1, 10, 2])
    #expect(try proto2Field("map_string_enum", ["map_string_enum": ["a": 10, "b": 1]]) == ["a": 10, "b": 1])
    #expect(try proto2Field("map_int32_enum", ["map_int32_enum": [-1: 10, 2: 1]]) == [-1: 10, 2: 1])
    let object = try #require(types.newValue(proto2, fields: ["standalone_enum": 10]).protobufObject)
    #expect(object.isFieldSet("standalone_enum") == true)
    #expect(object.isFieldSet("single_nested_enum") == false)
    // The 32-bit range is still checked.
    #expect(types.newValue(proto2, fields: ["standalone_enum": 2_147_483_648]).isError)
  }

  @Test func proto2UndeclaredEnumNumbersCompareAndSerialize() throws {
    let ten = types.newValue(proto2, fields: ["standalone_enum": 10, "repeated_nested_enum": [10, 1]])
    #expect(ten.celEquals(types.newValue(proto2, fields: ["standalone_enum": 10, "repeated_nested_enum": [10, 1]])) == true)
    #expect(ten.celEquals(types.newValue(proto2, fields: ["standalone_enum": 11, "repeated_nested_enum": [10, 1]])) == false)
    // Through an Any (binary encoding) and back.
    let any = try types.message(from: ten, as: Google_Protobuf_Any.self)
    let unpacked = try #require(types.value(of: any).protobufObject)
    #expect(unpacked.field("standalone_enum") == 10)
    #expect(unpacked.field("repeated_nested_enum") == [10, 1])
    // Bytes from elsewhere: field 24 (standalone_enum) holding 10.
    let decoded = try Cel_Expr_Conformance_Proto2_TestAllTypes(serializedBytes: [0xC0, 0x01, 0x0A] as [UInt8])
    #expect(types.value(of: decoded).protobufObject?.field("standalone_enum") == 10)
    // Decoding puts declared numbers in the typed field and the others in unknown fields, unlike a
    // literal; equality compares the field values.
    let list = try Cel_Expr_Conformance_Proto2_TestAllTypes(
      serializedBytes: [0xA0, 0x03, 0x01, 0xA0, 0x03, 0x0A] as [UInt8])
    #expect(types.value(of: list).protobufObject?.field("repeated_nested_enum") == [1, 10])
    #expect(types.value(of: list).celEquals(types.newValue(proto2, fields: ["repeated_nested_enum": [1, 10]])) == true)
  }

  /// A singular field (and a map key) repeated on the wire takes the last value. swift-protobuf
  /// keeps a declared number in the typed field and an undeclared one in the unknown fields, so a
  /// decoded message holds both; the declared number came last here, and cel-go (and the typed
  /// accessor) read it.
  @Test func decodedClosedEnumFieldsReadTheLastDeclaredValue() throws {
    // standalone_enum (24) = 10, then = 1.
    let singular = try Cel_Expr_Conformance_Proto2_TestAllTypes(
      serializedBytes: [0xC0, 0x01, 0x0A, 0xC0, 0x01, 0x01] as [UInt8])
    #expect(singular.standaloneEnum == .bar)
    // map_int32_enum (83) {1: 10}, then {1: 1}.
    let map = try Cel_Expr_Conformance_Proto2_TestAllTypes(
      serializedBytes: [0x9A, 0x05, 0x04, 0x08, 0x01, 0x10, 0x0A, 0x9A, 0x05, 0x04, 0x08, 0x01, 0x10, 0x01] as [UInt8])
    #expect(map.mapInt32Enum == [1: .bar])
    let singularField = types.value(of: singular).protobufObject?.field("standalone_enum")
    let mapField = types.value(of: map).protobufObject?.field("map_int32_enum")
    withKnownIssue("the undeclared number in the unknown fields takes precedence") {
      #expect(singularField == 1)
      #expect(mapField == [1: 1])
    }
  }

  /// protojson writes undeclared enum numbers as numbers and declared ones as names.
  @Test func proto2UndeclaredEnumNumbersInJSON() throws {
    let value = types.newValue(
      proto2,
      fields: ["standalone_enum": 10, "repeated_nested_enum": [1, 10], "map_int32_enum": [1: 10, 2: 1]])
    let fields = try json(value).structValue.fields
    #expect(fields["standaloneEnum"] == Google_Protobuf_Value(numberValue: 10))
    #expect(
      fields["repeatedNestedEnum"]
        == Google_Protobuf_Value(listValue: Google_Protobuf_ListValue(values: ["BAR", 10])))
    #expect(
      fields["mapInt32Enum"]
        == Google_Protobuf_Value(structValue: Google_Protobuf_Struct(fields: ["1": 10, "2": "BAR"])))
  }

  /// Nested messages are converted the same way.
  @Test func nestedNullValueNumbersAreNullInJSON() throws {
    let inner = types.newValue(proto3, fields: ["map_int64_null_value": [1: 7]])
    let outer = types.newValue(
      "cel.expr.conformance.proto3.NestedTestAllTypes", fields: ["payload": inner])
    let payload = try json(outer).structValue.fields["payload"]?.structValue
    #expect(payload?.fields["mapInt64NullValue"]?.structValue.fields["1"] == nil as Google_Protobuf_Value)
  }
}

// Enum fields of the cel-spec conformance messages: `google.protobuf.NullValue` fields converted to JSON.
// Not a ported file: cel-go gets these from protojson, which these tests compare against.

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

  /// Nested messages are converted the same way.
  @Test func nestedNullValueNumbersAreNullInJSON() throws {
    let inner = types.newValue(proto3, fields: ["map_int64_null_value": [1: 7]])
    let outer = types.newValue(
      "cel.expr.conformance.proto3.NestedTestAllTypes", fields: ["payload": inner])
    let payload = try json(outer).structValue.fields["payload"]?.structValue
    #expect(payload?.fields["mapInt64NullValue"]?.structValue.fields["1"] == nil as Google_Protobuf_Value)
  }
}

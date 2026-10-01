// Tests for the cel.expr.Value conversions in CELSpecProtos (port of cel-go cel/io.go) and the
// conformance test messages' generated adapters.

import CEL
import CELProtobuf
import CELSpecProtos
import Foundation
import SwiftProtobuf
import Testing

struct CELExprValueTests {
  let types = CELSpecProtos.protobufTypes

  @Test func roundTripsPrimitivesAndCollections() throws {
    let values: [Value] = [
      .null, true, 1, .uint(2), 1.5, "s", .bytes([1, 2]), .type(.int), .type(.object("a.B")),
      [1, "a", [true]], ["k": 1, "j": [.null]],
    ]
    for value in values {
      let proto = try Cel_Expr_Value(celValue: value, types: types)
      #expect(try proto.celValue(types: types) == value, "\(value)")
    }
  }

  @Test func durationsTimestampsAndMessagesAreObjects() throws {
    let duration = Value.duration(CELDuration(nanoseconds: 1_000_000_001))
    let proto = try Cel_Expr_Value(celValue: duration, types: types)
    #expect(proto.objectValue.typeURL == "type.googleapis.com/google.protobuf.Duration")
    #expect(try proto.celValue(types: types) == duration)

    let message = types.newValue(
      "cel.expr.conformance.proto3.TestAllTypes", fields: ["single_int32": 5, "single_any": "x"])
    let packed = try Cel_Expr_Value(celValue: message, types: types)
    #expect(packed.objectValue.typeURL == "type.googleapis.com/cel.expr.conformance.proto3.TestAllTypes")
    let back = try packed.celValue(types: types)
    #expect(back == message)
  }

  @Test func decodesTextFormatBindings() throws {
    // The shape of a conformance test binding: a proto2 message with an extension, packed in Any.
    let text = """
      object_value {
        [type.googleapis.com/cel.expr.conformance.proto2.TestAllTypes] {
          single_int32: 7
          [cel.expr.conformance.proto2.int32_ext]: 42
        }
      }
      """
    Google_Protobuf_Any.register(messageType: Cel_Expr_Conformance_Proto2_TestAllTypes.self)
    let proto = try Cel_Expr_Value(textFormatString: text, extensions: CELSpecProtos.extensions)
    let object = try #require(try proto.celValue(types: types).protobufObject)
    #expect(object.field("single_int32") == 7)
    #expect(object.field("cel.expr.conformance.proto2.int32_ext") == 42)
    #expect(object.isFieldSet("cel.expr.conformance.proto2.nested_ext") == false)
  }

  @Test func exprValueErrorsAndUnknowns() throws {
    let error = try Cel_Expr_ExprValue(celValue: .error(EvalError("boom")), types: types)
    #expect(error.error.errors.first?.message == "boom")
    let unknown = try Cel_Expr_ExprValue(celValue: .unknown(UnknownSet(exprID: 3)), types: types)
    #expect(unknown.unknown.exprs == [3])
    #expect(throws: EvalError.self) { try Cel_Expr_Value(celValue: .optional(nil), types: types) }
  }

  @Test func conformanceEnumsAndWrappers() {
    #expect(types.enumValue("cel.expr.conformance.proto3.GlobalEnum.GAZ") == 2)
    #expect(types.enumValue("cel.expr.conformance.proto2.TestAllTypes.NestedEnum.BAR") == 1)
    // proto3 enums are open: unknown numbers are kept.
    let proto3 = types.newValue("cel.expr.conformance.proto3.TestAllTypes", fields: ["standalone_enum": 99])
    #expect(proto3.protobufObject?.field("standalone_enum") == 99)
    // proto2 enums are closed in swift-protobuf.
    let proto2 = types.newValue("cel.expr.conformance.proto2.TestAllTypes", fields: ["standalone_enum": 99])
    #expect(proto2.isError)
    let tooBig = types.newValue(
      "cel.expr.conformance.proto2.TestAllTypes", fields: ["standalone_enum": .int(5_000_000_000)])
    #expect(tooBig.isError)
  }

  @Test func reservedWordFieldsAndGroups() throws {
    let value = types.newValue("cel.expr.conformance.proto2.TestAllTypes", fields: ["in": true, "while": true])
    let object = try #require(value.protobufObject)
    #expect(object.field("in") == true)
    #expect(object.field("while") == true)
    let group = types.newValue(
      "cel.expr.conformance.proto2.TestAllTypes",
      fields: [
        "nestedgroup": types.newValue(
          "cel.expr.conformance.proto2.TestAllTypes.NestedGroup", fields: ["single_id": 3])
      ])
    #expect(group.protobufObject?.field("nestedgroup").protobufObject?.field("single_id") == 3)
  }

  @Test func proto3OptionalPresence() throws {
    // cel-spec proto3 TestAllTypes has `optional` fields with explicit presence.
    let names = try #require(types.findStructFieldNames("cel.expr.conformance.proto3.TestAllTypes"))
    #expect(names.contains("optional_bool"))
    let value = types.newValue("cel.expr.conformance.proto3.TestAllTypes", fields: ["optional_bool": false])
    #expect(value.protobufObject?.isFieldSet("optional_bool") == true)
  }
}

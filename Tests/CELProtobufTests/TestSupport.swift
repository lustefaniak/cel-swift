// Shared fixtures for the CELProtobuf tests: the cel-go test protos registered as CEL types.

import CEL
import CELGoTestProtos
import CELProtobuf
import Foundation
import SwiftProtobuf

typealias Proto3 = Google_Expr_Proto3_Test_TestAllTypes
typealias Proto3Nested = Google_Expr_Proto3_Test_NestedTestAllTypes
typealias Proto2 = Google_Expr_Proto2_Test_TestAllTypes

/// cel-go's `newTestRegistry` with the proto2 / proto3 test messages registered.
func testTypes(jsonFieldNames: Bool = false) -> ProtobufTypes {
  ProtobufTypes(
    files: [
      Google_Expr_Proto3_Test_TestAllTypes_CELFile,
      Google_Expr_Proto2_Test_TestAllTypes_CELFile,
      Google_Expr_Proto2_Test_TestExtensions_CELFile,
    ],
    jsonFieldNames: jsonFieldNames
  )
}

/// cel-go `anypb.New`.
func packAny(_ message: any SwiftProtobuf.Message) throws -> Google_Protobuf_Any {
  try Google_Protobuf_Any(message: message, partial: true)
}

/// An `Any` holding serialized bytes rather than an in-memory message.
func serializedAny(_ message: any SwiftProtobuf.Message, typeURL: String? = nil) throws
  -> Google_Protobuf_Any
{
  var any = Google_Protobuf_Any()
  any.typeURL = typeURL ?? "type.googleapis.com/\(type(of: message).protoMessageName)"
  let bytes: Data = try message.serializedBytes()
  any.value = bytes
  return any
}

extension Value {
  /// The object as a `ProtobufObject`, or `nil`.
  var protobufObject: ProtobufObject? {
    guard case .object(let object) = self else { return nil }
    return object as? ProtobufObject
  }

  /// The error message, or `nil` for a non-error value.
  var errorMessage: String? {
    guard case .error(let error) = self else { return nil }
    return error.message
  }
}

func jsonValue(_ kind: Google_Protobuf_Value.OneOf_Kind) -> Google_Protobuf_Value {
  var v = Google_Protobuf_Value()
  v.kind = kind
  return v
}

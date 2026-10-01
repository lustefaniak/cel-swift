// Hand-written companion to the generated cel-spec protos (everything else in this directory comes from
// tools/gen-protos.sh and must not be edited). Not a ported file.

import SwiftProtobuf

/// Registries over the generated cel-spec messages, for decoders that meet `google.protobuf.Any` and proto2
/// extensions in conformance data.
package enum CELSpecProtos {
  /// Every proto2 extension declared by the conformance protos.
  package static let extensions: SimpleExtensionMap = Cel_Expr_Conformance_Proto2_TestAllTypesExtensions_Extensions

  /// The conformance test messages that may appear packed in a `google.protobuf.Any`.
  package static let messageTypes: [any Message.Type] = [
    Cel_Expr_Conformance_Proto2_TestAllTypes.self,
    Cel_Expr_Conformance_Proto2_TestAllTypes.NestedMessage.self,
    Cel_Expr_Conformance_Proto2_Proto2ExtensionScopedMessage.self,
    Cel_Expr_Conformance_Proto2_NestedTestAllTypes.self,
    Cel_Expr_Conformance_Proto2_TestRequired.self,
    Cel_Expr_Conformance_Proto3_TestAllTypes.self,
    Cel_Expr_Conformance_Proto3_TestAllTypes.NestedMessage.self,
    Cel_Expr_Conformance_Proto3_NestedTestAllTypes.self,
  ]
}

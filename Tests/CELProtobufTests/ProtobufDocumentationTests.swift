// The examples of Sources/CELProtobuf/CELProtobuf.docc, so the documentation keeps compiling and
// stays true. Keep them in sync when either side changes.

import CEL
import CELGoTestProtos
import CELProtobuf
import Testing

@Suite("CELProtobuf documentation examples")
struct ProtobufDocumentationTests {
  @Test func landingPage() throws {
    let protos = ProtobufTypes(files: [Google_Expr_Proto3_Test_TestAllTypes_CELFile])
    let env = try Environment(
      .typeProvider(protos),
      .variable("msg", .objectType("google.expr.proto3.test.TestAllTypes"))
    )
    var message = Google_Expr_Proto3_Test_TestAllTypes()
    message.singleInt64 = 7
    let program = try env.program(env.compile("msg.single_int64 > 5"))
    #expect(try program.evaluate(["msg": protos.value(of: message)]).value == true)
  }

  @Test func usingProtobufMessages() throws {
    let protos = ProtobufTypes(files: [Google_Expr_Proto3_Test_TestAllTypes_CELFile])
    let env = try Environment(
      .typeProvider(protos),
      .container("google.expr.proto3.test"),
      .variable("msg", .objectType("google.expr.proto3.test.TestAllTypes"))
    )

    var message = Google_Expr_Proto3_Test_TestAllTypes()
    message.singleInt64 = 7
    message.repeatedString = ["a", "b"]
    let program = try env.program(env.compile("msg.single_int64 > 5 && 'b' in msg.repeated_string"))
    #expect(try program.evaluate(["msg": protos.value(of: message)]).value == true)

    let built = try env.program(env.compile("TestAllTypes{single_string: 'hi', single_int32: 3}"))
    let value = try built.evaluate().value
    let result = try protos.message(from: value, as: Google_Expr_Proto3_Test_TestAllTypes.self)
    #expect(result.singleString == "hi")
    #expect(result.singleInt32 == 3)

    #expect(throws: EvalError.self) {
      _ = try protos.message(from: .int(1), as: Google_Expr_Proto3_Test_TestAllTypes.self)
    }
  }
}

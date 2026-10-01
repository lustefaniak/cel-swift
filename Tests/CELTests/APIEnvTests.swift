// Ported from cel-go cel/env_test.go against the public API.
//
// Not ported, with the reason:
// - TestAstNil, TestIssuesNil, TestIssuesEmpty, TestIssuesAppendSelf, TestEnvPartialVarsError,
//   TestMaybeInteropProvider_*: nil receivers, untyped inputs and the legacy exprpb provider have no
//   Swift counterpart; CompileError has no Append.
// - TestErrorAsIssues: the conversion is package-internal (CompileError(message:source:)).
// - TestFormatCELTypeEquivalence: compares with the exprpb formatter.
// - TestEnvToConfig, TestEnvFromConfig, TestEnvFromConfigErrors, TestDeclareContextProto_Duplicate:
//   environment configuration lives in CELPolicy and is tested there.
// - TestCELTypeAdapter, TestParserErrorRecoveryLimit, TestEnableHiddenAccumulatorName: read
//   unexported fields; the options are exercised by the parser tests.

import CEL
import CELGoTestProtos
import CELProtobuf
import Testing

@Suite("env_test.go")
struct APIEnvTests {
  @Test func issuesFromSeveralErrors() throws {
    let env = try Environment()
    #expect {
      try env.compile("-")
    } throws: { error in
      guard let error = error as? CompileError else { return false }
      return error.issues.count == 2
        && error.description == """
          ERROR: <input>:1:2: Syntax error: no viable alternative at input '-'
           | -
           | .^
          ERROR: <input>:1:2: Syntax error: mismatched input '<EOF>' expecting {'[', '{', '(', '.', '-', '!', 'true', 'false', 'null', NUM_FLOAT, NUM_INT, NUM_UINT, STRING, BYTES, IDENTIFIER}
           | -
           | .^
          """
    }
    #expect {
      try env.compile("a")
    } throws: { ($0 as? CompileError)?.issues.count == 1 }
  }

  @Test func extendingDisablesDeclaration() throws {
    let base = try Environment.custom(.function("foo", .overload("foo_bool", argumentTypes: [.bool], resultType: .bool)))
    _ = try base.compile("foo(true)")
    let child = try base.extending(
      .function("foo", .disableDeclaration(true), .overload("foo_bool", argumentTypes: [.bool], resultType: .bool)))
    #expect(throws: CompileError.self) { try child.compile("foo(true)") }
  }

  @Test func compileWhileExtending() async throws {
    for _ in 0..<50 {
      let env = try Environment.custom(.standardLibrary)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = try env.compile("1 + 1 * 20 < 400") }
        group.addTask { _ = try env.extending(.variable("bar", .bool)) }
        try await group.waitForAll()
      }
    }
  }

  @Test func concurrentExtend() async throws {
    let base = try Environment.custom(.standardLibrary)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for id in 0..<50 {
        group.addTask { _ = try base.extending(.variable("v\(id)", .string)) }
      }
      try await group.waitForAll()
    }
  }

  @Test func concurrentExtendAndCompile() async throws {
    let base = try Environment.custom(.standardLibrary)
    try await withThrowingTaskGroup(of: Value.self) { group in
      for id in 0..<50 {
        group.addTask {
          let name = "v\(id)"
          let env = try base.extending(.variable(name, .int))
          return try env.program(env.compile("\(name) > 0")).evaluate([name: 10]).value
        }
      }
      for try await value in group {
        #expect(value == true)
      }
    }
  }

  @Test func concurrentExtendWithFunctions() async throws {
    let base = try Environment.custom(.standardLibrary)
    try await withThrowingTaskGroup(of: Value.self) { group in
      for id in 0..<50 {
        group.addTask {
          let name = "custom_func_\(id)"
          let env = try base.extending(
            .function(name, .overload("\(name)_int", argumentTypes: [.int], resultType: .int, .unaryBinding { $0 })))
          return try env.program(env.compile("\(name)(42) == 42")).evaluate().value
        }
      }
      for try await value in group {
        #expect(value == true)
      }
    }
  }

  @Test func typeProviderInterop() throws {
    let env = try Environment(.typeProvider(ProtobufTypes(files: [Google_Expr_Proto3_Test_TestAllTypes_CELFile])))
    let provider = env.typeProvider
    #expect(provider.findStructType("google.expr.proto3.test.TestAllTypes") != nil)
    let field = try #require(provider.findStructFieldType("google.expr.proto3.test.TestAllTypes", fieldName: "single_int32"))
    #expect(field.type == .int)
    #expect(provider.findStructType("test.BadTypeName") == nil)
    #expect(provider.findStructFieldType("google.expr.proto3.test.TestAllTypes", fieldName: "undefined_field") == nil)
  }

  @Test func libraries() throws {
    let env = try Environment(.optionalTypes)
    #expect(env.hasLibrary(named: "cel.lib.std"))
    #expect(env.hasLibrary(named: "cel.lib.optional"))
    #expect(Set(env.libraryNames) == ["cel.lib.std", "cel.lib.optional"])
  }

  @Test func functions() throws {
    let env = try Environment(.optionalTypes)
    for name in ["optional.of", "or"] {
      #expect(env.hasFunction(named: name))
      #expect(env.functions.contains { $0.name == name })
    }
  }

  @Test(arguments: [
    ("compatible_duplicate", [Environment.Option.variable("foo", .int), .variable("foo", .int)], nil),
    ("variable_and_constant", [.variable("foo", .int), .constant("foo", .int, value: 50)], nil),
    ("compatible_constant", [.constant("foo", .string, value: "foo"), .constant("foo", .string, value: "foo")], nil),
    ("incompatible_variable", [.variable("foo", .int), .variable("foo", .double)], "overlapping identifier for name"),
    (
      "incompatible_constant", [.constant("foo", .int, value: 42), .constant("foo", .int, value: 43)],
      "conflicting constant definitions"
    ),
  ] as [(String, [Environment.Option], String?)])
  func variableValidation(_ name: String, _ options: [Environment.Option], _ error: String?) throws {
    // cel-go validates variables lazily, when the first expression is checked; here the
    // environment validates them when it is created.
    let result = Result { () throws -> CheckedExpression in
      try Environment(options: options).compile("foo")
    }
    switch (result, error) {
    case (.success, nil):
      break
    case (.failure(let failure), let error?):
      #expect("\(failure)".contains(error), "\(name)")
    case (.success, let error?):
      Issue.record("\(name): wanted error \(error)")
    case (.failure(let failure), nil):
      Issue.record("\(name): \(failure)")
    }
  }
}

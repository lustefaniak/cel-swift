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
// Ported from cel-go checker/checker_test.go. The table is generated (tools/checker-cases) into
// Fixtures/CheckerCases.swift.

import Testing

@testable import CEL

@Suite struct CheckerTests {
  @Test(arguments: CheckerCase.all)
  func check(_ tc: CheckerCase) throws {
    let parser = try Parser(
      .macros(Macro.allMacros), .enableOptionalSyntax(tc.optionalSyntax),
      .enableVariadicOperatorASTs(tc.variadicASTs))
    let src = TextSource(tc.in)
    let (parsed, parseErrors) = parser.parse(src)
    try #require(parseErrors.isEmpty, "Unexpected parse errors: \(parseErrors.toDisplayString())")

    var registry = testTypeRegistry(jsonFieldNames: tc.jsonFieldNames)
    if tc.optionalSyntax {
      try registry.register(CELType.optionalOfDyn)
    }
    let container = try Container(.name(tc.container))
    var options: [CheckerOption] = [.crossTypeNumericComparisons(tc.crossTypeNumericComparisons)]
    if tc.jsonFieldNames {
      options.append(.jsonFieldNames(true))
    }
    var env = CheckerEnv(container: container, provider: registry, options: options)
    if !tc.disableStdEnv {
      try? env.addFunctions(StandardLibrary.functions)
    }
    for ident in tc.idents {
      try? env.addIdents(ident)
    }
    for fn in tc.functions {
      try? env.addFunctions(fn)
    }

    let (checked, errors) = Checker.check(parsed, source: src, env: env)
    if !errors.isEmpty {
      let errorString = errors.toDisplayString()
      if !tc.err.isEmpty {
        #expect(
          compareIgnoringWhitespace(errorString, tc.err),
          "Error mismatch:\ngot \(errorString)\nwanted \(tc.err)")
      } else {
        Issue.record("Unexpected type-check errors: \(errorString)")
      }
    } else if !tc.err.isEmpty {
      Issue.record("Expected error not thrown: \(tc.err)")
    }

    let ids = checked.ids
    let unused = checked.sourceInfo.offsetRanges.keys.filter { !ids.contains($0) }.sorted()
    #expect(
      unused.isEmpty,
      "SourceInfo has offset ranges for ids \(unused) without nodes: \(ExprDebug.toDebugStringWithIDs(checked.expr))")

    if tc.err.isEmpty {
      let actual = checked.type(of: parsed.expr.id)
      if let outType = tc.outType {
        #expect(actual.isEquivalentType(outType), "Type error: got \(actual), wanted \(outType)")
      }
    }

    if !tc.out.isEmpty {
      let actual = Checker.print(checked.expr, checked: checked)
      #expect(
        compareIgnoringWhitespace(actual, tc.out), "Structure error:\ngot \(actual)\nwanted \(tc.out)")
    }
  }

  @Test func addDuplicateDeclarations() throws {
    var env = CheckerEnv(provider: testTypeRegistry(), options: [.crossTypeNumericComparisons(true)])
    try env.addFunctions(StandardLibrary.functions)
    try env.addFunctions(StandardLibrary.functions)
  }

  @Test func addEquivalentDeclarations() throws {
    var env = CheckerEnv(provider: testTypeRegistry(), options: [.crossTypeNumericComparisons(true)])
    func optIndex() throws -> FunctionDecl {
      try FunctionDecl(
        "optional_index",
        .overload(
          "optional_map_key_value",
          argTypes: [.map(key: .typeParam("K"), value: .typeParam("V")), .typeParam("K")],
          resultType: .optional(.typeParam("V"))))
    }
    try env.addFunctions(optIndex())
    try env.addFunctions(optIndex())
  }

  @Test func checkErrorData() throws {
    let parser = try Parser(.enableOptionalSyntax(true), .macros(Macro.allMacros))
    let src = TextSource("a || true")
    let (parsed, parseErrors) = parser.parse(src)
    try #require(parseErrors.isEmpty)
    var env = CheckerEnv(provider: TypeRegistry())
    try env.addFunctions(StandardLibrary.functions)
    let (_, errors) = Checker.check(parsed, source: src, env: env)
    try #require(errors.errors.count == 1, "\(errors.toDisplayString())")
    #expect(errors.errors[0].exprID == 1)
    #expect(errors.errors[0].message.contains("undeclared reference"))
  }

  @Test func checkInvalidOptSelectMember() {
    let target = Expr.struct(id: 1, typeName: "Foo", fields: [])
    let arg1 = Expr.struct(id: 2, typeName: "Foo", fields: [])
    let arg2 = Expr.literal(id: 3, .string("field"))
    let call = Expr.memberCall(id: 4, function: "_?._", target: target, args: [arg1, arg2])
    // Not valid syntax, just for illustration purposes.
    let src = TextSource("Foo{}._?._(Foo{}, 'field')")
    let parsed = AST(expr: call, sourceInfo: SourceInfo(source: src))
    let env = CheckerEnv(provider: TypeRegistry())
    let (_, errors) = Checker.check(parsed, source: src, env: env)
    #expect(errors.toDisplayString().contains("incorrect signature. member call"))
  }

  @Test func checkInvalidOptSelectMissingArg() {
    let arg1 = Expr.struct(id: 1, typeName: "Foo", fields: [])
    let call = Expr.call(id: 2, function: "_?._", args: [arg1])
    // Not valid syntax, just for illustration purposes.
    let src = TextSource("_?._(Foo{})")
    let parsed = AST(expr: call, sourceInfo: SourceInfo(source: src))
    let env = CheckerEnv(provider: TypeRegistry())
    let (_, errors) = Checker.check(parsed, source: src, env: env)
    #expect(errors.toDisplayString().contains("incorrect signature. argument count: 1"))
  }

  // TestCheckInvalidLiteral is not ported: `Constant` has no case for a duration literal, so the
  // invalid AST cannot be built.

  @Test func varsInheritance() throws {
    // Parent environment containing the inherited variable 'z'.
    var parentEnv = CheckerEnv(provider: TypeRegistry())
    try parentEnv.addFunctions(StandardLibrary.functions)
    try parentEnv.addIdents(VariableDecl(name: "z", type: .int))

    // Child environment inheriting declarations from parentEnv.
    var childEnv = CheckerEnv(provider: TypeRegistry(), options: [.validatedDeclarations(parentEnv)])
    try childEnv.addIdents(VariableDecl(name: "y", type: .list(.int)))

    let src = TextSource("y + [1, 2, 3].filter(x, .z > x)")
    let parser = try Parser(.macros(Macro.allMacros))
    let (parsed, parseErrors) = parser.parse(src)
    try #require(parseErrors.isEmpty, "\(parseErrors.toDisplayString())")
    let (checked, errors) = Checker.check(parsed, source: src, env: childEnv)
    try #require(errors.isEmpty, "\(errors.toDisplayString())")
    #expect(checked.type(of: checked.expr.id).isExactType(.list(.int)))
  }
}

// Ported from cel-go checker/env_test.go.
@Suite struct CheckerEnvTests {
  @Test func overlappingMacro() throws {
    var env = CheckerEnv(provider: TypeRegistry())
    try env.addFunctions(StandardLibrary.functions)
    let hasFn = try FunctionDecl("has", .overload("has", argTypes: [.string], resultType: .bool))
    #expect {
      try env.addFunctions(hasFn)
    } throws: { error in
      "\(error)".contains("overlapping macro")
    }
  }

  @Test func copyDeclarations() throws {
    let src = TextSource("1 + 2 != 3 - 4")
    let (parsed, parseErrors) = try Parser(.macros(Macro.allMacros)).parse(src)
    try #require(parseErrors.isEmpty)
    var env = CheckerEnv(provider: TypeRegistry())
    try env.addFunctions(StandardLibrary.functions)
    let (_, errors) = Checker.check(parsed, source: src, env: env)
    #expect(errors.isEmpty, "\(errors.toDisplayString())")

    let copy = CheckerEnv(provider: TypeRegistry(), options: [.validatedDeclarations(env)])
    let (_, copyErrors) = Checker.check(parsed, source: src, env: copy)
    #expect(copyErrors.isEmpty, "\(copyErrors.toDisplayString())")
  }
}

// Ported from cel-go checker/format_test.go, with the strings FormatCheckedType gives.
@Suite struct CheckerFormatTests {
  @Test(arguments: [
    (CELType.any, "any"),
    (.bool, "bool"),
    (.bytes, "bytes"),
    (.double, "double"),
    (.duration, "duration"),
    (.dyn, "dyn"),
    (.error, "!error!"),
    (.int, "int"),
    (.list(.string), "list(string)"),
    (.map(key: .int, value: .dyn), "map(int, dyn)"),
    (.object("dev.cel.Expr"), "dev.cel.Expr"),
    (.optional(.bool), "optional_type(bool)"),
    (.wrapper(.int), "wrapper(int)"),
    (.typeParam("T"), "T"),
    (.type(.list(.int)), "type(list(int))"),
    (.null, "null"),
    (.string, "string"),
    (.timestamp, "timestamp"),
    (.type(nil), "type"),
    (.uint, "uint"),
  ])
  func formatType(_ type: CELType, _ expected: String) {
    #expect(type.checkerDescription == expected)
  }

  @Test func formatFunctionType() {
    #expect(newFunctionType(.bool, [.string, .int]).checkerDescription == "(string, int) -> bool")
  }
}

// Ported from cel-go cel/inlining_test.go against the public API.

import CEL
import CELExtensions
import Testing

/// A variable of an inlining test: declared with `type`, and inlined when `expr` is set.
struct InlineVar: Sendable {
  var name: String
  var type: CELType
  var alias: String?
  var expr: String?

  init(_ name: String, _ type: CELType, alias: String? = nil, expr: String? = nil) {
    self.name = name
    self.type = type
    self.alias = alias
    self.expr = expr
  }
}

/// One inlining table row.
struct InlineCase: Sendable, CustomTestStringConvertible {
  var expr: String
  /// Variables declared but not inlined (the multi-stage table declares them separately).
  var declarations: [(String, CELType)]
  var vars: [InlineVar]
  var inlined: String
  var folded: String?

  init(_ expr: String, declarations: [(String, CELType)] = [], vars: [InlineVar], inlined: String, folded: String? = nil) {
    self.expr = expr
    self.declarations = declarations
    self.vars = vars
    self.inlined = inlined
    self.folded = folded
  }

  var testDescription: String { expr }

  /// Compiles the definitions and the expression, inlines, and checks the result and, when the
  /// table has one, the constant-folded result.
  func run(_ base: [Environment.Option], declareVars: Bool) throws {
    var options = declarations.map { Environment.Option.variable($0.0, $0.1) }
    if declareVars {
      options += vars.map { .variable($0.name, $0.type) }
    }
    let env = try Environment(options: options + base)
    var inlinedVars: [InlinedVariable] = []
    for v in vars {
      guard let expr = v.expr else {
        continue
      }
      inlinedVars.append(InlinedVariable(v.name, alias: v.alias, definition: try env.compile(expr)))
    }
    let checked = try env.compile(expr)
    let optimized = try env.optimize(checked, .inlining(inlinedVars))
    #expect(optimized.description == inlined)
    if let folded {
      let refolded = try env.optimize(optimized, .constantFolding())
      #expect(refolded.description == folded)
    }
  }
}

@Suite("Inlining")
struct APIInliningTests {
  @Test(arguments: shadowCases)
  func noopShadow(_ testCase: InlineCase) throws {
    try testCase.run([.optionalTypes, .macroCallTracking], declareVars: true)
  }

  @Test(arguments: presenceCases)
  func presenceTests(_ testCase: InlineCase) throws {
    try testCase.run(
      [
        .container("google.expr.proto3.test"), .typeProvider(proto3Types),
        .variable("msg", .object("google.expr.proto3.test.TestAllTypes")), .optionalTypes, .macroCallTracking,
      ], declareVars: true)
  }

  @Test(arguments: cases)
  func inlining(_ testCase: InlineCase) throws {
    try testCase.run(
      [
        .optionalTypes, .macroCallTracking,
        .function(
          "productsToConsumers",
          .overload("productsToConsumers_list", argTypes: [.list(.int)], resultType: .list(.int))),
      ], declareVars: true)
  }

  @Test(arguments: multiStageCases)
  func multiStage(_ testCase: InlineCase) throws {
    try testCase.run(
      [.container("google.expr"), .typeProvider(proto3Types), .optionalTypes, .macroCallTracking], declareVars: false)
  }

  @Test func presenceTestWithoutZeroValueFails() throws {
    let env = try Environment(
      .variable("a", .map(key: .string, value: .dyn)), .variable("v", .optional(.int)), .macroCallTracking)
    let definition = try env.compile("v")
    #expect(throws: CompileError.self) {
      try env.optimize(env.compile("has(a.b)"), .inlining(InlinedVariable("a.b", definition: definition)))
    }
  }

  @Test func bindRequiresNoBindingsLibraryToEvaluate() throws {
    let env = try Environment(.variable("a", .int), .macroCallTracking)
    let optimized = try env.optimize(
      env.compile("a + a"), .inlining(InlinedVariable("a", alias: "alpha", definition: try env.compile("20 + 1"))))
    #expect(optimized.description == "cel.bind(alpha, 20 + 1, alpha + alpha)")
    #expect(try env.program(optimized).evaluate().value == 42)
  }
}

extension APIInliningTests {
  static let shadowCases: [InlineCase] = [
    InlineCase(
      "[0].exists(shadowed_ident, shadowed_ident == 0)",
      vars: [InlineVar("shadowed_ident", .int, expr: "1")],
      inlined: "[0].exists(shadowed_ident, shadowed_ident == 0)"),
    InlineCase(
      "[[1]].all(shadowed_ident, shadowed_ident.all(shadowed, shadowed + 1 == 2))",
      vars: [InlineVar("shadowed_ident", .int, expr: "42")],
      inlined: "[[1]].all(shadowed_ident, shadowed_ident.all(shadowed, shadowed + 1 == 2))"),
  ]

  static let presenceCases: [InlineCase] = [
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .bool, expr: "true")],
      inlined: "true != false"),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .bytes, expr: "b'abc'")],
      inlined: #"b"\141\142\143".size() != 0"#),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .double, expr: "42.0")],
      inlined: "42.0 != 0.0"),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .duration, expr: "duration('1s')")],
      inlined: #"duration("1s") != duration("0s")"#),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .int, expr: "1")],
      inlined: "1 != 0"),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .list(.string), expr: "['foo', 'bar']")],
      inlined: #"["foo", "bar"].size() != 0"#),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .map(key: .string, value: .string), expr: "{'foo': 'bar'}")],
      inlined: #"{"foo": "bar"}.size() != 0"#),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .string, expr: "'foo'")],
      inlined: #""foo".size() != 0"#),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .object("google.expr.proto3.test.TestAllTypes"), expr: "TestAllTypes{single_int64: 1}")],
      inlined: "google.expr.proto3.test.TestAllTypes{single_int64: 1} != google.expr.proto3.test.TestAllTypes{}"),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .timestamp, expr: "timestamp(123)")],
      inlined: "timestamp(123) != timestamp(0)"),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      vars: [InlineVar("msg.single_any.processing_purpose", .uint, expr: "1u")],
      inlined: "1u != 0u"),
  ]

  static let cases: [InlineCase] = [
    InlineCase(
      "a || b",
      vars: [InlineVar("a", .bool), InlineVar("b", .bool, alias: "bravo", expr: "'hello'.contains('lo')")],
      inlined: #"a || "hello".contains("lo")"#, folded: "true"),
    InlineCase(
      "a + [a]",
      vars: [InlineVar("a", .dyn, alias: "alpha", expr: "dyn([1, 2])")],
      inlined: "cel.bind(alpha, dyn([1, 2]), alpha + [alpha])", folded: "[1, 2, [1, 2]]"),
    InlineCase(
      "a && (a || b)",
      vars: [InlineVar("a", .bool, alias: "alpha", expr: "'hello'.contains('lo')"), InlineVar("b", .bool)],
      inlined: #"cel.bind(alpha, "hello".contains("lo"), alpha && (alpha || b))"#, folded: "true"),
    InlineCase(
      "a && b && a",
      vars: [InlineVar("a", .bool, alias: "alpha", expr: "'hello'.contains('lo')"), InlineVar("b", .bool)],
      inlined: #"cel.bind(alpha, "hello".contains("lo"), alpha && b && alpha)"#, folded: "cel.bind(alpha, true, alpha && b && alpha)"),
    InlineCase(
      "(c || d) || (a && (a || b))",
      vars: [InlineVar("a", .bool, alias: "alpha", expr: "'hello'.contains('lo')"), InlineVar("b", .bool), InlineVar("c", .bool), InlineVar("d", .bool, expr: "!false")],
      inlined: #"c || !false || cel.bind(alpha, "hello".contains("lo"), alpha && (alpha || b))"#, folded: "true"),
    InlineCase(
      "a && (a || b)",
      vars: [InlineVar("a", .bool), InlineVar("b", .bool, alias: "bravo", expr: "'hello'.contains('lo')")],
      inlined: #"a && (a || "hello".contains("lo"))"#, folded: "a"),
    InlineCase(
      "a && b",
      vars: [InlineVar("a", .bool, alias: "alpha", expr: "!'hello'.contains('lo')"), InlineVar("b", .bool, alias: "bravo")],
      inlined: #"!"hello".contains("lo") && b"#, folded: "false"),
    InlineCase(
      "operation.system.consumers + operation.destination_consumers",
      vars: [InlineVar("operation.system", .dyn), InlineVar("operation.destination_consumers", .list(.int), expr: "productsToConsumers(operation.destination_products)"), InlineVar("operation.destination_products", .list(.int), expr: "operation.system.products")],
      inlined: "operation.system.consumers + productsToConsumers(operation.system.products)", folded: "operation.system.consumers + productsToConsumers(operation.system.products)"),
  ]

  static let multiStageCases: [InlineCase] = [
    InlineCase(
      "has(a.b)",
      declarations: [("a", .map(key: .string, value: .string))],
      vars: [InlineVar("a.b", .string, alias: "alpha", expr: "a.b_long")],
      inlined: "has(a.b_long)", folded: "has(a.b_long)"),
    InlineCase(
      "has(a.b) ? a.b : 'default'",
      declarations: [("a", .map(key: .string, value: .string))],
      vars: [InlineVar("a.b", .string, alias: "alpha", expr: "'hello'")],
      inlined: #"cel.bind(alpha, "hello", (alpha.size() != 0) ? alpha : "default")"#, folded: #""hello""#),
    InlineCase(
      "has(a.b) ? a.b : ['default']",
      declarations: [("a", .map(key: .string, value: .list(.string)))],
      vars: [InlineVar("a.b", .string, alias: "alpha", expr: "['hello']")],
      inlined: #"cel.bind(alpha, ["hello"], (alpha.size() != 0) ? alpha : ["default"])"#, folded: #"["hello"]"#),
    InlineCase(
      "0 in msg.map_int64_nested_type",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("nested_map", .map(key: .int, value: .object("google.expr.proto3.test.NestedTestAllTypes")))],
      vars: [InlineVar("msg.map_int64_nested_type", .map(key: .int, value: .object("google.expr.proto3.test.NestedTestAllTypes")), expr: "nested_map")],
      inlined: "0 in nested_map", folded: "0 in nested_map"),
    InlineCase(
      "has(msg.single_any)",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("unpacked_wrapper", .wrapper(.string))],
      vars: [InlineVar("msg.single_any", .wrapper(.string), expr: "unpacked_wrapper")],
      inlined: "unpacked_wrapper != null", folded: "unpacked_wrapper != null"),
    InlineCase(
      "has(msg.single_any) ? msg.single_any : '10'",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("unpacked_wrapper", .wrapper(.string))],
      vars: [InlineVar("msg.single_any", .wrapper(.string), alias: "wrapped", expr: "unpacked_wrapper")],
      inlined: #"cel.bind(wrapped, unpacked_wrapper, (wrapped != null) ? wrapped : "10")"#, folded: #"cel.bind(wrapped, unpacked_wrapper, (wrapped != null) ? wrapped : "10")"#),
    InlineCase(
      "has(msg.child.payload.single_int32_wrapper)",
      declarations: [("msg", .object("google.expr.proto3.test.NestedTestAllTypes")), ("unpacked_child", .object("google.expr.proto3.test.NestedTestAllTypes"))],
      vars: [InlineVar("msg.child.payload", .object("google.expr.proto3.test.NestedTestAllTypes"), alias: "payload", expr: "unpacked_child.payload")],
      inlined: "has(unpacked_child.payload.single_int32_wrapper)", folded: "has(unpacked_child.payload.single_int32_wrapper)"),
    InlineCase(
      "has(msg.child.payload.single_int32_wrapper)",
      declarations: [("msg", .object("google.expr.proto3.test.NestedTestAllTypes")), ("unpacked_payload", .object("google.expr.proto3.test.TestAllTypes"))],
      vars: [InlineVar("msg.child.payload.single_int32_wrapper", .wrapper(.int), alias: "payload", expr: "unpacked_payload.single_int32_wrapper")],
      inlined: "has(unpacked_payload.single_int32_wrapper)", folded: "has(unpacked_payload.single_int32_wrapper)"),
    InlineCase(
      "has(msg.child.payload.single_int32_wrapper) ? msg.child.payload.single_int32_wrapper : 1",
      declarations: [("msg", .object("google.expr.proto3.test.NestedTestAllTypes")), ("unpacked_payload", .object("google.expr.proto3.test.TestAllTypes"))],
      vars: [InlineVar("msg.child.payload.single_int32_wrapper", .wrapper(.int), alias: "nullable_int", expr: "unpacked_payload.single_int32_wrapper")],
      inlined: "cel.bind(nullable_int, unpacked_payload.single_int32_wrapper, (nullable_int != null) ? nullable_int : 1)", folded: "cel.bind(nullable_int, unpacked_payload.single_int32_wrapper, (nullable_int != null) ? nullable_int : 1)"),
    InlineCase(
      "has(msg.single_value) ? msg.single_value : null",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes"))],
      vars: [InlineVar("msg.single_value", .wrapper(.double), alias: "nullable_float", expr: "dyn(1.5)")],
      inlined: "cel.bind(nullable_float, dyn(1.5), (nullable_float != null) ? nullable_float : null)", folded: "1.5"),
    InlineCase(
      "has(msg.single_any) ? msg.single_any : 42",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes"))],
      vars: [InlineVar("msg.single_any", .int, alias: "unpacked_nested", expr: "proto3.test.NestedTestAllTypes{}.payload.single_int32")],
      inlined: "has(google.expr.proto3.test.NestedTestAllTypes{}.payload.single_int32) ? google.expr.proto3.test.NestedTestAllTypes{}.payload.single_int32 : 42", folded: "42"),
    InlineCase(
      "has(msg.single_any.processing_purpose)",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("unpacked_purpose", .list(.int))],
      vars: [InlineVar("msg.single_any.processing_purpose", .list(.int), alias: "unpacked_purpose", expr: "[1, 2, 3].map(i, i * 2)")],
      inlined: "[1, 2, 3].map(i, i * 2).size() != 0", folded: "true"),
    InlineCase(
      "has(msg.single_any.processing_purpose) ? msg.single_any.processing_purpose[0] : 42",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("unpacked_purpose", .list(.int))],
      vars: [InlineVar("msg.single_any.processing_purpose", .list(.int), alias: "unpacked_purpose", expr: "[1, 2, 3].map(i, i * 2)")],
      inlined: "cel.bind(unpacked_purpose, [1, 2, 3].map(i, i * 2), (unpacked_purpose.size() != 0) ? (unpacked_purpose[0]) : 42)", folded: "2"),
    InlineCase(
      "has(msg.single_any.processing_purpose) ? msg.single_any.processing_purpose.map(i, i * 2)[0] : 42",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("unpacked_purpose", .list(.int))],
      vars: [InlineVar("msg.single_any.processing_purpose", .list(.int), alias: "unpacked_purpose", expr: "[1, 2, 3].map(i, i * 2)")],
      inlined: "cel.bind(unpacked_purpose, [1, 2, 3].map(i, i * 2), (unpacked_purpose.size() != 0) ? (unpacked_purpose.map(i, i * 2)[0]) : 42)", folded: "4"),
    InlineCase(
      "msg.single_any.processing_purpose.filter(j, j < msg.single_any.processing_purpose.size()) == [2]",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("unpacked_purpose", .list(.int))],
      vars: [InlineVar("msg.single_any.processing_purpose", .list(.int), alias: "unpacked_purpose", expr: "[1, 2, 3].map(i, i * 2)")],
      inlined: "cel.bind(unpacked_purpose, [1, 2, 3].map(i, i * 2), unpacked_purpose.filter(j, j < unpacked_purpose.size())) == [2]", folded: "true"),
    InlineCase(
      "has(msg.single_any.listA) && msg.single_any.listB.size() > 0 && msg.single_any.listB.all(b, b == msg.single_any.listA[0]) && msg.single_any.listA.all(a, a == msg.single_any.listB[0])",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("listA", .list(.int)), ("listB", .list(.int))],
      vars: [InlineVar("msg.single_any.listA", .list(.int), alias: "listA", expr: "[1, 1]"), InlineVar("msg.single_any.listB", .list(.int), alias: "listB", expr: "[1, 1, 1]")],
      inlined: "cel.bind(listA, [1, 1], cel.bind(listB, [1, 1, 1], listA.size() != 0 && listB.size() > 0 &&\nlistB.all(b, b == listA[0]) && listA.all(a, a == listB[0])))", folded: "true"),
    InlineCase(
      "((msg.single_any.listB.all(b, b == msg.single_any.listA[0]) && msg.single_any.listA.all(a, a == msg.single_any.listB[0])) || msg.single_any.listA.size() == 0) || false",
      declarations: [("msg", .object("google.expr.proto3.test.TestAllTypes")), ("listA", .list(.int)), ("listB", .list(.int))],
      vars: [InlineVar("msg.single_any.listA", .list(.int), alias: "listA", expr: "[1, 1]"), InlineVar("msg.single_any.listB", .list(.int), alias: "listB", expr: "[1, 1, 1]")],
      inlined: "cel.bind(listA, [1, 1], cel.bind(listB, [1, 1, 1], listB.all(b, b == listA[0]) &&\nlistA.all(a, a == listB[0])) || listA.size() == 0) || false", folded: "true"),
    InlineCase(
      "has(m.child) && has(m.child.payload)",
      declarations: [("m", .object("google.expr.proto3.test.NestedTestAllTypes")), ("m_view", .map(key: .string, value: .object("google.expr.proto3.test.NestedTestAllTypes")))],
      vars: [InlineVar("m.child", .object("google.expr.proto3.test.NestedTestAllTypes"), alias: "child", expr: "m_view.nested.child")],
      inlined: "has(m_view.nested.child) && has(m_view.nested.child.payload)", folded: "has(m_view.nested.child) && has(m_view.nested.child.payload)"),
  ]
}

// Ported from cel-go cel/cel_test.go against the public API (package-level AST access only where
// cel-go reads the native AST: reference maps, macro calls, expression ids).
//
// Not ported, with the reason:
// - TestCompile: there is no one-shot `Compile(expr, opts...)` helper.
// - TestAbbrevsDisambiguation, TestCustomTypes, TestEnvExtension, TestParseAndCheckConcurrently
//   (with exprpb), TestTypeIsolation, TestDynamicProto*, TestContextProto*: need
//   google.api.expr.v1alpha1 messages, descriptor sets or dynamic messages; CELProtobuf only
//   adapts generated messages.
// - TestConvertToNativeJSONStructure, TestAstIsChecked, TestParseWithMacroTracking's exprpb half:
//   no ConvertToNative or proto conversion of ASTs (an open API decision).
// - TestCustomMacro, TestMacroInterop, TestMacroModern, TestCustomExistsMacro,
//   TestCustomInterpreterDecorator*: custom macros and decorators need the public AST (open).
// - TestEvalRecover: Swift cannot recover from a trap in a function binding.
// - TestVariadicLogicalOperators: uses an unexported cel-go option.
// - TestDefaultUTCTimeZone "disabled" rows: DefaultUTCTimeZone(false) is not ported (deprecated).
// - TestJSONFieldNames, TestJSONFieldNamesInvalidProvider: JSON names are covered by
//   CELProtobufTests; the provider-wrapping error has no counterpart.
// - TestAstProgramNilValue, TestResidualAstNil, TestProgramEvalInvalidInput,
//   TestProgramContextEvalInvalidInput, TestOptionalOperatorsLegacyEval: nil and untyped inputs
//   cannot be expressed; the legacy interpretables do not exist.
// - The custom cost estimator and tracker parts of TestEval / TestEstimateCostAndRuntimeCost /
//   TestCostLimit: the public API takes size hints instead of estimator objects.

import CEL
import CELGoTestProtos
import CELProtobuf
import Testing

/// Go `bytes.Contains`.
private func bytesContain(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
  if needle.isEmpty {
    return true
  }
  guard haystack.count >= needle.count else {
    return false
  }
  for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
    return true
  }
  return false
}

/// cel-go `compileOrError` + `Eval`: compiles with `OptOptimize` and evaluates.
private func interpret(_ env: Environment, _ expr: String, _ variables: Variables = [:]) throws -> Value {
  try env.program(env.compile(expr), options: [.optimize]).evaluate(variables).value
}

@Suite("cel_test.go")
struct APICelTests {
  @Test func exampleWithBuiltins() throws {
    let env = try Environment(.variable("i", .string), .variable("you", .string))
    let checked = try env.compile(#""Hello " + you + "! I'm " + i + ".""#)
    let out = try env.program(checked).evaluate(["i": "CEL", "you": "world"]).value
    #expect(out == "Hello world! I'm CEL.")
  }

  @Test(arguments: [
    (#"value + " " + oldValue + " " + baseVar"#, ["value": "new", "oldValue": "old", "baseVar": "base"], Value("new old base")),
    ("size(value) > 0 && [1, 2, 3].exists(x, x > 2)", ["value": "test"], Value(true)),
  ] as [(String, [String: Value], Value)])
  func extendCheckerParity(_ expr: String, _ vars: [String: Value], _ want: Value) throws {
    let base = try Environment(.variable("baseVar", .string))
    let extended = try base.extending(.variable("value", .string), .variable("oldValue", .string))
    let flat = try Environment(.variable("baseVar", .string), .variable("value", .string), .variable("oldValue", .string))
    let extChecked = try extended.compile(expr)
    let flatChecked = try flat.compile(expr)
    #expect(extChecked.outputType == flatChecked.outputType)
    #expect(try extended.program(extChecked).evaluate(vars).value == want)
    #expect(try flat.program(flatChecked).evaluate(vars).value == want)
  }

  @Test func concurrentEvaluation() async throws {
    let env = try Environment(.variable("input", .list(.int)))
    let program = try env.program(
      env.compile("input.size() != 0"), options: [.optimize, .trackCost, .interruptCheckFrequency(100)])
    try await withThrowingTaskGroup(of: Value.self) { group in
      for _ in 0..<100 {
        group.addTask { try program.evaluate(["input": [1, 2, 3]]).value }
      }
      for try await value in group {
        #expect(value == true)
      }
    }
  }

  @Test func abbreviationsCompiled() throws {
    let env = try Environment(
      .abbreviations("qualified.identifier.name"), .variable("qualified.identifier.name.first", .string))
    #expect(try interpret(env, #""hello "+ name.first"#, ["qualified.identifier.name.first": "Jim"]) == "hello Jim")
  }

  @Test func abbreviationsParsed() throws {
    let env = try Environment(.abbreviations("qualified.identifier.name"))
    let parsed = try env.parse(#""hello " + name.first"#)
    let out = try env.program(parsed).evaluate(["qualified.identifier.name": ["first": "Jim"]]).value
    #expect(out == "hello Jim")
  }

  @Test func customEnvironment() throws {
    let doubled = try Environment.custom(.standardLibrary, .standardLibrary)
    #expect(throws: CompileError.self) { try doubled.compile("a.b.c == true") }

    let env = try Environment.custom(.variable("a.b.c", .bool))
    // Without the standard library there is no `==`.
    #expect(throws: CompileError.self) { try env.compile("a.b.c == true") }
    #expect(try interpret(env, "a.b.c", ["a.b.c": true]) == true)
  }

  @Test func crossTypeNumericComparisons() throws {
    let disabled = try Environment(.crossTypeNumericComparisons(false))
    #expect {
      try disabled.compile("1.0 < 2")
    } throws: { error in
      compareIgnoringWhitespace(
        "\(error)",
        """
        ERROR: <input>:1:5: found no matching overload for '_<_' applied to '(double, int)'
         | 1.0 < 2
         | ....^
        """)
    }
    let enabled = try Environment(.crossTypeNumericComparisons(true))
    #expect(try interpret(enabled, "1.0 < 2") == true)
    // Dynamic data already benefits from cross-type numeric comparisons.
    #expect(try interpret(disabled, "dyn(1.0) < 2") == true)
    #expect(try interpret(enabled, "dyn(1.0) < 2") == true)
  }

  @Test func extendStandardLibraryFunction() throws {
    let env = try Environment(
      .function(
        "contains",
        .memberOverload(
          "bytes_contains_bytes", argumentTypes: [.bytes, .bytes], resultType: .bool,
          .binaryBinding { haystack, needle in
            guard let h = haystack.asBytes, let n = needle.asBytes else { return .error(EvalError("bad")) }
            return Value(bytesContain(h, n))
          })))
    #expect(try interpret(env, "b'string'.contains(b'tri') && 'string'.contains('tri')") == true)
  }

  @Test func globalVariables() throws {
    let env = try Environment(
      .variable("attrs", .map(key: .string, value: .dyn)), .variable("default", .dyn),
      .function(
        "get",
        .memberOverload(
          "get_map", argumentTypes: [.map(key: .string, value: .dyn), .string, .dyn], resultType: .dyn,
          .functionBinding { args in
            guard let attrs = args[0].asMap, let key = args[1].asString else {
              return .error(EvalError("invalid operand of type '\(args[0])' to obj.get(key, def)"))
            }
            return attrs[.string(key)] ?? args[2]
          })))
    let program = try env.program(
      env.compile(#"attrs.get("first", attrs.get("second", default))"#),
      options: [.globals(["default": "shadow me"]), .globals(["default": "third"]), .globals([:])])
    #expect(throws: EvalError.self) { try program.evaluate(["attrs": ["one", "two"]]) }
    #expect(try program.evaluate(["attrs": Value([String: Value]())]).value == "third")
    #expect(try program.evaluate(["attrs": ["second": "yep"]]).value == "yep")
    #expect(try program.evaluate(["attrs": Value([String: Value]()), "default": "fourth"]).value == "fourth")
  }

  @Test func exhaustiveEvaluation() throws {
    let env = try Environment(.variable("k", .string), .variable("v", .bool))
    let checked = try env.compile("{k: true}[k] || v != false")
    let result = try env.program(checked, options: [.exhaustiveEvaluation]).evaluate(["k": "key", "v": true])
    #expect(result.value == true)
    // With short-circuiting, `v != false` would not have been evaluated.
    let args = try #require(checked.ast.expr.asCall).args
    #expect(result.state?.value(ofExpressionID: args[0].id) == true)
    #expect(result.state?.value(ofExpressionID: args[1].id) == true)
  }

  @Test func interruptedEvaluation() throws {
    let env = try Environment(.variable("items", .list(.int)))
    let checked = try env.compile("items.map(i, i * 2).filter(i, i >= 50).size()")
    let items = Value((0..<2000).map { Value($0) })
    let program = try env.program(checked, options: [.optimize, .trackState, .interruptCheckFrequency(100)])
    #expect(try program.evaluate(["items": items]).value == 1975)
    let limited = try env.program(checked, options: [.optimize, .trackState, .timeLimit(.nanoseconds(1))])
    #expect {
      try limited.evaluate(["items": items])
    } throws: { error in
      "\(error)".contains("operation interrupted")
    }
  }

  @Test func evaluationIsRepeatable() throws {
    let env = try Environment(.variable("groups", .list(.int)), .variable("id", .int))
    let program = try env.program(
      env.compile("groups.exists(t, t == id)"), options: [.trackState, .partialEvaluation, .interruptCheckFrequency(100)])
    let variables = Variables(["groups": [1, 2, 3]], unknowns: [UnknownPattern("id")])
    let first = try program.evaluate(variables)
    let second = try program.evaluate(variables)
    #expect(first.value.asUnknown != nil)
    #expect(first.value.asUnknown == second.value.asUnknown)
  }

  // MARK: Residual ASTs

  @Test func residualAST() throws {
    let env = try Environment(.variable("x", .int), .variable("y", .int))
    let parsed = try env.parse("x < 10 && (y == 0 || 'hello' != 'goodbye')")
    let program = try env.program(parsed, options: [.trackState, .partialEvaluation])
    let result = try program.evaluate(env.partialVariables())
    #expect(result.value.asUnknown != nil)
    let state = try #require(result.state)
    #expect(try env.residual(of: parsed, state: state).description == "x < 10")
  }

  @Test func residualASTComplex() throws {
    let env = try Environment(
      .variable("resource.name", .string), .variable("request.time", .timestamp),
      .variable("request.auth.claims", .map(key: .string, value: .string)))
    let variables = Variables(
      ["resource.name": "bucket/my-bucket/objects/private", "request.auth.claims": ["email_verified": "true"]],
      unknowns: [UnknownPattern("request.auth.claims").qualified(by: "email")])
    let checked = try env.compile(
      """
      resource.name.startsWith("bucket/my-bucket") &&
      bool(request.auth.claims.email_verified) == true &&
      request.auth.claims.email == "wiley@acme.co"
      """)
    let result = try env.program(checked, options: [.trackState, .partialEvaluation]).evaluate(variables)
    #expect(result.value.asUnknown != nil)
    let residual = try env.residual(of: checked, state: try #require(result.state))
    #expect(residual.description == #"request.auth.claims.email == "wiley@acme.co""#)
  }

  @Test func residualASTMacros() throws {
    let env1 = try Environment(.variable("x", .list(.int)), .variable("y", .int), .macroCallTracking)
    let checked1 = try env1.compile("x.exists(i, i < 10) && [11, 12, 13].all(i, i in [y, 12, 13])")
    let result1 = try env1.program(checked1, options: [.trackState, .partialEvaluation])
      .evaluate(Variables(["y": 11], unknowns: [UnknownPattern("x")]))
    #expect(try env1.residual(of: checked1, state: try #require(result1.state)).description == "x.exists(i, i < 10)")

    let env2 = try Environment(
      .variable("bar", .map(key: .string, value: .dyn)), .variable("foo", .map(key: .string, value: .dyn)),
      .macroCallTracking)
    let checked2 = try env2.compile("foo.exists(t, t == bar.baz.x)")
    let result2 = try env2.program(checked2, options: [.trackState, .partialEvaluation])
      .evaluate(Variables(["foo": ["a": "b"]], unknowns: [UnknownPattern("bar").qualified(by: "baz").wildcard()]))
    #expect(
      try env2.residual(of: checked2, state: try #require(result2.state)).description
        == #"{"a": "b"}.exists(t, t == bar.baz.x)"#)
  }

  @Test func residualASTAttributeQualifiers() throws {
    let env = try Environment(
      .variable("x", .map(key: .string, value: .dyn)), .variable("y", .list(.int)), .variable("u", .int))
    let parsed = try env.parse(
      #"x.abc == u && x["abc"] == u && x[x.string] == u && y[0] == u && y[x.zero] == u && (true ? x : y).abc == u && (false ? y : x).abc == u"#
    )
    let program = try env.program(parsed, options: [.trackState, .partialEvaluation])
    let result = try program.evaluate(
      Variables(["x": ["zero": 0, "abc": 123, "string": "abc"], "y": [123]], unknowns: [UnknownPattern("u")]))
    #expect(result.value.asUnknown != nil)
    let residual = try env.residual(of: parsed, state: try #require(result.state))
    #expect(
      residual.description == "123 == u && 123 == u && 123 == u && 123 == u && 123 == u && 123 == u && 123 == u")
  }

  @Test func residualASTDoesNotModifyTheOriginal() throws {
    let env = try Environment(.variable("x", .map(key: .string, value: .int)), .variable("y", .int))
    let parsed = try env.parse("x == y")
    let program = try env.program(parsed, options: [.trackState, .partialEvaluation])
    for x in [123, 456] {
      let result = try program.evaluate(Variables(["x": Value(x)], unknowns: [UnknownPattern("y")]))
      #expect(result.value.asUnknown != nil)
      let residual = try env.residual(of: parsed, state: try #require(result.state))
      #expect(parsed.description == "x == y")
      #expect(residual.description == "\(x) == y")
    }
  }

  // MARK: Environments

  @Test func extensionIsolation() throws {
    let base = try Environment(
      .container("google.expr"), .variable("age", .int), .variable("gender", .string), .variable("country", .string))
    let env1 = try base.extending(
      .typeProvider(ProtobufTypes(files: [Google_Expr_Proto2_Test_TestAllTypes_CELFile])), .variable("name", .string))
    let env2 = try base.extending(
      .typeProvider(ProtobufTypes(files: [Google_Expr_Proto3_Test_TestAllTypes_CELFile])), .variable("group", .string))
    _ = try env2.compile("size(group) > 10 && !has(proto3.test.TestAllTypes{}.single_int32)")
    #expect(throws: CompileError.self) { try env2.compile("size(name) > 10") }
    #expect(throws: CompileError.self) { try env2.compile("!has(proto2.test.TestAllTypes{}.single_int32)") }
    _ = try env1.compile("size(name) > 10 && !has(proto2.test.TestAllTypes{}.single_int32)")
    #expect(throws: CompileError.self) { try env1.compile("size(group) > 10") }
    #expect(throws: CompileError.self) { try env1.compile("!has(proto3.test.TestAllTypes{}.single_int32)") }
  }

  @Test func parseAndCheckConcurrently() async throws {
    let env = try Environment(.variable("expr", .map(key: .string, value: .int)))
    try await withThrowingTaskGroup(of: CELType.self) { group in
      for i in 0..<10 {
        group.addTask { try env.compile("expr.id + \(i)").outputType }
      }
      for try await type in group {
        #expect(type == .int)
      }
    }
  }

  @Test func parseError() throws {
    #expect(throws: CompileError.self) { try Environment().parse("invalid & logical_and") }
  }

  @Test func parseWithMacroTracking() throws {
    let env = try Environment(.macroCallTracking)
    let parsed = try env.parse("has(a.b) && a.b.exists(c, c < 10)")
    let functions = Set(parsed.ast.sourceInfo.macroCalls.values.compactMap { $0.asCall?.function })
    #expect(parsed.ast.sourceInfo.macroCalls.count == 2)
    #expect(functions == ["has", "exists"])
  }

  // MARK: Cost

  @Test(arguments: [
    ("const", #""Hello World!""#, [], [:], 0...0, [:]),
    ("identity", "input", [("input", CELType.list(.int))], [:], 1...1, ["input": [1, 2]]),
    (
      "str concat", #""abcdefg".contains(str1 + str2)"#, [("str1", .string), ("str2", .string)],
      ["str1": 0...10, "str2": 0...10], 2...6, ["str1": "val1111111", "str2": "val2222222"]
    ),
  ] as [(String, String, [(String, CELType)], [String: ClosedRange<UInt64>], ClosedRange<UInt64>, [String: Value])])
  func estimateCostAndRuntimeCost(
    _ name: String, _ expr: String, _ decls: [(String, CELType)], _ hints: [String: ClosedRange<UInt64>],
    _ want: ClosedRange<UInt64>, _ vars: [String: Value]
  ) throws {
    let env = try Environment(options: decls.map { .variable($0.0, $0.1) })
    let checked = try env.compile(expr)
    let estimate = env.estimateCost(checked, sizeHints: hints)
    #expect(estimate == want, "\(name)")
    let cost = try #require(try env.program(checked, options: [.trackCost]).evaluate(vars).cost)
    #expect(estimate.contains(cost), "\(name)")
  }

  @Test func costLimit() throws {
    let env = try Environment(.variable("val1", .int), .variable("val2", .int))
    let checked = try env.compile("val1 > val2")
    let estimate = env.estimateCost(checked)
    let within = try env.program(checked, options: [.costLimit(10)]).evaluate(["val1": 1, "val2": 2])
    #expect(estimate.contains(try #require(within.cost)))
    #expect {
      try env.program(checked, options: [.costLimit(0)]).evaluate(["val1": 1, "val2": 2])
    } throws: { error in
      "\(error)".contains("actual cost limit exceeded")
    }
  }

  @Test func costTrackingIsConsistentAcrossEvaluations() throws {
    let env = try Environment(.variable("val1", .int), .variable("val2", .int))
    let program = try env.program(env.compile("val1 + val2"), options: [.trackCost])
    let first = try program.evaluate(["val1": 1, "val2": 2]).cost
    let second = try program.evaluate(["val1": 1, "val2": 2]).cost
    #expect(first != nil)
    #expect(first == second)
  }

  @Test func costTrackingWithStateTracking() throws {
    let env = try Environment(.variable("a", .string))
    let checked = try env.compile(#"a.startsWith("x") && a.contains("yz")"#)
    func run(_ options: [Program.Option]) throws -> (cost: UInt64, hasState: Bool) {
      let result = try env.program(checked, options: options).evaluate(["a": "xyz-abcdefghij"])
      return (try #require(result.cost), !(result.state?.expressionIDs.isEmpty ?? true))
    }
    let baseline = try run([.trackCost])
    #expect(baseline.cost != 0)
    #expect(!baseline.hasState)
    for options in [[Program.Option.trackCost, .trackState], [.trackCost, .exhaustiveEvaluation]] {
      let tracked = try run(options)
      #expect(tracked.cost == baseline.cost)
      #expect(tracked.hasState)
    }
  }

  // MARK: Partial evaluation

  @Test func partialVariables() throws {
    let env = try Environment(.variable("x", .string), .variable("y", .int))
    let program = try env.program(env.compile("x == string(y)"), options: [.partialEvaluation])
    let unknownX = UnknownSet(expressionID: 1, attribute: AttributeTrail(variable: "x"))
    let unknownY = UnknownSet(expressionID: 4, attribute: AttributeTrail(variable: "y"))
    let both = unknownX.merging(unknownY)
    struct Case {
      var input: [String: Value]
      var unknowns: [String]
      var out: Value?
      var error: String?
      var partialOut: Value?
    }
    let cases: [Case] = [
      Case(input: [:], unknowns: ["x", "y"], out: .unknown(both)),
      Case(input: ["x": "10"], unknowns: ["y"], out: .unknown(unknownY)),
      Case(input: ["y": 10], unknowns: ["x"], out: .unknown(unknownX)),
      Case(input: ["x": "10", "y": 10], unknowns: [], out: true),
      Case(input: ["x": "10", "y": 9], unknowns: [], out: false),
      Case(input: ["y": 10], unknowns: [], error: "no such attribute", partialOut: .unknown(unknownX)),
      Case(input: ["x": "10"], unknowns: [], error: "no such attribute", partialOut: .unknown(unknownY)),
      Case(input: [:], unknowns: [], error: "no such attribute", partialOut: .unknown(both)),
    ]
    for c in cases {
      // Manually configured unknown patterns.
      let manual = Variables(c.input, unknowns: c.unknowns.map { UnknownPattern($0) })
      if let error = c.error {
        #expect {
          try program.evaluate(manual)
        } throws: { "\($0)".contains(error) }
      } else {
        #expect(try program.evaluate(manual).value == c.out)
      }
      // Inferred unknown patterns.
      #expect(try program.evaluate(env.partialVariables(c.input)).value == (c.partialOut ?? c.out))
    }
  }

  @Test func partialVariablesFromEnvironment() throws {
    let env = try Environment(.variable("x", .int), .variable("y", .int))
    let program = try env.program(env.compile("x == y"), options: [.partialEvaluation])
    #expect(try program.evaluate(env.partialVariables(["x": 1, "y": 1])).value == true)

    let extended = try env.extending(.variable("z", .int))
    let extendedProgram = try extended.program(extended.compile("x == y && y == z"), options: [.partialEvaluation])
    let result = try extendedProgram.evaluate(extended.partialVariables(["z": 1, "y": 1]))
    #expect(result.value == .unknown(UnknownSet(expressionID: 1, attribute: AttributeTrail(variable: "x"))))
  }

  // MARK: Regular expressions

  @Test(arguments: [
    (#""123 abc 456".matches('[0-9]*')"#, false, nil, nil),
    (#""123 abc 456".matches('[0-9]' + '*')"#, false, nil, nil),
    (#""123 abc 456".matches('[0-9]*')"#, true, nil, nil),
    (#""123 abc 456".matches('[0-9]' + '*')"#, true, nil, nil),
    (#""123 abc 456".matches(')[0-9]*')"#, true, "error parsing regexp: unexpected ): `)[0-9]*`", nil),
    (#""123 abc 456".matches(')[0-9]*')"#, false, nil, "error parsing regexp: unexpected ): `)[0-9]*`"),
  ] as [(String, Bool, String?, String?)])
  func regexOptimizer(_ expr: String, _ optimize: Bool, _ programError: String?, _ evalError: String?) throws {
    let env = try Environment()
    let parsed = try env.parse(expr)
    let checked = try env.check(parsed)
    let options: [Program.Option] = optimize ? [.optimize] : []
    for makeProgram in [{ try env.program(parsed, options: options) }, { try env.program(checked, options: options) }] {
      if let programError {
        #expect {
          try makeProgram()
        } throws: { "\($0)".contains(programError) }
        continue
      }
      let program = try makeProgram()
      if let evalError {
        #expect {
          try program.evaluate()
        } throws: { "\($0)" == evalError }
      } else {
        #expect(try program.evaluate().value == true)
      }
    }
  }

  @Test func regexProgramSizeLimit() throws {
    let env = try Environment(.variable("pattern", .string), .regexProgramSizeLimit(5))
    #expect {
      try env.compile(#""123 abc 456".matches('(a|b)*[0-9]+')"#)
    } throws: { "\($0)".contains("regex program size 8 exceeds limit of 5") }
    let program = try env.program(env.compile(#""123 abc 456".matches(pattern)"#))
    #expect {
      try program.evaluate(["pattern": "(a|b)*[0-9]+"])
    } throws: { "\($0)".contains("regex program size 8 exceeds limit of 5") }
    #expect(try program.evaluate(["pattern": "[0-9]+"]).value == true)
  }

  // MARK: Time zones

  static let localTimestamp = Value.timestamp(
    CELTimestamp(secondsSinceEpoch: 7506, nanoseconds: 1_000_000, utcOffsetSeconds: -8 * 3600))

  @Test(arguments: [
    (
      """
      x.getFullYear() == 1970 && x.getMonth() == 0 && x.getDayOfYear() == 0 && x.getDayOfMonth() == 0
      && x.getDate() == 1 && x.getDayOfWeek() == 4 && x.getHours() == 2 && x.getMinutes() == 5
      && x.getSeconds() == 6 && x.getMilliseconds() == 1
      """, Value(true)
    ),
    ("x.getFullYear()", Value(1970)),
    ("x.getDayOfYear()", Value(0)),
    ("x.getMonth()", Value(0)),
    ("x.getDayOfMonth() == 30 && x.getDate() == 31", Value(false)),
    ("x.getDayOfWeek()", Value(4)),
    ("x.getHours() == 18 && x.getMinutes() == 5 && x.getSeconds() == 6 && x.getMilliseconds() == 1", Value(false)),
    (
      """
      x.getFullYear('-07:30') == 1969 && x.getDayOfYear('-07:30') == 364 && x.getMonth('-07:30') == 11
      && x.getDayOfMonth('-07:30') == 30 && x.getDate('-07:30') == 31 && x.getDayOfWeek('-07:30') == 3
      && x.getHours('-07:30') == 18 && x.getMinutes('-07:30') == 35 && x.getSeconds('-07:30') == 6
      && x.getMilliseconds('-07:30') == 1 && x.getFullYear('23:15') == 1970 && x.getDayOfYear('23:15') == 1
      && x.getMonth('23:15') == 0 && x.getDayOfMonth('23:15') == 1 && x.getDate('23:15') == 2
      && x.getDayOfWeek('23:15') == 5 && x.getHours('23:15') == 1 && x.getMinutes('23:15') == 20
      && x.getSeconds('23:15') == 6 && x.getMilliseconds('23:15') == 1
      """, Value(true)
    ),
  ] as [(String, Value)])
  func defaultUTCTimeZone(_ expr: String, _ want: Value) throws {
    let env = try Environment(.variable("x", .timestamp))
    #expect(try interpret(env, expr, ["x": Self.localTimestamp]) == want)
  }

  @Test func defaultUTCTimeZoneInExtendedEnvironment() throws {
    let env = try Environment(.variable("x", .timestamp), .variable("y", .duration)).extending()
    // cel-go expects y.getMilliseconds() == 7235000; the spec's milliseconds portion is 0
    // (docs/divergences.md).
    let out = try interpret(
      env,
      """
      x.getFullYear() == 1970 && y.getHours() == 2 && y.getMinutes() == 120 && y.getSeconds() == 7235
      && y.getMilliseconds() == 0
      """,
      ["x": Self.localTimestamp, "y": .duration(CELDuration(nanoseconds: 7235 * 1_000_000_000))])
    #expect(out == true)
  }

  @Test func invalidTimeZones() throws {
    let env = try Environment(.variable("x", .timestamp))
    #expect(throws: EvalError.self) {
      try interpret(
        env,
        """
        x.getFullYear(':xx') == 1969 || x.getDayOfYear('xx:') == 364 || x.getMonth('Am/Ph') == 11
        || x.getDayOfMonth('Am/Ph') == 30 || x.getDate('Am/Ph') == 31 || x.getDayOfWeek('Am/Ph') == 3
        || x.getHours('Am/Ph') == 19 || x.getMinutes('Am/Ph') == 5 || x.getSeconds('Am/Ph') == 6
        || x.getMilliseconds('Am/Ph') == 1
        """, ["x": Self.localTimestamp])
    }
    let utc = Value.timestamp(CELTimestamp(secondsSinceEpoch: 7506))
    for zone in ["+24:00", "-24:00", "+99:00", "-50:30", "+00:99", "+05:-30"] {
      #expect(throws: EvalError.self, "\(zone)") { try interpret(env, "x.getHours('\(zone)') >= 0", ["x": utc]) }
    }
    #expect(try interpret(env, "x.getHours('23:15')", ["x": utc]) == 1)
  }

  // MARK: Parser limits and syntax

  @Test(arguments: [
    ("0 + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11", nil),
    ("0 + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10", Value(55)),
    ("0 + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 == 45", nil),
    ("0 + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 == 0 + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9", Value(true)),
  ] as [(String, Value?)])
  func parserRecursionLimit(_ expr: String, _ want: Value?) throws {
    let env = try Environment(.parserRecursionLimit(10))
    if let want {
      #expect(try interpret(env, expr) == want)
    } else {
      #expect {
        try interpret(env, expr)
      } throws: { "\($0)".contains("max recursion depth exceeded") }
    }
  }

  @Test(arguments: [
    ("{'key-1': 64}.`key-1`", Value(64)),
    ("{'key-1': 64}.`key-2`", nil),
    ("has({'key-1': 64}.`key-1`)", Value(true)),
    ("has({'key-1': 64}.`key-2`)", Value(false)),
  ] as [(String, Value?)])
  func quotedFields(_ expr: String, _ want: Value?) throws {
    let env = try Environment(.parserRecursionLimit(10), .identifierEscapeSyntax())
    if let want {
      #expect(try interpret(env, expr) == want)
    } else {
      #expect {
        try interpret(env, expr)
      } throws: { "\($0)".contains("no such key: key-2") }
    }
  }

  @Test func dynamicDispatch() throws {
    func first(_ zero: Value) -> OverloadDecl.Option {
      .unaryBinding { list in list.asList?.first ?? zero }
    }
    let env = try Environment(
      .homogeneousAggregateLiterals,
      .function(
        "first",
        .memberOverload("first_list_int", argumentTypes: [.list(.int)], resultType: .int, first(0)),
        .memberOverload("first_list_double", argumentTypes: [.list(.double)], resultType: .double, first(0.0)),
        .memberOverload("first_list_string", argumentTypes: [.list(.string)], resultType: .string, first("")),
        .memberOverload(
          "first_list_list_string", argumentTypes: [.list(.list(.string))], resultType: .list(.string), first([]))))
    let out = try interpret(
      env,
      """
      dyn([]).first() == 0
      && [1, 2].first() == 1
      && [1.0, 2.0].first() == 1.0
      && ["hello", "world"].first() == "hello"
      && [["hello"], ["world", "!"]].first().first() == "hello"
      && [[], ["empty"]].first().first() == ""
      && dyn([1, 2]).first() == 1
      && dyn([1.0, 2.0]).first() == 1.0
      && dyn(["hello", "world"]).first() == "hello"
      && dyn([["hello"], ["world", "!"]]).first().first() == "hello"
      """)
    #expect(out == true)
  }

  @Test func parserExpressionSizeLimit() throws {
    let env = try Environment(.expressionSizeLimit(10))
    _ = try env.parse("'greeting'")
    #expect {
      try env.parse("'greetings'")
    } throws: { "\($0)".contains("size exceeds limit") }
  }

  @Test(arguments: [
    ("x.optMap(a, a + 1)", 500, nil),
    (
      "x.optMap(a, a + 1).optMap(b, b + 1).optMap(c, c + 1).optMap(d, d + 1).optMap(e, e + 1).optMap(f, f + 1)", 100,
      "expression count exceeds limit of 100 while expanding macro 'optMap'"
    ),
    (
      "x.optMap(a, [a, a]).optMap(b, {b: b}).optMap(c, c + 1).optMap(d, d + 2).optMap(e, e + 3).optMap(f, f + 4).optMap(g, g + 5).optMap(h, h + 6).optMap(i, i + 7).optMap(j, j + 8).optMap(k, k + 9).optMap(l, l + 10).optMap(m, m + 11).optMap(n, n + 12)",
      200, "expression count exceeds limit of 200 while expanding macro 'optMap'"
    ),
    (
      "x.optMap(a, a + 1).optMap(b, b + 1).optMap(c, c + 1).optMap(d, d + 1).optMap(e, e + 1).optMap(f, f + 1)", -1,
      nil
    ),
  ] as [(String, Int, String?)])
  func expressionNodeLimit(_ expr: String, _ limit: Int, _ error: String?) throws {
    let env = try Environment(.optionalTypes, .variable("x", .optional(.int)), .expressionNodeLimit(limit))
    if let error {
      #expect {
        try env.parse(expr)
      } throws: { "\($0)".contains(error) }
    } else {
      _ = try env.parse(expr)
    }
  }

  @Test func expressionNodeLimitWhenChecking() throws {
    let env = try Environment(.expressionNodeLimit(5), .variable("x", .int))
    let parseEnv = try Environment(.expressionNodeLimit(-1), .variable("x", .int))
    let parsed = try parseEnv.parse("x + 1 + 2 + 3 + 4 + 5")
    #expect {
      try env.check(parsed)
    } throws: { "\($0)".contains("expression node count exceeds limit") }
  }

  @Test func expressionSizeLimitIsEnforcedEarly() throws {
    let env = try Environment(.expressionSizeLimit(1000))
    let payload = String(repeating: "a", count: 10_000_000)
    #expect {
      try env.compile(payload)
    } throws: { "\($0)".contains("expression code point size exceeds limit") }
    #expect {
      try env.parse(payload)
    } throws: { "\($0)".contains("expression code point size exceeds limit") }
  }

  // MARK: Optionals

  @Test(arguments: [
    ("x.or(optional.of(y)).orValue(42)", [1: "x", 2: "optional_or_optional", 4: "optional_of", 5: "y", 6: "optional_orValue_value"]),
    ("m.?x.hasValue()", [1: "m", 3: "select_optional_field", 4: "optional_hasValue"]),
    ("has(m.?x.y)", [2: "m", 4: "select_optional_field"]),
    ("m.k[?'dashed-index'].orValue('default value')", [1: "m", 3: "map_optindex_optional_value", 5: "optional_orValue_value"]),
    ("l[?y]", [1: "l", 2: "list_optindex_optional_int", 3: "y"]),
    ("optm.c['index'].orValue('default value')", [1: "optm", 3: "optional_map_index_value", 5: "optional_orValue_value"]),
    ("optm.c[?'index']", [1: "optm", 3: "optional_map_optindex_optional_value"]),
    ("optl[0]", [1: "optl", 2: "optional_list_index_int"]),
    ("optl[?0]", [1: "optl", 2: "optional_list_optindex_optional_int"]),
  ] as [(String, [Int64: String])])
  func optionalValuesCompile(_ expr: String, _ references: [Int64: String]) throws {
    let env = try Environment(
      .optionalTypes,
      .variable("m", .map(key: .string, value: .map(key: .string, value: .string))),
      .variable("optm", .optional(.map(key: .string, value: .map(key: .string, value: .string)))),
      .variable("l", .list(.string)), .variable("optl", .optional(.list(.string))),
      .variable("x", .optional(.int)), .variable("y", .int))
    let checked = try env.compile(expr)
    #expect(checked.ast.referenceMap.count == references.count)
    for (id, reference) in checked.ast.referenceMap {
      let want = try #require(references[id], "unexpected reference at \(id): \(reference)")
      if reference.overloadIDs.isEmpty {
        #expect(reference.name == want)
      } else {
        #expect(reference.overloadIDs == [want])
      }
    }
  }

  static let optionalEnvironment: Environment = {
    do {
      return try Environment(
        .optionalTypes,
        .variable("m", .map(key: .string, value: .map(key: .string, value: .string))),
        .variable("l", .list(.string)),
        .variable("optm", .optional(.map(key: .string, value: .map(key: .string, value: .string)))),
        .variable("optl", .optional(.list(.string))),
        .variable("x", .optional(.int)), .variable("y", .optional(.int)), .variable("z", .int))
    } catch {
      fatalError("\(error)")
    }
  }()

  struct OptionalCase: Sendable, CustomTestStringConvertible {
    var expr: String
    var input: [String: Value] = [:]
    var out: Value?
    var error: String?
    var testDescription: String { expr }
  }

  static let none = Value(optional: nil)
  static let optionalCases: [OptionalCase] = [
    OptionalCase(expr: "has({'foo': optional.none()}.foo)", out: true),
    OptionalCase(expr: "has({'foo': optional.none()}.foo.value)", out: false),
    OptionalCase(expr: "has({?'foo': optional.none()}.foo)", out: false),
    OptionalCase(expr: "has({?'foo': optional.none()}.foo.value)", error: "no such key: foo"),
    OptionalCase(expr: "{}.?invalid", out: none),
    OptionalCase(expr: "{'null_field': dyn(null)}.?null_field", out: Value(optional: .null)),
    OptionalCase(expr: "{'null_field': dyn(null)}.?null_field.?nested", out: none),
    OptionalCase(expr: "{'zero_field': dyn(0)}.?zero_field.?invalid", out: none),
    OptionalCase(expr: "{0: dyn(0)}[?0].?invalid", out: none),
    OptionalCase(expr: "{true: dyn(0)}[?false].?invalid", out: none),
    OptionalCase(expr: "{true: dyn(0)}[?true].?invalid", out: none),
    OptionalCase(expr: "x.or(y).orValue(z)", input: ["x": none, "y": none, "z": 42], out: 42),
    OptionalCase(expr: "x.optMap(y, y + 1)", input: ["x": none], out: none),
    OptionalCase(expr: "m.?key.optFlatMap(k, k.?subkey)", input: ["m": Value([String: Value]())], out: none),
    OptionalCase(expr: "m.?key.optFlatMap(k, k.?subkey)", input: ["m": ["key": Value([String: Value]())]], out: none),
    OptionalCase(
      expr: "m.?key.optFlatMap(k, k.?subkey)", input: ["m": ["key": ["subkey": "subvalue"]]],
      out: Value(optional: "subvalue")),
    OptionalCase(expr: "m.?key.optFlatMap(k, k.?subkey)", input: ["m": ["key": ["subkey": ""]]], out: Value(optional: "")),
    OptionalCase(
      expr: "m.?key.optFlatMap(k, optional.ofNonZeroValue(k.subkey))", input: ["m": ["key": ["subkey": ""]]], out: none),
    OptionalCase(expr: "x.optMap(y, y + 1)", input: ["x": Value(optional: 42)], out: Value(optional: 43)),
    OptionalCase(expr: "{0: 10}[?0].optMap(v, v + 1)", out: Value(optional: 11)),
    OptionalCase(expr: "{0: 10}[?0].optMap(a, a + 1).optMap(b, b * 2)", out: Value(optional: 22)),
    OptionalCase(expr: "{0: 10}[?1].optMap(a, a + 1).optMap(b, b * 2)", out: none),
    OptionalCase(expr: "optional.ofNonZeroValue(z).or(optional.of(10)).value() == 42", input: ["z": 42], out: true),
    OptionalCase(
      expr: "(has(m.x) ? optional.of(m.x) : optional.none()).hasValue()", input: ["m": Value([String: Value]())], out: false),
    OptionalCase(expr: "m.?x.hasValue()", input: ["m": Value([String: Value]())], out: false),
    OptionalCase(expr: "has(m.?x.y)", input: ["m": Value([String: Value]())], out: false),
    OptionalCase(expr: "has(m.?x.y)", input: ["m": ["x": ["y": "z"]]], out: true),
    OptionalCase(expr: "type(optional.none()) == optional_type", out: true),
    OptionalCase(
      expr: "optional.ofNonZeroValue('').or(optional.of(m.c['dashed-index'])).orValue('default value')",
      input: ["m": ["c": ["dashed-index": "goodbye"]]], out: "goodbye"),
    OptionalCase(
      expr: "m.c[?'dashed-index'].orValue('default value')", input: ["m": ["c": ["dashed-index": "goodbye"]]],
      out: "goodbye"),
    OptionalCase(
      expr: "m.c[?'missing-index'].orValue('default value')", input: ["m": ["c": Value([String: Value]())]],
      out: "default value"),
    OptionalCase(
      expr: "optm.c.index.orValue('default value')", input: ["optm": Value(optional: ["c": ["index": "goodbye"]])],
      out: "goodbye"),
    OptionalCase(
      expr: "optm.c.missing.or(optl[0]).orValue('default value')",
      input: ["optm": Value(optional: ["c": Value([String: Value]())]), "optl": none], out: "default value"),
    OptionalCase(
      expr: "optm.c.missing.or(optl[0]).orValue('default value')",
      input: ["optm": Value(optional: ["c": Value([String: Value]())]), "optl": Value(optional: ["list-value"])],
      out: "list-value"),
    OptionalCase(
      expr: "optm.c['index'].orValue('default value')", input: ["optm": Value(optional: ["c": ["index": "goodbye"]])],
      out: "goodbye"),
    OptionalCase(
      expr: "optm.c['missing'].orValue('default value')", input: ["optm": Value(optional: ["c": Value([String: Value]())])],
      out: "default value"),
    OptionalCase(
      expr: "has(optm.c) && !has(optm.c.missing)", input: ["optm": Value(optional: ["c": ["entry": "hello world"]])],
      out: true),
    OptionalCase(
      expr: "optional.ofNonZeroValue(m.a.z).orValue(m.c['dashed-index'])",
      input: ["m": ["c": ["dashed-index": "goodbye"]]], error: "no such key: a"),
    OptionalCase(
      expr: "m.?c.missing.or(m.?c['dashed-index']).orValue('').size()",
      input: ["m": ["c": ["dashed-index": "goodbye"]]], out: 7),
    OptionalCase(
      expr: "{?'nested_map': optional.ofNonZeroValue({?'map': m.?c})}",
      input: ["m": ["c": ["dashed-index": "goodbye"]]], out: ["nested_map": ["map": ["dashed-index": "goodbye"]]]),
    OptionalCase(
      expr: "{?'nested_map': optional.ofNonZeroValue({?'map': m.?c}), 'singleton': true}",
      input: ["m": Value([String: Value]())], out: ["singleton": true]),
    OptionalCase(
      expr: "[?m.?c, ?x, ?y]", input: ["m": Value([String: Value]()), "x": Value(optional: 42), "y": none], out: [42]),
    OptionalCase(
      expr: "[?optional.ofNonZeroValue(m.?c.orValue({}))]", input: ["m": ["c": Value([String: Value]())]], out: []),
    OptionalCase(
      expr: "optional.ofNonZeroValue({?'nested_map': optional.ofNonZeroValue({?'map': m.?c})})",
      input: ["m": Value([String: Value]())], out: none),
    OptionalCase(expr: "[].first()", out: none),
    OptionalCase(expr: "['a','b','c'].first()", out: Value(optional: "a")),
    OptionalCase(expr: "[].last()", out: none),
    OptionalCase(expr: "[1, 2, 3].last()", out: Value(optional: 3)),
    OptionalCase(expr: "optional.unwrap([])", out: []),
    OptionalCase(expr: "optional.unwrap([optional.none(), optional.none()])", out: []),
    OptionalCase(expr: #"optional.unwrap([optional.of(42), optional.none(), optional.of("a")])"#, out: [42, "a"]),
    OptionalCase(expr: #"optional.unwrap([optional.of(42), optional.of("a")])"#, out: [42, "a"]),
    OptionalCase(expr: "[].unwrapOpt()", out: []),
    OptionalCase(expr: "[optional.none(), optional.none()].unwrapOpt()", out: []),
    OptionalCase(expr: #"[optional.of(42), optional.none(), optional.of("a")].unwrapOpt()"#, out: [42, "a"]),
    OptionalCase(expr: #"[optional.of(42), optional.of("a")].unwrapOpt()"#, out: [42, "a"]),
    OptionalCase(expr: "optional.of(optional.of(1)) != dyn(optional.of(1))", out: true),
    OptionalCase(expr: "(true ? optional.of(optional.of(1)) : dyn(optional.of(2))) != dyn(optional.of(1))", out: true),
  ]

  @Test(arguments: optionalCases)
  func optionalValuesEval(_ testCase: OptionalCase) throws {
    let env = Self.optionalEnvironment
    let program = try env.program(env.compile(testCase.expr))
    if let error = testCase.error {
      #expect {
        try program.evaluate(testCase.input)
      } throws: { "\($0)" == error }
      return
    }
    let out = try program.evaluate(testCase.input).value
    let want = try #require(testCase.out)
    #expect(out.celEquals(want) == true, "got \(out), want \(want)")
  }

  @Test(arguments: [
    (["y": none, "z": 42], Value.unknown(UnknownSet(expressionID: 1, attribute: AttributeTrail(variable: "x")))),
    (["x": none, "y": none], Value.unknown(UnknownSet(expressionID: 5, attribute: AttributeTrail(variable: "z")))),
    (["x": Value(optional: 1), "y": none], Value(1)),
    (["x": none, "y": Value(optional: 1)], Value(1)),
  ] as [([String: Value], Value)])
  func optionalValuesEvalUnknowns(_ input: [String: Value], _ want: Value) throws {
    let env = try Environment(
      .optionalTypes, .variable("x", .optional(.int)), .variable("y", .optional(.int)), .variable("z", .int))
    let program = try env.program(env.compile("x.or(y).orValue(z)"), options: [.partialEvaluation])
    #expect(try program.evaluate(env.partialVariables(input)).value == want)
  }

  @Test(arguments: [
    ("dyn(1).or(optional.of(2))", "no such overload"),
    ("dyn(1).orValue(2)", "no such overload"),
    ("optional.of(1/0).or(optional.of(2))", "division by zero"),
    ("optional.of(1/0).orValue(2)", "division by zero"),
  ])
  func optionalValuesEvalErrors(_ expr: String, _ error: String) throws {
    let env = try Environment(.optionalTypes, .variable("x", .optional(.int)), .variable("z", .int))
    let program = try env.program(env.compile(expr))
    #expect {
      try program.evaluate()
    } throws: { "\($0)".contains(error) }
  }

  @Test(arguments: [
    ("{}.?invalid", none, nil),
    ("{'null_field': dyn(null)}.?null_field", Value(optional: .null), nil),
    ("{'null_field': dyn(null)}.?null_field.?nested", nil, "no such key: nested"),
    ("{'zero_field': dyn(0)}.?zero_field.?invalid", nil, "no such key: invalid"),
    ("{0: dyn(0)}[?0].?invalid", nil, "no such key: invalid"),
    ("{true: dyn(0)}[?false].?invalid", none, nil),
    ("{true: dyn(0)}[?true].?invalid", nil, "no such key: invalid"),
  ] as [(String, Value?, String?)])
  func errorOnBadPresenceTest(_ expr: String, _ want: Value?, _ error: String?) throws {
    let env = try Environment(.optionalTypes, .errorOnBadPresenceTest(true))
    let program = try env.program(env.compile(expr))
    if let error {
      #expect {
        try program.evaluate()
      } throws: { "\($0)" == error }
    } else {
      #expect(try program.evaluate().value == want)
    }
  }

  @Test func optionalMacroErrors() throws {
    let env = try Environment(.optionalTypes, .variable("x", .optional(.int)))
    for expr in ["x.optMap(y.z, y.z + 1)", "x.optFlatMap(y.z, y.z + 1)"] {
      #expect {
        try env.compile(expr)
      } throws: { "\($0)".contains("variable name must be a simple identifier") }
    }
    let v0 = try Environment(.library(.optionalTypes(version: 0)), .variable("x", .optional(.int)))
    #expect {
      try v0.compile("x.optFlatMap(y, y.z + 1)")
    } throws: { "\($0)".contains("undeclared reference to 'optFlatMap'") }
  }
}

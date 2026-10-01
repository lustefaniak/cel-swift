// Ported from cel-go cel/folding_test.go and the two-variable case of cel/optimizer_test.go,
// against the public API. TestConstantFoldingNormalizeIDs and the option-plumbing tests check
// cel-go internals and are not ported; asyncFunc has no Swift counterpart.

import CEL
import CELExtensions
import CELGoTestProtos
import CELProtobuf
import Testing

/// One folding table row.
struct FoldCase: Sendable, CustomTestStringConvertible {
  enum Known: Sendable {
    case empty, list, object
  }

  var expr: String
  var folded: String
  var known: Known?
  var limit: Int = 100
  var macroCount: Int = 0

  init(_ expr: String, _ folded: String, known: Known? = nil) {
    self.expr = expr
    self.folded = folded
    self.known = known
  }

  init(_ expr: String, _ folded: String, limit: Int) {
    self.expr = expr
    self.folded = folded
    self.limit = limit
  }

  init(_ expr: String, _ folded: String, macroCount: Int) {
    self.expr = expr
    self.folded = folded
    self.macroCount = macroCount
  }

  var testDescription: String { expr }
}

let proto3Types = ProtobufTypes(files: [Google_Expr_Proto3_Test_TestAllTypes_CELFile])

@Suite("Constant folding")
struct APIConstantFoldingTests {
  static let foldingEnvironment: Environment = {
    do {
      let env = try Environment(
        .optionalTypes, .macroCallTracking, .typeProvider(proto3Types),
        .variable("x", .dyn), .variable("y", .dyn), .variable("b", .bool),
        .constant("c", .int, value: 2))
      return try env.extending(.variable("l", .list(.string)))
        .extending(.variable("o", .object("google.expr.proto3.test.TestAllTypes")))
    } catch {
      fatalError("\(error)")
    }
  }()

  @Test(arguments: cases)
  func constantFolding(_ testCase: FoldCase) throws {
    let env = Self.foldingEnvironment
    let checked = try env.compile(testCase.expr)
    var known: Variables?
    switch testCase.known {
    case nil: known = nil
    case .empty: known = Variables()
    case .list: known = ["l": ["foo", "bar", "baz"]]
    case .object:
      let message = Google_Expr_Proto3_Test_TestAllTypes.with { $0.repeatedInt32 = [1, 2, 3] }
      known = ["o": proto3Types.value(of: message)]
    }
    let optimized = try env.optimize(checked, .constantFolding(knownValues: known))
    #expect(optimized.description == testCase.folded)
  }

  @Test(arguments: [
    ("b in [b]", "true"), ("by in [by]", "true"), ("du in [du]", "true"), ("i in [1, 2, i]", "true"),
    ("n in [n]", "true"), ("s in [s]", "true"), ("ts in [ts]", "true"), ("ty in [ty]", "true"),
    ("u in [u]", "true"), ("li in [li]", "true"), ("lli in [lli]", "true"), ("msi in [msi]", "true"),
    ("ld in [ld]", "ld in [ld]"), ("lx in [lx]", "lx in [lx]"), ("msd in [msd]", "msd in [msd]"),
    ("d in [d]", "d in [d]"), ("x in [1, 2, x]", "x in [1, 2, x]"), ("oi in [oi]", "oi in [oi]"),
    ("o in [o]", "o in [o]"), ("1 in [1, 2]", "true"), ("1.0 in [d, 1.0]", "true"),
  ] as [(String, String)])
  func inListIdentifier(_ expr: String, _ folded: String) throws {
    let env = try Environment(
      .optionalTypes, .typeProvider(proto3Types),
      .variable("b", .bool), .variable("by", .bytes), .variable("du", .duration), .variable("i", .int),
      .variable("n", .null), .variable("s", .string), .variable("ts", .timestamp), .variable("ty", .type(nil)),
      .variable("u", .uint), .variable("li", .list(.int)), .variable("lli", .list(.list(.int))),
      .variable("msi", .map(key: .string, value: .int)), .variable("ld", .list(.double)),
      .variable("lx", .list(.dyn)), .variable("msd", .map(key: .string, value: .double)),
      .variable("d", .double), .variable("x", .dyn), .variable("oi", .optional(.int)),
      .variable("o", .object("google.expr.proto3.test.TestAllTypes")))
    let optimized = try env.optimize(env.compile(expr), .constantFolding())
    #expect(optimized.description == folded)
    // The rewrite must not change the result for a NaN, which is not equal to itself.
    let nan: [String: [String: Value]] = [
      "ld": ["ld": [Value(Double.nan)]], "lx": ["lx": [Value(Double.nan)]],
      "msd": ["msd": ["a": Value(Double.nan)]], "d": ["d": Value(Double.nan)], "x": ["x": Value(Double.nan)],
    ]
    let name = String(expr.prefix { $0 != " " })
    if let variables = nan[name] {
      let result = try env.program(optimized).evaluate(variables)
      #expect(result.value == false)
    }
  }

  @Test(arguments: sideEffectCases)
  func callsWithSideEffects(_ testCase: FoldCase) throws {
    let env = try Environment(
      .optionalTypes, .macroCallTracking,
      .function("noSideEffect", .overload("noSideEffect_int_int", argTypes: [.int], resultType: .int, .unaryBinding { $0 })),
      .function("withSideEffect", .overload("withSideEffect_int_int", argTypes: [.int], resultType: .int, .lateBinding)),
      .function("noImpl", .overload("noImpl_int_int", argTypes: [.int], resultType: .int)))
    let optimized = try env.optimize(env.compile(testCase.expr), .constantFolding())
    #expect(optimized.description == testCase.folded)
  }

  @Test(arguments: macroEliminationCases)
  func macroElimination(_ testCase: FoldCase) throws {
    let env = try Environment(.optionalTypes, .macroCallTracking, .typeProvider(proto3Types), .variable("x", .dyn))
    let optimized = try env.optimize(env.compile(testCase.expr), .constantFolding())
    #expect(optimized.description == testCase.folded)
    #expect(optimized.ast.sourceInfo.macroCalls.count == testCase.macroCount)
  }

  @Test(arguments: limitCases)
  func iterationLimit(_ testCase: FoldCase) throws {
    let env = try Environment(.optionalTypes, .macroCallTracking, .typeProvider(proto3Types), .variable("x", .dyn))
    let optimized = try env.optimize(env.compile(testCase.expr), .constantFolding(maxIterations: testCase.limit))
    #expect(optimized.description == testCase.folded)
  }

  @Test(arguments: [
    ("missing attribute", "x + 1", true, "x + 1"),
    ("evaluation error division by zero", "1 / 0", false, "1 / 0"),
    ("evaluation error index out of bounds", "[1, 2][5]", false, "[1, 2][5]"),
  ] as [(String, String, Bool, String)])
  func evaluationFailuresAreNotFolded(_ name: String, _ expr: String, _ declareX: Bool, _ folded: String) throws {
    let env = try Environment(options: declareX ? [.variable("x", .int)] : [])
    let known = declareX ? Variables([:], unknowns: [UnknownPattern("x")]) : nil
    let optimized = try env.optimize(env.compile(expr), .constantFolding(knownValues: known))
    #expect(optimized.description == folded, "\(name)")
  }

  @Test(arguments: [
    ("[1 + 1, 1 + 2].all(i, v, i < 10 && v < 10)", "true", nil),
    ("[1 + 1, 1 + 2].all(i, v, i < 10 && v < x)", "[2, 3].all(i, v, i < 10 && v < x)", nil),
    ("[1, 2, 3].transformList(i, v, i + v)", "[1, 3, 5]", nil),
    ("{'a': 1, 'b': 2}.all(k, v, v > 0)", "true", nil),
    ("v > 0 && [1 + 1, 1 + 2].all(i, v, i < 10 && v < 10)", "v > 0", nil),
    ("[1 + 1, 1 + 2].all(i, v, i < 10 && v < 10) && v > 0", "v > 0", nil),
    ("[1, 2, 3].transformList(i, v, i + v + k)", "[1, 2, 3].transformList(i, v, i + v + k)", nil),
    ("l.transformList(i, v, i + v)", "l.transformList(i, v, i + v)", nil),
    ("v > 0 && [1 + 1, 1 + 2].all(i, v, i < 10 && v < 10)", "true", 5),
    ("[1 + 1, 1 + 2].all(i, v, i < 10 && v < .v)", "true", 10),
  ] as [(String, String, Int64?)])
  func twoVariableComprehensions(_ expr: String, _ folded: String, _ v: Int64?) throws {
    let env = try Environment(
      .optionalTypes, .macroCallTracking, .library(.twoVarComprehensions),
      .variable("x", .int), .variable("v", .int), .variable("i", .int), .variable("k", .int),
      .variable("l", .list(.int)))
    let known = v.map { Variables(["v": .int($0)]) }
    let optimized = try env.optimize(env.compile(expr), .constantFolding(knownValues: known))
    #expect(optimized.description == folded)
  }

  @Test func foldedProgramEvaluatesLikeTheOriginal() throws {
    let env = try Environment(.variable("x", .int))
    let checked = try env.compile("x + (2 * 3) > 10 ? 'big' : 'small'")
    let folded = try env.optimize(checked, .constantFolding())
    #expect(folded.description == #"(x + 6 > 10) ? "big" : "small""#)
    #expect(try env.program(folded).evaluate(["x": 5]).value == "big")
    #expect(try env.program(checked).evaluate(["x": 5]).value == "big")
  }
}

extension APIConstantFoldingTests {
  static let cases: [FoldCase] = [
    FoldCase("[1, 1 + 2, 1 + (2 + 3)]", "[1, 3, 6]"),
    FoldCase("[1, 2] + [3, 4]", "[1, 2, 3, 4]"),
    FoldCase("[1, ?optional.of(2)] + [3, 4]", "[1, 2, 3, 4]"),
    FoldCase("[1, ?optional.none()] + [2]", "[1, 2]"),
    FoldCase("[x, 1] + [2, y]", "[x, 1, 2, y]"),
    FoldCase("[x, ?optional.of(1)] + [?optional.of(2), y]", "[x, 1, 2, y]"),
    FoldCase("[1] + [x] + [2]", "[1, x, 2]"),
    FoldCase("[1] + [?x] + [2]", "[1, ?x, 2]"),
    FoldCase("[?x, 1] + [2, ?y]", "[?x, 1, 2, ?y]"),
    FoldCase("6 in [1, 1 + 2, 1 + (2 + 3)]", "true"),
    FoldCase("5 in [1, 1 + 2, 1 + (2 + 3)]", "false"),
    FoldCase("x in [1, 1 + 2, 1 + (2 + 3)]", "x in [1, 3, 6]"),
    FoldCase("1 in [1, x + 2, 1 + (2 + 3)]", "true"),
    FoldCase("1 in [x, x + 2, 1 + (2 + 3)]", "1 in [x, x + 2, 6]"),
    FoldCase("x in []", "false"),
    FoldCase("{'hello': 'world'}.hello == x", #""world" == x"#),
    FoldCase("{'hello': 'world'}.?hello.orValue('default') == x", #""world" == x"#),
    FoldCase("{'hello': 'world'}['hello'] == x", #""world" == x"#),
    FoldCase(#"optional.of("hello")"#, #"optional.of("hello")"#),
    FoldCase(#"optional.ofNonZeroValue("")"#, "optional.none()"),
    FoldCase("{?'hello': optional.of('world')}['hello'] == x", #""world" == x"#),
    FoldCase("duration(string(7 * 24) + 'h')", #"duration("604800s")"#),
    FoldCase(#"timestamp("1970-01-01T00:00:00Z")"#, #"timestamp("1970-01-01T00:00:00Z")"#),
    FoldCase("[1, 1 + 1, 1 + 2, 2 + 3].exists(i, i < 10)", "true"),
    FoldCase("[1, 1 + 1, 1 + 2, 2 + 3].exists(i, i < 1 % 2)", "false"),
    FoldCase("[1, 2, 3].map(i, [1, 2, 3].map(j, i * j))", "[[1, 2, 3], [2, 4, 6], [3, 6, 9]]"),
    FoldCase("[1, 2, 3].map(i, [1, 2, 3].map(j, i * j).filter(k, k % 2 == 0))", "[[2], [2, 4, 6], [6]]"),
    FoldCase("[1, 2, 3].map(i, [1, 2, 3].map(j, i * j).filter(k, k % 2 == x))", "[1, 2, 3].map(i, [1, 2, 3].map(j, i * j).filter(k, k % 2 == x))"),
    FoldCase("[(x - 1 > 3) ? 1 : 2].all(x, x < .x)", "[(x - 1 > 3) ? 1 : 2].all(x, x < .x)"),
    FoldCase("[(x - 1 > 3) ? (x - 1) : 5].exists(x, x - 1 > 3)", "[(x - 1 > 3) ? (x - 1) : 5].exists(x, x - 1 > 3)"),
    FoldCase(#"[{}, {"a": 1}, {"b": 2}].filter(m, has(m.a))"#, #"[{"a": 1}]"#),
    FoldCase(#"[{}, {"a": 1}, {"b": 2}].filter(m, has({'a': true}.a))"#, #"[{}, {"a": 1}, {"b": 2}]"#),
    FoldCase("type(1)", "int"),
    FoldCase("[google.expr.proto3.test.TestAllTypes{single_int32: 2 + 3}].map(i, i)[0]", "google.expr.proto3.test.TestAllTypes{single_int32: 5}"),
    FoldCase("[?optional.ofNonZeroValue(0)]", "[]"),
    FoldCase("[1, ?optional.ofNonZeroValue(0)]", "[1]"),
    FoldCase("[optional.none(), ?x]", "[optional.none(), ?x]"),
    FoldCase("[?optional.none(), ?x]", "[?x]"),
    FoldCase("[?optional.of(1), ?x]", "[1, ?x]"),
    FoldCase("[1, x, ?optional.ofNonZeroValue(0), ?x.?y]", "[1, x, ?x.?y]"),
    FoldCase("[1, x, ?optional.ofNonZeroValue(3), ?x.?y]", "[1, x, 3, ?x.?y]"),
    FoldCase("[1, x, ?optional.ofNonZeroValue(3), ?x.?y].size() > 3", "[1, x, 3, ?x.?y].size() > 3"),
    FoldCase("{?'a': optional.of('hello'), ?x : optional.of(1), ?'b': optional.none()}", #"{"a": "hello", ?x: optional.of(1)}"#),
    FoldCase("true ? x + 1 : x + 2", "x + 1"),
    FoldCase("false ? x + 1 : x + 2", "x + 2"),
    FoldCase("false ? x + 'world' : 'hello' + 'world'", #""helloworld""#),
    FoldCase("x == true", "x == true"),
    FoldCase("true == x", "true == x"),
    FoldCase("x != false", "x != false"),
    FoldCase("false != x", "false != x"),
    FoldCase("x ? 1 + 2 : 3 + 4", "x ? 3 : 7"),
    FoldCase("true && x", "true && x"),
    FoldCase("x && true", "x && true"),
    FoldCase("false && x", "false"),
    FoldCase("x && false", "false"),
    FoldCase("true || x", "true"),
    FoldCase("x || true", "true"),
    FoldCase("false || x", "false || x"),
    FoldCase("x || false", "x || false"),
    FoldCase("true && b", "b"),
    FoldCase("b && true", "b"),
    FoldCase("false || b", "b"),
    FoldCase("b || false", "b"),
    FoldCase("false || x", "false || x"),
    FoldCase("x || false", "x || false"),
    FoldCase("true && x", "true && x"),
    FoldCase("x && true", "x && true"),
    FoldCase("true && x && true && x", "true && x && true && x"),
    FoldCase("false || x || false || x", "false || x || false || x"),
    FoldCase("true && b && true && b", "b && b"),
    FoldCase("false || b || false || b", "b || b"),
    FoldCase("true && true", "true"),
    FoldCase("true && false", "false"),
    FoldCase("true || false", "true"),
    FoldCase("false || false", "false"),
    FoldCase("true && false || true", "true"),
    FoldCase("false && true || false", "false"),
    FoldCase("null", "null"),
    FoldCase("google.expr.proto3.test.TestAllTypes{?single_int32: optional.ofNonZeroValue(1)}", "google.expr.proto3.test.TestAllTypes{single_int32: 1}"),
    FoldCase("google.expr.proto3.test.TestAllTypes{?single_int32: optional.ofNonZeroValue(0)}", "google.expr.proto3.test.TestAllTypes{}"),
    FoldCase("google.expr.proto3.test.TestAllTypes{single_int32: x, repeated_int32: [1, 2, 3]}", "google.expr.proto3.test.TestAllTypes{single_int32: x, repeated_int32: [1, 2, 3]}"),
    FoldCase("x + dyn([1, 2] + [3, 4])", "x + [1, 2, 3, 4]"),
    FoldCase("dyn([1, 2]) + [3.0, 4.0]", "[1, 2, 3.0, 4.0]"),
    FoldCase("{'a': dyn([1, 2]), 'b': x}", #"{"a": [1, 2], "b": x}"#),
    FoldCase("1 + x + 2 == 2 + x + 1", "1 + x + 2 == 2 + x + 1"),
    FoldCase("1 + 2 + x ==  x + 2 + 1", "3 + x == x + 2 + 1"),
    FoldCase("google.expr.proto3.test.ImportedGlobalEnum.IMPORT_BAR", "1", known: .empty),
    FoldCase("google.expr.proto3.test.ImportedGlobalEnum.IMPORT_BAR", "google.expr.proto3.test.ImportedGlobalEnum.IMPORT_BAR"),
    FoldCase(#"c == google.expr.proto3.test.ImportedGlobalEnum.IMPORT_BAZ ? "BAZ" : "Unknown""#, #""BAZ""#, known: .empty),
    FoldCase(#"[ google.expr.proto3.test.ImportedGlobalEnum.IMPORT_BAR, c, google.expr.proto3.test.ImportedGlobalEnum.IMPORT_FOO ].exists(e, e == google.expr.proto3.test.ImportedGlobalEnum.IMPORT_FOO) ? "has Foo" : "no Foo""#, #""has Foo""#, known: .empty),
    FoldCase(#"l.exists(e, e == "foo") ? "has Foo" : "no Foo""#, #""has Foo""#, known: .list),
    FoldCase(#""foo" in l"#, "true", known: .list),
    FoldCase("o.repeated_int32", "[1, 2, 3]", known: .object),
    FoldCase("false || x || false || y", "false || x || false || y"),
    FoldCase("false || b || false || b", "b || b"),
    FoldCase("true ? (false ? x + 1 : x + 2) : x", "x + 2"),
    FoldCase("false ? x : (true ? x + 1 : x + 2)", "x + 1"),
    FoldCase("1 in []", "false"),
    FoldCase("x in [1, 2, x]", "x in [1, 2, x]"),
    FoldCase("[1, 2].filter(x, x in [1, 2])", "[1, 2]"),
    FoldCase("5 in [1, x, y, 5]", "true"),
    FoldCase("!(5 in [1, x, y, 5])", "false"),
    FoldCase("[1, ?optional.of(3)]", "[1, 3]"),
    FoldCase("[1, optional.of(3)]", "[1, optional.of(3)]"),
    FoldCase("[?optional.of(1 + 2 + 3)]", "[6]"),
    FoldCase("[?optional.of(3)]", "[3]"),
    FoldCase("[?optional.of(x)]", "[?optional.of(x)]"),
    FoldCase("[?optional.ofNonZeroValue(3)]", "[3]"),
    FoldCase("[optional.of(1 + 2 + 3)]", "[optional.of(6)]"),
    FoldCase("[optional.of(x)]", "[optional.of(x)]"),
    FoldCase("[optional.ofNonZeroValue(1 + 2 + 3)]", "[optional.of(6)]"),
    FoldCase("[optional.ofNonZeroValue(3)]", "[optional.of(3)]"),
    FoldCase("{?1: optional.none()}", "{}"),
    FoldCase("google.expr.proto3.test.TestAllTypes{single_int64: 1 + 2 + 3 + x}", "google.expr.proto3.test.TestAllTypes{single_int64: 6 + x}"),
    FoldCase("google.expr.proto3.test.TestAllTypes{single_nested_message: google.expr.proto3.test.TestAllTypes.NestedMessage{bb: 42}}.single_nested_message.bb", "42"),
    FoldCase(#"{"a": 1}["a"]"#, "1"),
    FoldCase(#"{"a": {"b": 2}}["a"]["b"]"#, "2"),
    FoldCase(#"{"hello": "world"}.?hello"#, #"optional.of("world")"#),
    FoldCase("[1] + [2] + [3]", "[1, 2, 3]"),
    FoldCase("[?optional.none(), 2]", "[2]"),
    FoldCase("[1] + [?optional.of(2)] + [3]", "[1, 2, 3]"),
    FoldCase("[1] + [x]", "[1, x]"),
    FoldCase(#"duration("1h") - duration("60m")"#, #"duration("0s")"#),
    FoldCase(#"timestamp("1970-01-01T00:15:00Z") - timestamp("1970-01-01T00:00:10Z")"#, #"duration("890s")"#),
    FoldCase(#"timestamp("2000-01-01T00:02:03.2123Z") + duration("25h2m32s42ms53us29ns")"#, #"timestamp("2000-01-02T01:04:35.254353029Z")"#),
    FoldCase("[1 + 1, 1 + 2].exists(i, i < 10)", "true"),
  ]

  static let sideEffectCases: [FoldCase] = [
    FoldCase("noSideEffect(3)", "3"),
    FoldCase("withSideEffect(3)", "withSideEffect(3)"),
    FoldCase(#"[{}, {"a": 1}, {"b": 2}].exists(i, has(i.b) && withSideEffect(i.b) == 1)"#, #"[{}, {"a": 1}, {"b": 2}].exists(i, has(i.b) && withSideEffect(i.b) == 1)"#),
    FoldCase(#"[{}, {"a": 1}, {"b": 2}].exists(i, has(i.b) && noSideEffect(i.b) == 2)"#, "true"),
    FoldCase("noImpl(3)", "noImpl(3)"),
  ]

  static let macroEliminationCases: [FoldCase] = [
    FoldCase("has({}.key)", "false", macroCount: 0),
    FoldCase("[1, 2, 3].filter(i, i < 1)", "[]", macroCount: 0),
    FoldCase(#"[{}, {"a": 1}, {"b": 2}].exists(i, has(i.b))"#, "true", macroCount: 0),
    FoldCase(#"has(x.b) && [{}, {"a": 1}, {"b": 2}].exists(i, has(i.b))"#, "has(x.b)", macroCount: 1),
  ]

  static let limitCases: [FoldCase] = [
    FoldCase("[1, 1 + 2, 1 + (2 + 3)]", "[1, 3, 1 + 5]", limit: 1),
    FoldCase("5 in [1, 1 + 2, 1 + (2 + 3)]", "5 in [1, 3, 6]", limit: 2),
    FoldCase("[1, 2, 3].map(i, [1, 2, 3].map(j, i * j))", "[[1, 2, 3], [2, 4, 6], [3, 6, 9]]", limit: 1),
  ]
}

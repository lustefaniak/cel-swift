// Ported from cel-go cel/decls_test.go against the public API (the package-level
// maybeNoSuchOverload stands in for cel-go's exported decls.MaybeNoSuchOverload).
//
// Not ported: TestExprDeclToDeclaration and TestExprDeclToDeclarationInvalid convert exprpb
// declarations, which have no counterpart (an open API decision on proto conversion).

import CEL
import Testing

/// cel-go `dispatchTests`: the result of each expression, an error message, or an unknown.
private let dispatchCases: [(expr: String, out: Value?, error: String?)] = [
  ("max(-1)", -1, nil),
  ("max(-1, 0)", 0, nil),
  ("max(-1, 0, 1)", 1, nil),
  ("max(dyn(1.2))", nil, "no such overload: max(double)"),
  ("max(1, dyn(1.2))", nil, "no such overload: max(int, double)"),
  ("max(1, 2, dyn(1.2))", nil, "no such overload: max(int, int, double)"),
  ("max(err, 1)", nil, "error argument"),
  ("max(err, unk)", nil, "error argument"),
  ("max(unk, unk)", .unknown(UnknownSet(expressionID: 42)), nil),
  ("max(unk, unk, unk)", .unknown(UnknownSet(expressionID: 42)), nil),
]

/// cel-go `testParse` and `testCompile`.
private func checkDispatch(_ env: Environment) throws {
  let variables: [String: Value] = ["err": .error(EvalError("error argument")), "unk": .unknown(UnknownSet(expressionID: 42))]
  for c in dispatchCases {
    for program in [try env.program(env.parse(c.expr)), try env.program(env.compile(c.expr))] {
      if let error = c.error {
        #expect(Comment(rawValue: c.expr), performing: { try program.evaluate(variables) }, throws: { "\($0)" == error })
      } else if case .unknown(let want)? = c.out {
        let out = try program.evaluate(variables).value
        #expect(out.asUnknown.map { want.contains($0) } == true, "\(c.expr): \(out)")
      } else {
        #expect(try program.evaluate(variables).value == c.out, "\(c.expr)")
      }
    }
  }
}

private func sizeOf(_ value: Value) -> Value {
  switch value {
  case .string(let s): return Value(s.unicodeScalars.count)
  case .bytes(let b): return Value(b.count)
  case .list(let l): return Value(l.count)
  case .map(let m): return Value(m.count)
  default: return maybeNoSuchOverload("size", [value])
  }
}

private func maxOfInts(_ args: [Value]) -> Value {
  var result = Int64.min
  for arg in args {
    guard let i = arg.asInt else {
      // A singleton must handle errors itself; overloads get runtime type guards.
      return maybeNoSuchOverload("max", args)
    }
    result = max(result, i)
  }
  return Value(result)
}

@Suite("decls_test.go")
struct APIDeclsTests {
  static let vector = CELType.opaque(name: "vector", parameters: [.typeParam("V")])

  @Test func functionMerge() throws {
    let mapKV = CELType.map(key: .typeParam("K"), value: .typeParam("V"))
    let listV = CELType.list(.typeParam("V"))
    let size = Environment.Option.function(
      "size",
      .overload("size_map", argumentTypes: [mapKV], resultType: .int),
      .overload("size_list", argumentTypes: [listV], resultType: .int),
      .overload("size_string", argumentTypes: [.string], resultType: .int),
      .overload("size_bytes", argumentTypes: [.bytes], resultType: .int),
      .memberOverload("map_size", argumentTypes: [mapKV], resultType: .int),
      .memberOverload("list_size", argumentTypes: [listV], resultType: .int),
      .memberOverload("string_size", argumentTypes: [.string], resultType: .int),
      .memberOverload("bytes_size", argumentTypes: [.bytes], resultType: .int),
      .singletonUnaryBinding({ sizeOf($0) }, traits: .sizer))
    // The vector size is inherited from the singleton implementation of `size`.
    let sizeExt = Environment.Option.function(
      "size",
      .overload("size_vector", argumentTypes: [Self.vector], resultType: .int),
      .memberOverload("vector_size", argumentTypes: [Self.vector], resultType: .int))
    let vectorExt = Environment.Option.function(
      "vector", .overload("vector_list", argumentTypes: [listV], resultType: Self.vector, .unaryBinding { $0 }))
    let eq = Environment.Option.function(
      "_==_",
      .overload(
        "_==_", argumentTypes: [.typeParam("T"), .typeParam("T")], resultType: .bool,
        .binaryBinding { lhs, rhs in lhs.celEquals(rhs) }))
    let env = try Environment.custom(size, sizeExt, vectorExt, eq)
    let checked = try env.compile(
      """
      [[0].size() == 1,
       {'a': true, 'b': false}.size() == 2,
       'hello'.size() == 5,
       b'hello'.size() == 5,
       vector([1.2, 2.3, 3.4]).size() == 3]
      """)
    #expect(checked.outputType == CELType.list(.bool))
    #expect(checked.outputType.description == "list(bool)")
    #expect(try env.program(checked).evaluate().value == [true, true, true, true, true])

    let sizeBad = Environment.Option.function(
      "size",
      .overload("size_vector", argumentTypes: [Self.vector], resultType: .int),
      .memberOverload("vector_size", argumentTypes: [Self.vector], resultType: .int),
      .singletonBinaryBinding { _, _ in .null })
    #expect {
      try Environment.custom(size, sizeBad)
    } throws: { "\($0)".contains("already has a singleton binding") }

    // cel-go reports the conflict when the program is created; the environment builds its
    // dispatcher eagerly, so it is reported when the environment is created.
    #expect {
      let mixed = try Environment.custom(
        size,
        .function("size", .overload("size_int", argumentTypes: [.int], resultType: .int, .unaryBinding { _ in 2 })))
      _ = try mixed.program(checked)
    } throws: { "\($0)".contains("incompatible with specialized overloads") }
  }

  @Test func functionMergeDuplicate() throws {
    let maxFunc = Environment.Option.function(
      "max", .overload("max_int", argumentTypes: [.int], resultType: .int), .overload("max_int", argumentTypes: [.int], resultType: .int))
    _ = try Environment.custom(maxFunc, maxFunc)
  }

  @Test func functionMergeDeclarationAndDefinition() throws {
    let decl = Environment.Option.function(
      "id", .overload("id", argumentTypes: [.typeParam("T")], resultType: .typeParam("T"), .nonStrict))
    let def = Environment.Option.function(
      "id", .overload("id", argumentTypes: [.typeParam("T")], resultType: .typeParam("T"), .nonStrict, .unaryBinding { $0 }))
    let env = try Environment.custom(.variable("x", .any), decl, def)
    #expect(try env.program(env.compile("id(x)")).evaluate(["x": true]).value == true)
  }

  @Test func functionMergeCollision() {
    let maxFunc = Environment.Option.function(
      "max", .overload("max_int", argumentTypes: [.int], resultType: .int),
      .overload("max_int2", argumentTypes: [.int], resultType: .int))
    #expect(throws: DeclarationError.self) { try Environment.custom(maxFunc, maxFunc) }
  }

  @Test func functionNoOverloads() {
    #expect {
      try Environment.custom(.function("right", .singletonBinaryBinding { _, rhs in rhs }))
    } throws: { "\($0)".contains("must have at least one overload") }
  }

  @Test func singletonUnaryBinding() throws {
    let env = try Environment.custom(
      .variable("x", .any),
      .function("id", .overload("id_any", argumentTypes: [.any], resultType: .any)),
      .function("id", .overload("id_any", argumentTypes: [.any], resultType: .any), .singletonUnaryBinding { $0 }))
    #expect(try env.program(env.parse("id(x)")).evaluate(["x": "hello"]).value == "hello")
  }

  @Test func singletonUnaryBindingParameterized() throws {
    let env = try Environment.custom(
      .variable("x", .any),
      .function("isSorted", .memberOverload("list_int_is_sorted", argumentTypes: [.list(.int)], resultType: .bool)),
      .function(
        "isSorted", .memberOverload("list_uint_is_sorted", argumentTypes: [.list(.uint)], resultType: .bool),
        .singletonUnaryBinding { _ in true }))
    #expect(try env.program(env.parse("x.isSorted()")).evaluate(["x": [1, 2, 3]]).value == true)
  }

  @Test func singletonBinaryBinding() throws {
    _ = try Environment.custom(
      .function(
        "right",
        .overload("right_int_int", argumentTypes: [.int, .int], resultType: .int),
        .overload("right_double_double", argumentTypes: [.double, .double], resultType: .double),
        .overload("right_string_string", argumentTypes: [.string, .string], resultType: .string),
        .singletonBinaryBinding({ _, rhs in rhs }, traits: .comparer)))
  }

  @Test func singletonFunctionBinding() throws {
    let env = try Environment.custom(
      .variable("unk", .dyn), .variable("err", .dyn),
      .function("dyn", .overload("dyn", argumentTypes: [.dyn], resultType: .dyn), .singletonUnaryBinding { $0 }),
      .function(
        "max",
        .overload("max_int", argumentTypes: [.int], resultType: .int),
        .overload("max_int_int", argumentTypes: [.int, .int], resultType: .int),
        .overload("max_int_int_int", argumentTypes: [.int, .int, .int], resultType: .int),
        .singletonFunctionBinding { maxOfInts($0) }))
    try checkDispatch(env)
  }

  @Test func unaryBinding() throws {
    #expect {
      try Environment.custom(.function("dyn", .overload("dyn", argumentTypes: [], resultType: .dyn, .unaryBinding { $0 })))
    } throws: { "\($0)".contains("function bound to non-unary overload") }

    let env = try Environment.custom(
      .function(
        "size",
        .overload(
          "size_non_strict", argumentTypes: [.list(.dyn)], resultType: .int, .nonStrict, .operandTraits(.sizer),
          .unaryBinding { arg in
            switch arg {
            case .unknown, .error: return arg
            default: return sizeOf(arg)
            }
          })),
      .variable("x", .list(.dyn)))
    let out = try env.program(env.compile("size(x)")).evaluate(["x": .unknown(UnknownSet(expressionID: 1))]).value
    #expect(out.asUnknown.map { UnknownSet(expressionID: 1).contains($0) } == true)
  }

  @Test func binaryBinding() throws {
    let env = try Environment.custom(
      .function(
        "max",
        .overload(
          "max_int_int", argumentTypes: [.int, .int], resultType: .int, .nonStrict,
          .binaryBinding { lhs, rhs in
            guard let l = lhs.asInt else { return rhs }
            guard let r = rhs.asInt else { return lhs }
            return Value(max(l, r))
          })),
      .variable("x", .int), .variable("y", .int))
    let program = try env.program(env.parse("max(x, y)"))
    #expect(try program.evaluate(["x": .unknown(UnknownSet(expressionID: 1)), "y": 1]).value == 1)
    #expect(try program.evaluate(["x": 2, "y": .unknown(UnknownSet(expressionID: 2))]).value == 2)
    #expect(try program.evaluate(["x": 2, "y": 1]).value == 2)

    #expect {
      try Environment.custom(
        .function(
          "right",
          .overload("right_int_int", argumentTypes: [.int, .int, .int], resultType: .int, .binaryBinding { _, rhs in rhs })))
    } throws: { "\($0)".contains("function bound to non-binary overload") }
  }

  @Test func functionBinding() throws {
    let env = try Environment.custom(
      .variable("unk", .dyn), .variable("err", .dyn),
      .function("dyn", .overload("dyn", argumentTypes: [.dyn], resultType: .dyn), .singletonUnaryBinding { $0 }),
      .function(
        "max",
        .overload("max_int", argumentTypes: [.int], resultType: .int, .unaryBinding { $0 }),
        .overload(
          "max_int_int", argumentTypes: [.int, .int], resultType: .int,
          .binaryBinding { lhs, rhs in (lhs.asInt ?? 0) < (rhs.asInt ?? 0) ? rhs : lhs }),
        .overload("max_int_int_int", argumentTypes: [.int, .int, .int], resultType: .int, .functionBinding { maxOfInts($0) })))
    try checkDispatch(env)
  }

  @Test func functionDisableDeclaration() throws {
    let env = try Environment.custom(
      .function(
        "disabled", .disableDeclaration(true), .overload("disabled_any", argumentTypes: [.bool], resultType: .bool),
        .singletonFunctionBinding { _ in true }))
    #expect(try env.program(env.parse("disabled(true)")).evaluate().value == true)
    #expect {
      try env.compile("disabled(true)")
    } throws: { "\($0)".contains("undeclared reference to 'disabled'") }
  }

  @Test func functionDisableDeclarationMerge() throws {
    let env = try Environment.custom(
      .function("disabled", .overload("disabled_any", argumentTypes: [.bool], resultType: .bool)),
      .function(
        "disabled", .disableDeclaration(true),
        .overload("disabled_any", argumentTypes: [.bool], resultType: .bool, .functionBinding { _ in true })))
    #expect(try env.program(env.parse("disabled(true)")).evaluate().value == true)
    #expect {
      try env.compile("disabled(true)")
    } throws: { "\($0)".contains("undeclared reference to 'disabled'") }
  }

  @Test func functionDisableDeclarationMergeReenable() throws {
    let env = try Environment.custom(
      .function("enabled", .disableDeclaration(true), .overload("enabled_any", argumentTypes: [.bool], resultType: .bool)),
      .function(
        "enabled", .disableDeclaration(false),
        .overload("enabled_any", argumentTypes: [.bool], resultType: .bool, .functionBinding { _ in true })))
    #expect(try env.program(env.parse("enabled(true)")).evaluate().value == true)
    _ = try env.compile("enabled(true)")
  }

  @Test func excludeOverloads() throws {
    let env = try Environment.custom(
      .library(.standard(subset: .init(excludedFunctions: [.init("_+_", overloadIDs: ["add_list", "add_bytes", "add_string"])]))))
    let successes: [(String, Value)] = [
      ("1 + 1", 2), ("1.5 + 1.5", 3.0), ("1u + 2u", .uint(3)),
      ("timestamp('2001-01-01T00:00:00Z') + duration('1h') == timestamp('2001-01-01T01:00:00Z')", true),
      ("duration('1h') + duration('1m') == duration('1h1m')", true),
    ]
    for (expr, want) in successes {
      #expect(try env.program(env.compile(expr)).evaluate().value == want, "\(expr)")
    }
    for expr in ["'a' + 'b'", "b'123' + b'456'", "[1] + [2, 3]"] {
      #expect(throws: CompileError.self, "\(expr)") { try env.compile(expr) }
    }
  }

  @Test func includeOverloads() throws {
    // As cel-go: the standard functions, with `_+_` restricted to two overloads.
    let functions = Library.standard.functions.compactMap { fn in
      fn.name == "_+_" ? fn.including(overloadIDs: ["add_int64", "add_double"]) : fn
    }
    let env = try Environment.custom(.functions(functions))
    #expect(try env.program(env.compile("1 + 1")).evaluate().value == 2)
    #expect(try env.program(env.compile("1.5 + 1.5")).evaluate().value == 3.0)
    for expr in [
      "'a' + 'b'", "b'123' + b'456'", "[1] + [2, 3]", "1u + 2u",
      "timestamp('2001-01-01T00:00:00Z') + duration('1h') == timestamp('2001-01-01T01:00:00Z')",
      "duration('1h') + duration('1m') == duration('1h1m')",
    ] {
      #expect(throws: CompileError.self, "\(expr)") { try env.compile(expr) }
    }
  }
}

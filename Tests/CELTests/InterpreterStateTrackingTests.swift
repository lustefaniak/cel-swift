// Copyright 2019 Google LLC
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
// Ported from cel-go interpreter/attributes_test.go (TestAttributeStateTracking,
// TestAttributesMissingMsg, TestAttributeMissingMsgUnknownField, TestConditionalAttributeQualify,
// TestQualifyIfPresent) and attribute_patterns_test.go (TestQualifierValueEquals). Not ported:
// TestAttribute_StringRepresentation (Go `fmt.Stringer` debug output), TestResolverCustomQualifier
// and TestAttributesNarrowMapKeyQualifier (custom Go qualifiers over Go native maps).

import CELGoTestProtos
import CELProtobuf
import Testing

@testable import CEL

struct StateTrackingCase: Sendable, CustomTestStringConvertible {
  var expr: String
  var vars: [VariableDecl] = []
  var input: [String: Value] = [:]
  /// Unknown patterns; non-nil evaluates with a partial activation and the partial attribute factory.
  var unknowns: [AttributePattern]?
  var out: Value
  /// The error's expression id, for an error result.
  var errorNodeID: Int64 = 0
  var state: [Int64: Value] = [:]

  var testDescription: String { expr }
}

private let mapStringMapStringString = CELType.map(key: .string, value: .map(key: .string, value: .string))
private let dexList: Value = ["index", "middex", "outdex", "dex"]

let stateTrackingCases: [StateTrackingCase] = [
  StateTrackingCase(
    expr: #"[{"field": true}][0].field"#, out: true,
    state: [1: [["field": true]], 6: ["field": true], 8: true]),
  StateTrackingCase(
    expr: "a[1]['two']", vars: [VariableDecl(name: "a", type: .map(key: .int, value: .map(key: .string, value: .bool)))],
    input: ["a": [1: ["two": true]]], out: true, state: [2: ["two": true], 4: true]),
  StateTrackingCase(
    expr: "a[1][2][3]", vars: [VariableDecl(name: "a", type: .map(key: .int, value: .map(key: .dyn, value: .dyn)))],
    input: ["a": [1: [1: 0, 2: dexList]]], out: "dex", state: [2: [1: 0, 2: dexList], 4: dexList, 6: "dex"]),
  StateTrackingCase(
    expr: "a[1][2][a[1][1]]",
    vars: [VariableDecl(name: "a", type: .map(key: .int, value: .map(key: .dyn, value: .dyn)))],
    input: ["a": [1: [1: 0, 2: dexList]]], out: "index",
    state: [2: [1: 0, 2: dexList], 4: dexList, 6: "index", 8: [1: 0, 2: dexList], 10: 0]),
  StateTrackingCase(
    expr: "true ? a : b", vars: [VariableDecl(name: "a", type: .string), VariableDecl(name: "b", type: .string)],
    input: ["a": "hello", "b": "world"], out: "hello", state: [2: "hello"]),
  StateTrackingCase(
    expr: "(a.size() != 0 ? a : b)[0]",
    vars: [VariableDecl(name: "a", type: .list(.string)), VariableDecl(name: "b", type: .list(.string))],
    input: ["a": ["hello", "world"], "b": ["world", "hello"]], out: "hello",
    state: [1: ["hello", "world"], 2: 2, 3: true, 4: 0, 8: "hello"]),
  StateTrackingCase(
    expr: "a.?b.c", vars: [VariableDecl(name: "a", type: mapStringMapStringString)],
    input: ["a": ["b": ["c": "world"]]], out: .optional("world"), state: [3: ["c": "world"], 4: .optional("world")]),
  StateTrackingCase(
    expr: "a.?b.c", vars: [VariableDecl(name: "a", type: mapStringMapStringString)],
    input: ["a": ["b": ["random": "value"]]], out: .optional(nil),
    state: [3: ["random": "value"], 4: .optional(nil)]),
  StateTrackingCase(
    expr: "a.b.c", vars: [VariableDecl(name: "a", type: mapStringMapStringString)],
    input: ["a": ["b": ["c": "world"]]], out: "world", state: [2: ["c": "world"], 3: "world"]),
  StateTrackingCase(
    expr: "m[has(a.b)]",
    vars: [
      VariableDecl(name: "a", type: .map(key: .string, value: .string)),
      VariableDecl(name: "m", type: .map(key: .bool, value: .string)),
    ], input: ["a": ["b": ""], "m": [true: "world"]], out: "world"),
  StateTrackingCase(
    expr: "m[?has(a.b)]",
    vars: [
      VariableDecl(name: "a", type: .map(key: .string, value: .string)),
      VariableDecl(name: "m", type: .map(key: .bool, value: .string)),
    ], input: ["a": ["b": ""], "m": [true: "world"]], out: .optional("world")),
  StateTrackingCase(
    expr: "m[?has(a.b.c)]",
    vars: [
      VariableDecl(name: "a", type: .map(key: .string, value: .dyn)),
      VariableDecl(name: "m", type: .map(key: .bool, value: .string)),
    ], input: ["a": .map(OrderedMap()), "m": [true: "world"]], unknowns: [AttributePattern("a").qualString("b")],
    out: .unknown(UnknownSet(expressionID: 5, attribute: AttributeTrail(variable: "a", qualifierPath: [.string("b")])))),
  // Error node 9 is the `i + 'b'` expression.
  StateTrackingCase(
    expr: "['a', b.val, 'c'].filter(i, i + 'b' != 'ab')",
    vars: [VariableDecl(name: "b", type: .map(key: .string, value: .dyn))], input: ["b": ["val": 1]], unknowns: [],
    out: Value.noSuchOverload, errorNodeID: 9),
]

struct InterpreterStateTrackingTests {
  @Test(arguments: stateTrackingCases)
  func attributeStateTracking(_ tc: StateTrackingCase) throws {
    var env = ProgramEnvironment(
      functions: StandardLibrary.functions + OptionalLibrary.functions(),
      parserOptions: [.enableOptionalSyntax(true)])
    env.decorators = [OptionalLibrary.decorator]
    env.declaresStandardTypes = false
    try env.declare(tc.vars)
    let ast = try env.check(env.parse(tc.expr), source: TextSource(tc.expr))
    var options: EvalOptions = [.optimize, .trackState]
    let activation: any Activation
    if let unknowns = tc.unknowns {
      options.insert(.partialEval)
      activation = PartialActivationWrapper(MapActivation(tc.input), unknowns: unknowns)
    } else {
      activation = MapActivation(tc.input)
    }
    let result = try env.program(ast, options: ProgramOptions(evalOptions: options)).eval(activation)
    switch (tc.out, result.value) {
    case (.unknown, _):
      #expect(result.value == tc.out)
    case (.error(let want), .error(let got)):
      #expect(got.message == want.message)
      #expect(got.expressionID == tc.errorNodeID)
    default:
      #expect(result.value.celEquals(tc.out) == .bool(true), "got \(result.value), want \(tc.out)")
    }
    let state = try #require(result.state)
    for (id, want) in tc.state.sorted(by: { $0.key < $1.key }) {
      let got = try #require(state.value(id), "state not found for \(id)")
      #expect(got.celEquals(want) == .bool(true), "state[\(id)]: got \(got), want \(want)")
    }
  }

  /// An activation binding `missing_msg` to a message of a type the registry does not know: cel-go
  /// binds an `Any` holding a `TestAllTypes` and converts it when the attribute is qualified.
  private func missingMessage() -> Value {
    ProtobufTypes().value(of: Google_Expr_Proto3_Test_TestAllTypes())
  }

  @Test func attributesMissingMsg() throws {
    let fac = DefaultAttributeFactory(container: .default, provider: TypeRegistry())
    let attr = try fac.absoluteAttribute(id: 1, names: ["missing_msg"]).addingQualifier(
      fac.newQualifier(objType: nil, qualID: 2, value: .value("field"), optional: false))
    #expect {
      try attr.resolve(ExecutionFrame(MapActivation(["missing_msg": missingMessage()])))
    } throws: { error in
      guard case .eval(let e)? = error as? ResolveError else { return false }
      return e.message == "unknown type: 'google.expr.proto3.test.TestAllTypes'"
    }
  }

  @Test func attributeMissingMsgUnknownField() throws {
    let fac = PartialAttributeFactory(container: .default, provider: TypeRegistry())
    let attr = try fac.absoluteAttribute(id: 1, names: ["missing_msg"]).addingQualifier(
      fac.newQualifier(objType: nil, qualID: 2, value: .value("field"), optional: false))
    let vars = PartialActivationWrapper(
      MapActivation(["missing_msg": missingMessage()]),
      unknowns: [AttributePattern("missing_msg").qualString("field")])
    #expect(try attr.resolve(ExecutionFrame(vars)).isUnknown)
  }

  @Test func conditionalAttributeQualify() throws {
    let fac = DefaultAttributeFactory(container: .default, provider: TypeRegistry())
    let cond = fac.conditionalAttribute(
      id: 3, expr: EvalConst(id: 4, value: true), truthy: fac.absoluteAttribute(id: 1, names: ["a"]),
      falsy: fac.absoluteAttribute(id: 2, names: ["b"]))
    let vars = ExecutionFrame(MapActivation(["a": "key", "b": "other"]))
    let obj: Value = ["key": 100]
    #expect(try cond.qualify(vars, obj) == 100)
    let (value, found) = try cond.qualifyIfPresent(vars, obj, presenceOnly: false)
    #expect(found)
    #expect(value == 100)
  }

  @Test func qualifyIfPresent() throws {
    let fac = DefaultAttributeFactory(container: .default, provider: TypeRegistry())
    let vars = ExecutionFrame(MapActivation(["a": "b", "c": 1]))
    func optQual(_ value: Value) throws -> any Qualifier {
      try fac.newQualifier(objType: nil, qualID: 1, value: .value(value), optional: true)
    }
    let cases: [(String, any Qualifier, Value, Value)] = [
      ("absolute_attribute", fac.absoluteAttribute(id: 1, names: ["a"]), ["b": 100], 100),
      ("maybe_attribute", fac.maybeAttribute(id: 1, name: "a"), ["b": 100], 100),
      ("relative_attribute", fac.relativeAttribute(id: 2, operand: EvalConst(id: 1, value: "b")), ["b": 200], 200),
      ("string_qualifier", try optQual("b"), ["b": 300], 300),
      ("int_qualifier", try optQual(1), [1: "value"], "value"),
      ("uint_qualifier", try optQual(.uint(1)), [.uint(1): "uvalue"], "uvalue"),
      ("bool_qualifier", try optQual(true), [true: "bvalue"], "bvalue"),
    ]
    for (name, qual, obj, out) in cases {
      let (value, found) = try qual.qualifyIfPresent(vars, obj, presenceOnly: false)
      #expect(found && value == out, "\(name): got (\(String(describing: value)), \(found))")
    }
  }

  @Test func qualifierValueEquals() throws {
    let registry = testTypeRegistry()
    let fac = DefaultAttributeFactory(container: .default, provider: registry)
    func equator(_ value: Value, objType: CELType? = nil) throws -> any QualifierValueEquator {
      let q = try fac.newQualifier(objType: objType, qualID: 1, value: .value(value), optional: false)
      return try #require(q as? any QualifierValueEquator, "\(q) is not a value equator")
    }
    // Pattern qualifiers are strings, ints, uints and bools (cel-go also tries Go floats, which
    // patterns cannot hold).
    let cases: [(String, any QualifierValueEquator, [(AttributeQualifier, Bool)])] = [
      (
        "fieldQualifier", try equator("single_int32", objType: .object("google.expr.proto3.test.TestAllTypes")),
        [(.string("single_int32"), true), (.string("bar"), false), (.int(123), false), (.bool(true), false)]
      ),
      ("stringQualifier", try equator("hello"), [(.string("hello"), true), (.string("world"), false), (.int(123), false)]),
      (
        "boolQualifier", try equator(true),
        [(.bool(true), true), (.bool(false), false), (.string("true"), false), (.int(1), false)]
      ),
      (
        "intQualifier", try equator(42),
        [(.int(42), true), (.uint(42), true), (.int(100), false), (.string("42"), false)]
      ),
      (
        "uintQualifier", try equator(.uint(100)),
        [(.uint(100), true), (.int(100), true), (.uint(50), false), (.string("100"), false)]
      ),
      ("doubleQualifier", try equator(3.14), [(.int(3), false), (.string("3.14"), false)]),
      ("doubleQualifierWhole", try equator(42.0), [(.int(42), true), (.uint(42), true)]),
    ]
    for (name, qualifier, inputs) in cases {
      for (input, want) in inputs {
        #expect(qualifier.qualifierValueEquals(input) == want, "\(name).qualifierValueEquals(\(input))")
      }
    }
  }
}

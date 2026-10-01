// Copyright 2024 Google LLC
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
// Ported from cel-go ext/comprehensions_test.go (TestTwoVarComprehensionsResidualAST): partial
// evaluation and residual expressions of two-variable comprehensions and cel.bind, through the
// public API.

import CEL
import CELExtensions
import Testing

struct ComprehensionResidualCase: Sendable, CustomTestStringConvertible {
  var name: String
  var variables: [String: CELType]
  var input: [String: Value]
  var unknowns: [UnknownPattern]
  var expr: String
  var residual: String

  var testDescription: String { name }
}

private let listIntMapIntDyn: [String: CELType] = ["x": .list(.int), "y": .map(key: .int, value: .dyn)]
private let listStringMapIntString: [String: CELType] = ["x": .list(.string), "y": .map(key: .int, value: .string)]
private let hiHelloHowdy: Value = [1: "hi", 2: "hello", 3: "howdy"]

let comprehensionResidualCases: [ComprehensionResidualCase] = [
  ComprehensionResidualCase(
    name: "transform map entry residual compare", variables: ["x": .list(.dyn), "y": .int],
    input: ["x": [0, .uint(1)]], unknowns: [UnknownPattern("y")],
    expr: "x.transformMapEntry(i, v, {v: i}).size() < y", residual: "2 < y"),
  ComprehensionResidualCase(
    name: "transform map entry residual transform", variables: ["x": .list(.dyn), "y": .int],
    input: ["x": [0, .uint(1)]], unknowns: [UnknownPattern("y")],
    expr: "x.transformMapEntry(i, v, i < y, {v: i})", residual: "[0, 1u].transformMapEntry(i, v, i < y, {v: i})"),
  ComprehensionResidualCase(
    name: "nested exists unknown inner range", variables: listIntMapIntDyn, input: ["x": [1, 2, 3]],
    unknowns: [UnknownPattern("y")], expr: "x.exists(val, y.exists(key, _, key == val))",
    residual: "[1, 2, 3].exists(val, y.exists(key, _, key == val))"),
  ComprehensionResidualCase(
    name: "nested exists unknown outer range", variables: listIntMapIntDyn, input: ["y": hiHelloHowdy],
    unknowns: [UnknownPattern("x")], expr: "x.exists(val, y.exists(key, _, key == val))",
    residual: "x.exists(val, y.exists(key, _, key == val))"),
  ComprehensionResidualCase(
    name: "nested exists unknown outer range with extra predicate", variables: listIntMapIntDyn,
    input: ["y": hiHelloHowdy], unknowns: [UnknownPattern("x")],
    expr: "x.exists(val, y.exists(key, _, key == val)) && y.all(key, val, val.startsWith('h'))",
    residual: "x.exists(val, y.exists(key, _, key == val))"),
  ComprehensionResidualCase(
    name: "nested exists partial unknown outer range", variables: listIntMapIntDyn,
    input: ["x": [42, 0, 43], "y": hiHelloHowdy], unknowns: [UnknownPattern("x").qualified(by: .int(1))],
    expr: "x.exists(val, y.exists(key, _, key == val)) || x[0] == 0 || x[1] == 1 || x[2] == 2",
    residual: "x.exists(val, y.exists(key, _, key == val)) || x[1] == 1"),
  ComprehensionResidualCase(
    name: "nested exists partial unknown outer range with optionals", variables: listIntMapIntDyn,
    input: ["x": [42, 0, 43], "y": hiHelloHowdy], unknowns: [UnknownPattern("x").qualified(by: .int(1))],
    expr: "x.exists(val, y.exists(key, _, key == val)) || (x[?0].hasValue() && x[?1].hasValue())",
    residual: "x.exists(val, y.exists(key, _, key == val)) || x[?1].hasValue()"),
  ComprehensionResidualCase(
    name: "inner value partial unknown two-var", variables: listStringMapIntString,
    input: ["x": ["howdy", "hello", "hi"], "y": [0: "hi", 1: "hello", 2: "howdy"]],
    unknowns: [UnknownPattern("y").qualified(by: .int(1))], expr: "x.exists(key, val, y[?key] == optional.of(val))",
    residual: #"["howdy", "hello", "hi"].exists(key, val, y[?key] == optional.of(val))"#),
  ComprehensionResidualCase(
    name: "inner value partial unknown one-var", variables: listStringMapIntString,
    input: ["x": ["howdy"], "y": [0: "hello"]], unknowns: [UnknownPattern("x").qualified(by: .int(0))],
    expr: "y.exists(key, y[?key] == x[?key])", residual: #"{0: "hello"}.exists(key, y[?key] == x[?key])"#),
  ComprehensionResidualCase(
    name: "simple bind", variables: ["y": .map(key: .int, value: .string)],
    input: ["y": [0: "hi", 1: "hello", 2: "howdy"]], unknowns: [UnknownPattern("y").qualified(by: .int(1))],
    expr: "cel.bind(z, y[0], z + y[1])", residual: #"cel.bind(z, "hi", "hi" + y[1])"#),
  ComprehensionResidualCase(
    name: "bind with comprehension", variables: listStringMapIntString,
    input: ["x": ["hi", "hello", "howdy"], "y": [0: "hi", 1: "hello", 2: "howdy"]],
    unknowns: [UnknownPattern("y").qualified(by: .int(1))],
    expr: "cel.bind(z, y[0], x.all(i, val, val == z || optional.of(val) == y[?i]))",
    residual: #"cel.bind(z, "hi", ["hi", "hello", "howdy"].all(i, val, val == z || optional.of(val) == y[?i]))"#),
]

struct ComprehensionsResidualTests {
  @Test(arguments: comprehensionResidualCases)
  func twoVarComprehensionsResidual(_ tc: ComprehensionResidualCase) throws {
    let env = try Environment(
      .library(.twoVarComprehensions), .library(.bindings), .library(.lists), .library(.strings), .optionalTypes,
      .macroCallTracking, .hiddenAccumulatorName(true), .variables(tc.variables))
    let checked = try env.compile(tc.expr)
    let program = try env.program(checked, options: [.trackState, .partialEvaluation])
    let result = try program.evaluate(Variables(tc.input, unknowns: tc.unknowns))
    #expect(result.value.isUnknown, "got \(result.value)")
    let residual = try env.residual(of: checked, state: try #require(result.state))
    #expect(residual.description == tc.residual)
  }
}

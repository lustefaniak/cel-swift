// Copyright 2022 Google LLC
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
// Ported from cel-go interpreter/runtimecost_test.go.

import CELGoTestProtos
import Testing

@testable import CEL

/// One row of cel-go's `TestRuntimeCost` table.
struct RuntimeCostCase: Sendable, CustomTestStringConvertible {
  enum Tracker: Sendable {
    case containsString
  }

  var name: String
  var expr: String
  var vars: [VariableDecl] = []
  var presenceTestHasCost: Bool? = nil
  var tracker: Tracker? = nil
  var `in`: [String: Value] = [:]
  var testFuncCost = false
  var limit: UInt64 = 0
  var expectExceedsLimit = false
  var want: UInt64

  var testDescription: String { "\(name): \(expr)" }
}

/// cel-go's `testRuntimeCostEstimator`: 7 for `timestamp.getFullYear()`, else the default.
struct TestRuntimeCostEstimator: ActualCostEstimator {
  func callCost(function: String, overloadID: String, args: [Value], result: Value) -> UInt64? {
    overloadID == Overloads.timestampToYear ? 7 : nil
  }
}

/// A string of `n` ASCII letters (cel-go `randSeq`; only the length matters for cost).
func randSeq(_ n: Int) -> String {
  let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
  var rng = SplitMix64(seed: UInt64(n))
  var s = String.UnicodeScalarView()
  for _ in 0..<n {
    s.append(letters[Int(rng.next() % UInt64(letters.count))])
  }
  return String(s)
}

/// A small deterministic generator for test data.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// `&proto3pb.TestAllTypes{RepeatedBool: [false], MapInt64NestedType: {1: {}}, MapStringString: {}}`.
func testMessage() -> Value {
  var m = Google_Expr_Proto3_Test_TestAllTypes()
  m.repeatedBool = [false]
  m.mapInt64NestedType = [1: Google_Expr_Proto3_Test_NestedTestAllTypes()]
  return testTypeRegistry().nativeToValue(m)
}

/// `&proto3pb.TestAllTypes{}`.
func emptyMessage() -> Value {
  testTypeRegistry().nativeToValue(Google_Expr_Proto3_Test_TestAllTypes())
}

/// cel-go's `computeCost`: checks the expression, estimates its cost with the test estimator and
/// evaluates it with cost tracking. Returns the actual cost, the estimate and the result.
func computeCost(
  _ expr: String, vars: [VariableDecl] = [], in bindings: [String: Value] = [:],
  options: CostTrackerOptions = CostTrackerOptions(estimator: TestRuntimeCostEstimator())
) throws -> (cost: UInt64, estimate: CostEstimate, result: Value) {
  var env = ProgramEnvironment(provider: testTypeRegistry())
  try env.declare(vars)
  let checked = try env.compile(expr)
  let est = Checker.estimateCost(
    checked, estimator: TestCostEstimator(bytesHint: false),
    options: CostEstimateOptions(presenceTestHasCost: options.presenceTestHasCost))
  var programOptions = ProgramOptions(evalOptions: [.trackCost])
  programOptions.costTracker = options
  let program = try env.program(checked, options: programOptions)
  let result = program.eval(bindings)
  return (try #require(result.actualCost), est, result.value)
}

@Suite struct RuntimeCostTests {
  @Test(arguments: [
    ("1", "2"),
    (#""abc".contains("d")"#, #""def".contains("d")"#),
    ("1 in [4, 5, 6]", "2 in [15, 17, 16]"),
  ])
  func trackCostAdvancedEqual(_ lhs: String, _ rhs: String) throws {
    let lhsCost = try computeCost(lhs)
    let rhsCost = try computeCost(rhs)
    #expect(lhsCost.cost == rhsCost.cost)
  }

  @Test(arguments: [
    ("1", "1 + 2"),
    (#""abc".contains("d")"#, #""abcdhdflsfiehfieubdkwjbdwgxvuyagwsdwdnw qdbgquyidvbwqi".contains("e")"#),
    ("1 in [4, 5, 6]", "1 in [4, 5, 6, 7, 8, 9]"),
  ])
  func trackCostAdvancedSmaller(_ lhs: String, _ rhs: String) throws {
    let lhsCost = try computeCost(lhs)
    let rhsCost = try computeCost(rhs)
    #expect(lhsCost.cost < rhsCost.cost)
  }

  @Test(arguments: runtimeCostCases)
  func runtimeCost(_ tc: RuntimeCostCase) throws {
    var options = CostTrackerOptions(estimator: TestRuntimeCostEstimator())
    if let p = tc.presenceTestHasCost {
      options.presenceTestHasCost = p
    }
    if tc.limit > 0 {
      options.limit = tc.limit
    }
    switch tc.tracker {
    case .containsString?:
      options.overloadTrackers[Overloads.containsString] = { args, _ in
        let strCost = UInt64((Double(actualSize(args[0])) * 0.2).rounded(.up))
        let substrCost = UInt64((Double(actualSize(args[1])) * 0.2).rounded(.up))
        return strCost * substrCost
      }
    case nil:
      break
    }
    let (actual, est, result) = try computeCost(tc.expr, vars: tc.vars, in: tc.in, options: options)
    if case .error(let e) = result, e.message == costLimitExceededMessage {
      #expect(tc.expectExceedsLimit, "unexpected cost limit error at cost \(actual)")
      return
    }
    #expect(!tc.expectExceedsLimit, "no cost limit error for limit \(tc.limit), got cost \(actual)")
    #expect(actual == tc.want)
    #expect(est.min <= actual && actual <= est.max, "cost \(actual) outside the estimate \(est)")
  }
}

let runtimeCostCases: [RuntimeCostCase] = [
  RuntimeCostCase(
    name: "const",
    expr: #""Hello World!""#,
    want: 0),
  RuntimeCostCase(
    name: "identity",
    expr: "input",
    vars: [VariableDecl(name: "input", type: .list(.int))],
    in: ["input": [1, 2]],
    want: 1),
  RuntimeCostCase(
    name: "select: map",
    expr: "input['key']",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .string))],
    in: ["input": ["key": "v"]],
    want: 2),
  RuntimeCostCase(
    name: "select: array index",
    expr: "input[0]",
    vars: [VariableDecl(name: "input", type: .list(.string))],
    in: ["input": ["v"]],
    want: 2),
  RuntimeCostCase(
    name: "select: field",
    expr: "input.single_int32",
    vars: [VariableDecl(name: "input", type: .object("google.expr.proto3.test.TestAllTypes"))],
    in: ["input": testMessage()],
    want: 2),
  RuntimeCostCase(
    name: "expr select: map",
    expr: "input['ke' + 'y']",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .string))],
    in: ["input": ["key": "v"]],
    want: 3),
  RuntimeCostCase(
    name: "expr select: array index",
    expr: "input[3-3]",
    vars: [VariableDecl(name: "input", type: .list(.string))],
    in: ["input": ["v"]],
    want: 3),
  RuntimeCostCase(
    name: "select: field test only no has() cost",
    expr: "has(input.single_int32)",
    vars: [VariableDecl(name: "input", type: .object("google.expr.proto3.test.TestAllTypes"))],
    presenceTestHasCost: false,
    in: ["input": testMessage()],
    want: 1),
  RuntimeCostCase(
    name: "select: field test only",
    expr: "has(input.single_int32)",
    vars: [VariableDecl(name: "input", type: .object("google.expr.proto3.test.TestAllTypes"))],
    in: ["input": testMessage()],
    want: 2),
  RuntimeCostCase(
    name: "select: non-proto field test has() cost",
    expr: "has(input.testAttr.nestedAttr)",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    presenceTestHasCost: true,
    in: ["input": ["testAttr": ["nestedAttr": "0"]]],
    want: 3),
  RuntimeCostCase(
    name: "select: non-proto field test no has() cost",
    expr: "has(input.testAttr.nestedAttr)",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    presenceTestHasCost: false,
    in: ["input": ["testAttr": ["nestedAttr": "0"]]],
    want: 2),
  RuntimeCostCase(
    name: "select: non-proto field test",
    expr: "has(input.testAttr.nestedAttr)",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    in: ["input": ["testAttr": ["nestedAttr": "0"]]],
    want: 3),
  RuntimeCostCase(
    name: "estimated function call",
    expr: "input.getFullYear()",
    vars: [VariableDecl(name: "input", type: .timestamp)],
    in: ["input": .timestamp(CELTimestamp(secondsSinceEpoch: 1_700_000_000))],
    testFuncCost: true,
    want: 8),
  RuntimeCostCase(
    name: "create list",
    expr: "[1, 2, 3]",
    want: 10),
  RuntimeCostCase(
    name: "create struct",
    expr: "google.expr.proto3.test.TestAllTypes{single_int32: 1, single_float: 3.14, single_string: 'str'}",
    want: 40),
  RuntimeCostCase(
    name: "create map",
    expr: #"{"a": 1, "b": 2, "c": 3}"#,
    want: 30),
  RuntimeCostCase(
    name: "all comprehension",
    expr: "input.all(x, true)",
    vars: [VariableDecl(name: "input", type: .list(.object("google.expr.proto3.test.TestAllTypes")))],
    in: ["input": []],
    want: 2),
  RuntimeCostCase(
    name: "nested all comprehension",
    expr: "input.all(x, x.all(y, true))",
    vars: [VariableDecl(name: "input", type: .list(.list(.object("google.expr.proto3.test.TestAllTypes"))))],
    in: ["input": []],
    want: 2),
  RuntimeCostCase(
    name: "all comprehension on literal",
    expr: "[1, 2, 3].all(x, true)",
    want: 20),
  RuntimeCostCase(
    name: "variable cost function",
    expr: "input.matches('[0-9]')",
    vars: [VariableDecl(name: "input", type: .string)],
    in: ["input": .string(randSeq(500))],
    want: 103),
  RuntimeCostCase(
    name: "variable cost function with constant",
    expr: "'123'.matches('[0-9]')",
    want: 2),
  RuntimeCostCase(
    name: "or",
    expr: "false || false",
    want: 0),
  RuntimeCostCase(
    name: "or short-circuit",
    expr: "true || false",
    want: 0),
  RuntimeCostCase(
    name: "or accumulated branch cost",
    expr: "a || b || c || d",
    vars: [VariableDecl(name: "a", type: .bool), VariableDecl(name: "b", type: .bool), VariableDecl(name: "c", type: .bool), VariableDecl(name: "d", type: .bool)],
    in: ["a": false, "b": false, "c": false, "d": false],
    want: 4),
  RuntimeCostCase(
    name: "and",
    expr: "true && false",
    want: 0),
  RuntimeCostCase(
    name: "and short-circuit",
    expr: "false && true",
    want: 0),
  RuntimeCostCase(
    name: "and accumulated branch cost",
    expr: "a && b && c && d",
    vars: [VariableDecl(name: "a", type: .bool), VariableDecl(name: "b", type: .bool), VariableDecl(name: "c", type: .bool), VariableDecl(name: "d", type: .bool)],
    in: ["a": true, "b": true, "c": true, "d": true],
    want: 4),
  RuntimeCostCase(
    name: "lt",
    expr: "1 < 2",
    want: 1),
  RuntimeCostCase(
    name: "lte",
    expr: "1 <= 2",
    want: 1),
  RuntimeCostCase(
    name: "eq",
    expr: "1 == 2",
    want: 1),
  RuntimeCostCase(
    name: "gt",
    expr: "2 > 1",
    want: 1),
  RuntimeCostCase(
    name: "gte",
    expr: "2 >= 1",
    want: 1),
  RuntimeCostCase(
    name: "in",
    expr: "2 in [1, 2, 3]",
    want: 13),
  RuntimeCostCase(
    name: "plus",
    expr: "1 + 1",
    want: 1),
  RuntimeCostCase(
    name: "minus",
    expr: "1 - 1",
    want: 1),
  RuntimeCostCase(
    name: "/",
    expr: "1 / 1",
    want: 1),
  RuntimeCostCase(
    name: "/",
    expr: "1 * 1",
    want: 1),
  RuntimeCostCase(
    name: "%",
    expr: "1 % 1",
    want: 1),
  RuntimeCostCase(
    name: "ternary",
    expr: "true ? 1 : 2",
    want: 0),
  RuntimeCostCase(
    name: "string size",
    expr: #"size("123")"#,
    want: 1),
  RuntimeCostCase(
    name: "str eq str",
    expr: "'12345678901234567890' == '123456789012345678901234567890'",
    want: 2),
  RuntimeCostCase(
    name: "bytes to string conversion",
    expr: "string(input)",
    vars: [VariableDecl(name: "input", type: .bytes)],
    in: ["input": .bytes(Array(randSeq(500).utf8))],
    want: 51),
  RuntimeCostCase(
    name: "string to bytes conversion",
    expr: "bytes(input)",
    vars: [VariableDecl(name: "input", type: .string)],
    in: ["input": .string(randSeq(500))],
    want: 51),
  RuntimeCostCase(
    name: "int to string conversion",
    expr: "string(1)",
    want: 1),
  RuntimeCostCase(
    name: "contains",
    expr: "input.contains(arg1)",
    vars: [VariableDecl(name: "input", type: .string), VariableDecl(name: "arg1", type: .string)],
    in: ["input": .string(randSeq(500)), "arg1": .string(randSeq(500))],
    want: 2502),
  RuntimeCostCase(
    name: "matches",
    expr: #"input.matches('\\d+a\\d+b')"#,
    vars: [VariableDecl(name: "input", type: .string)],
    in: ["input": .string(randSeq(500)), "arg1": .string(randSeq(500))],
    want: 103),
  RuntimeCostCase(
    name: "matches global",
    expr: #"matches(input, '\\d+a\\d+b')"#,
    vars: [VariableDecl(name: "input", type: .string)],
    in: ["input": .string(randSeq(500))],
    want: 103),
  RuntimeCostCase(
    name: "startsWith",
    expr: "input.startsWith(arg1)",
    vars: [VariableDecl(name: "input", type: .string), VariableDecl(name: "arg1", type: .string)],
    in: ["input": "idc", "arg1": .string(randSeq(500))],
    want: 52),
  RuntimeCostCase(
    name: "endsWith",
    expr: "input.endsWith(arg1)",
    vars: [VariableDecl(name: "input", type: .string), VariableDecl(name: "arg1", type: .string)],
    in: ["input": "idc", "arg1": .string(randSeq(500))],
    want: 52),
  RuntimeCostCase(
    name: "size receiver",
    expr: "input.size()",
    vars: [VariableDecl(name: "input", type: .string)],
    in: ["input": "500", "arg1": "500"],
    want: 2),
  RuntimeCostCase(
    name: "size",
    expr: "size(input)",
    vars: [VariableDecl(name: "input", type: .string)],
    in: ["input": "500", "arg1": "500"],
    want: 2),
  RuntimeCostCase(
    name: "ternary eval",
    expr: "(x > 2 ? input1 : input2).all(y, true)",
    vars: [VariableDecl(name: "x", type: .int), VariableDecl(name: "input1", type: .list(.object("google.expr.proto3.test.TestAllTypes"))), VariableDecl(name: "input2", type: .list(.object("google.expr.proto3.test.TestAllTypes")))],
    in: ["input1": [emptyMessage()], "input2": [emptyMessage()], "x": 1],
    want: 6),
  RuntimeCostCase(
    name: "ternary eval trivial, true",
    expr: "true ? false : 1 > 3",
    in: [:],
    want: 0),
  RuntimeCostCase(
    name: "ternary eval trivial, false",
    expr: "false ? false : 1 > 3",
    in: [:],
    want: 1),
  RuntimeCostCase(
    name: "comprehension over map",
    expr: "input.all(k, input[k].single_int32 > 3)",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes")))],
    in: ["input": ["val": emptyMessage()]],
    want: 9),
  RuntimeCostCase(
    name: "comprehension over nested map of maps",
    expr: "input.all(k, input[k].all(x, true))",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    in: ["input": [:]],
    want: 2),
  RuntimeCostCase(
    name: "string size of map keys",
    expr: "input.all(k, k.contains(k))",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    in: ["input": [:]],
    want: 2),
  RuntimeCostCase(
    name: "comprehension variable shadowing",
    expr: "input.all(k, input[k].all(k, true) && k.contains(k))",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    in: ["input": [:]],
    want: 2),
  RuntimeCostCase(
    name: "comprehension variable shadowing",
    expr: "input.all(k, input[k].all(k, true) && k.contains(k))",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    in: ["input": [:]],
    want: 2),
  RuntimeCostCase(
    name: "list concat",
    expr: "(list1 + list2).all(x, true)",
    vars: [VariableDecl(name: "list1", type: .list(.int)), VariableDecl(name: "list2", type: .list(.int))],
    in: ["list1": [], "list2": []],
    want: 4),
  RuntimeCostCase(
    name: "str concat",
    expr: #""abcdefg".contains(str1 + str2)"#,
    vars: [VariableDecl(name: "str1", type: .string), VariableDecl(name: "str2", type: .string)],
    in: ["str1": "val1", "str2": "val2222222"],
    want: 6),
  RuntimeCostCase(
    name: "str concat custom cost tracker",
    expr: #""abcdefg".contains(str1 + str2)"#,
    vars: [VariableDecl(name: "str1", type: .string), VariableDecl(name: "str2", type: .string)],
    tracker: .containsString,
    in: ["str1": "val1", "str2": "val2222222"],
    want: 10),
  RuntimeCostCase(
    name: "at limit",
    expr: #""abcdefg".contains(str1 + str2)"#,
    vars: [VariableDecl(name: "str1", type: .string), VariableDecl(name: "str2", type: .string)],
    in: ["str1": "val1", "str2": "val2222222"],
    limit: 6,
    want: 6),
  RuntimeCostCase(
    name: "above limit",
    expr: #""abcdefg".contains(str1 + str2)"#,
    vars: [VariableDecl(name: "str1", type: .string), VariableDecl(name: "str2", type: .string)],
    in: ["str1": "val1", "str2": "val2222222"],
    limit: 5,
    expectExceedsLimit: true,
    want: 0),
  RuntimeCostCase(
    name: "ternary as operand",
    expr: "(1 > 2 ? 5 : 3) > 1",
    in: [:],
    want: 2),
  RuntimeCostCase(
    name: "ternary as operand",
    expr: "(1 > 2 || 2 > 1) == true",
    in: [:],
    want: 3),
  RuntimeCostCase(
    name: "list map literal",
    expr: "[{'k1': 1}, {'k2': 2}].all(x, true)",
    in: [:],
    want: 77),
  RuntimeCostCase(
    name: "list map literal",
    expr: "[{'k1': 1}, {'k2': 2}].all(x, true)",
    in: [:],
    want: 77),
  RuntimeCostCase(
    name: ".filter list literal",
    expr: "[1,2,3,4,5].filter(x, x % 2 == 0)",
    in: [:],
    want: 62),
  RuntimeCostCase(
    name: ".map list literal",
    expr: "[1,2,3,4,5].map(x, x)",
    in: [:],
    want: 86),
  RuntimeCostCase(
    name: ".map.filter list literal",
    expr: "[1,2,3,4,5].map(x, x).filter(x, x % 2 == 0)",
    in: [:],
    want: 138),
  RuntimeCostCase(
    name: ".map.exists list literal",
    expr: "[1,2,3,4,5].map(x, x).exists(x, x == 5) == true",
    in: [:],
    want: 118),
  RuntimeCostCase(
    name: ".map.map list literal",
    expr: "[1,2,3,4,5].map(x, x).map(x, x)",
    in: [:],
    want: 162),
  RuntimeCostCase(
    name: ".map.map list literal",
    expr: "[1,2,3,4,5].map(x, [x, x]).filter(z, z.size() == 2)",
    in: [:],
    want: 232),
  RuntimeCostCase(
    name: "comprehension on nested list",
    expr: "[1,2,3,4,5].map(x, [x, x]).all(y, y.all(y, y == 1))",
    want: 171),
  RuntimeCostCase(
    name: "comprehension size",
    expr: "[1,2,3,4,5].map(x, x).map(x, x) + [1]",
    want: 173),
  RuntimeCostCase(
    name: "nested comprehension",
    expr: "[1,2,3].all(i, i in [1,2,3].map(j, j + j))",
    want: 86),

]

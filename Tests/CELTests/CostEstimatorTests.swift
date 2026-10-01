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
// Ported from cel-go checker/cost_test.go (TestCost and its test estimator) and
// common/cost/cost_test.go.

import Testing

@testable import CEL

/// One row of cel-go's `TestCost` table.
struct CostCase: Sendable, CustomTestStringConvertible {
  enum Estimator: Sendable {
    case containsString, listBytesMax
  }

  var name: String
  var expr: String
  var vars: [VariableDecl] = []
  var hints: [String: UInt64] = [:]
  var presenceTestHasCost: Bool? = nil
  var overloadEstimator: Estimator? = nil
  var wanted: CostEstimate

  var testDescription: String { "\(name): \(expr)" }
}

/// cel-go's checker `testCostEstimator`: size hints by dot-joined path, at most 12 bytes for any
/// bytes value, and a fixed cost of 7 for `timestamp.getFullYear()`.
struct TestCostEstimator: CostEstimator {
  var hints: [String: UInt64] = [:]
  var bytesHint = true

  func estimateSize(_ element: CostAstNode) -> SizeEstimate? {
    if let l = hints[element.path.joined(separator: ".")] {
      return SizeEstimate(min: 0, max: l)
    }
    if bytesHint && element.type == .bytes {
      return SizeEstimate(min: 0, max: 12)
    }
    return nil
  }

  func estimateCallCost(function: String, overloadID: String, target: CostAstNode?, args: [CostAstNode])
    -> CallEstimate?
  {
    overloadID == Overloads.timestampToYear ? CallEstimate(cost: .fixed(7)) : nil
  }
}

/// cel-go's `estimateSize` / `sizeEstimate` test helpers.
func testSizeEstimate(_ estimator: any CostEstimator, _ node: CostAstNode) -> SizeEstimate {
  node.computedSize ?? estimator.estimateSize(node) ?? .unknown
}

/// cel-go's `listElementNode`: a node for the element type of a list node, with the path when known.
func listElementNode(_ list: CostAstNode) -> CostAstNode? {
  guard let elem = list.type.parameters.first else {
    return nil
  }
  return CostAstNode(path: list.path.isEmpty ? [] : list.path + ["@items"], type: elem, expr: nil)
}

extension CostCase.Estimator {
  var options: CostEstimateOptions {
    switch self {
    case .containsString:
      return CostEstimateOptions(overloadEstimators: [
        Overloads.containsString: { estimator, target, args in
          guard let target, args.count == 1 else {
            return nil
          }
          let strSize = testSizeEstimate(estimator, target).multipliedByCostFactor(0.2)
          let subSize = testSizeEstimate(estimator, args[0]).multipliedByCostFactor(0.2)
          return CallEstimate(cost: strSize.multiplied(by: subSize))
        }
      ])
    case .listBytesMax:
      return CostEstimateOptions(overloadEstimators: [
        "list_bytes_max": { estimator, target, _ in
          guard let target else {
            return nil
          }
          // One per element compared, plus the traversal of string or bytes elements.
          var elCost = CostEstimate(min: 1, max: 1)
          if let elNode = listElementNode(target) {
            let k = elNode.type.kind
            if k == .string || k == .bytes {
              let sz = testSizeEstimate(estimator, elNode)
              elCost = elCost.adding(sz.multipliedByCostFactor(Cost.stringTraversalCostFactor))
            }
            return CallEstimate(cost: testSizeEstimate(estimator, target).multiplied(byCost: elCost))
          }
          return nil
        }
      ])
    }
  }
}

/// The environment of cel-go's cost tests: the standard library, `max` on `list(bytes)` and
/// cel-go's proto3 test messages.
func costTestEnvironment(_ vars: [VariableDecl]) throws -> ProgramEnvironment {
  var env = ProgramEnvironment(provider: testTypeRegistry())
  let maxFunc = try FunctionDecl(
    "max", .memberOverload("list_bytes_max", argTypes: [.list(.bytes)], resultType: .bytes))
  try env.declare(vars, functions: [maxFunc])
  return env
}

@Suite struct CostEstimatorTests {
  @Test(arguments: costCases)
  func cost(_ tc: CostCase) throws {
    let env = try costTestEnvironment(tc.vars)
    let checked = try env.compile(tc.expr)
    var options = tc.overloadEstimator?.options ?? CostEstimateOptions()
    if let p = tc.presenceTestHasCost {
      options.presenceTestHasCost = p
    }
    let est = Checker.estimateCost(checked, estimator: TestCostEstimator(hints: tc.hints), options: options)
    #expect(est == tc.wanted)
  }

  @Test(arguments: [
    (0, 0, [], 0), (2, 3, [], 5), (1, 2, [3, 4], 10), (.max, 0, [], .max), (.max, 1, [], .max),
    (.max - 5, 10, [], .max), (1, 2, [.max], .max), (.max, .max, [.max], .max),
  ] as [(UInt64, UInt64, [UInt64], UInt64)])
  func safeAdd(_ x: UInt64, _ y: UInt64, _ rest: [UInt64], _ want: UInt64) {
    var sum = Cost.safeAdd(x, y)
    for r in rest {
      sum = Cost.safeAdd(sum, r)
    }
    #expect(sum == want)
  }

  @Test(arguments: [
    (0, 0, 0), (.max, 0, 0), (3, 4, 12), (.max, 1, .max), (.max, 2, .max),
    (UInt64(UInt32.max), UInt64(UInt32.max) * 2, .max),
  ] as [(UInt64, UInt64, UInt64)])
  func safeMultiply(_ x: UInt64, _ y: UInt64, _ want: UInt64) {
    #expect(Cost.safeMultiply(x, y) == want)
  }

  @Test(arguments: [
    (0, 0.1, 0), (100, 0, 0), (15, 0.1, 2), (10, 0.1, 1), (10, 3, 30), (.max, 2, .max),
    (.max, 0.1, 1_844_674_407_370_955_264), (10, -1, 0),
  ] as [(UInt64, Double, UInt64)])
  func safeMultiplyByFactor(_ x: UInt64, _ factor: Double, _ want: UInt64) {
    #expect(Cost.safeMultiplyByFactor(x, factor) == want)
  }

  @Test(arguments: [
    (0, 0), (-1.5, 0), (.nan, 0), (0.1, 1), (2.5, 3), (3.0, 3), (.infinity, .max),
    (18_446_744_073_709_551_616.0, .max), (9_223_372_036_854_775_808.0, 1 << 63),
  ] as [(Double, UInt64)])
  func safeCeil(_ x: Double, _ want: UInt64) {
    #expect(Cost.safeCeil(x) == want)
  }
}

let costCases: [CostCase] = [
  CostCase(
    name: "const",
    expr: #""Hello World!""#,
    wanted: .zero),
  CostCase(
    name: "identity",
    expr: "input",
    vars: [VariableDecl(name: "input", type: .list(.int))],
    wanted: CostEstimate(min: 1, max: 1)),
  CostCase(
    name: "select: map",
    expr: "input['key']",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .string))],
    wanted: CostEstimate(min: 2, max: 2)),
  CostCase(
    name: "select: field",
    expr: "input.single_int32",
    vars: [VariableDecl(name: "input", type: .object("google.expr.proto3.test.TestAllTypes"))],
    wanted: CostEstimate(min: 2, max: 2)),
  CostCase(
    name: "select: field test only no has() cost",
    expr: "has(input.single_int32)",
    vars: [VariableDecl(name: "input", type: .object("google.expr.proto3.test.TestAllTypes"))],
    presenceTestHasCost: false,
    wanted: CostEstimate(min: 1, max: 1)),
  CostCase(
    name: "select: field test only",
    expr: "has(input.single_int32)",
    vars: [VariableDecl(name: "input", type: .object("google.expr.proto3.test.TestAllTypes"))],
    wanted: CostEstimate(min: 2, max: 2)),
  CostCase(
    name: "select: non-proto field test has() cost",
    expr: "has(input.testAttr.nestedAttr)",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    presenceTestHasCost: true,
    wanted: CostEstimate(min: 3, max: 3)),
  CostCase(
    name: "select: non-proto field test no has() cost",
    expr: "has(input.testAttr.nestedAttr)",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    presenceTestHasCost: false,
    wanted: CostEstimate(min: 2, max: 2)),
  CostCase(
    name: "select: non-proto field test",
    expr: "has(input.testAttr.nestedAttr)",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    wanted: CostEstimate(min: 3, max: 3)),
  CostCase(
    name: "estimated function call",
    expr: "input.getFullYear()",
    vars: [VariableDecl(name: "input", type: .timestamp)],
    wanted: CostEstimate(min: 8, max: 8)),
  CostCase(
    name: "create list",
    expr: "[1, 2, 3]",
    wanted: CostEstimate(min: 10, max: 10)),
  CostCase(
    name: "create struct",
    expr: "google.expr.proto3.test.TestAllTypes{single_int32: 1, single_float: 3.14, single_string: 'str'}",
    wanted: CostEstimate(min: 40, max: 40)),
  CostCase(
    name: "create map",
    expr: #"{"a": 1, "b": 2, "c": 3}"#,
    wanted: CostEstimate(min: 30, max: 30)),
  CostCase(
    name: "all comprehension",
    expr: "input.all(x, true)",
    vars: [VariableDecl(name: "input", type: .list(.object("google.expr.proto3.test.TestAllTypes")))],
    hints: ["input": 100],
    wanted: CostEstimate(min: 2, max: 302)),
  CostCase(
    name: "nested all comprehension",
    expr: "input.all(x, x.all(y, true))",
    vars: [VariableDecl(name: "input", type: .list(.list(.object("google.expr.proto3.test.TestAllTypes"))))],
    hints: ["input": 50, "input.@items": 10],
    wanted: CostEstimate(min: 2, max: 1752)),
  CostCase(
    name: "all comprehension on literal",
    expr: "[1, 2, 3].all(x, true)",
    wanted: CostEstimate(min: 20, max: 20)),
  CostCase(
    name: "variable cost function",
    expr: "input.matches('[0-9]')",
    vars: [VariableDecl(name: "input", type: .string)],
    hints: ["input": 500],
    wanted: CostEstimate(min: 3, max: 103)),
  CostCase(
    name: "variable cost function with constant",
    expr: "'123'.matches('[0-9]')",
    wanted: CostEstimate(min: 2, max: 2)),
  CostCase(
    name: "or",
    expr: "true || false",
    wanted: .zero),
  CostCase(
    name: "or accumulated branch cost",
    expr: "a || b || c || d",
    vars: [VariableDecl(name: "a", type: .bool), VariableDecl(name: "b", type: .bool), VariableDecl(name: "c", type: .bool), VariableDecl(name: "d", type: .bool)],
    wanted: CostEstimate(min: 1, max: 4)),
  CostCase(
    name: "and",
    expr: "true && false",
    wanted: .zero),
  CostCase(
    name: "and accumulated branch cost",
    expr: "a && b && c && d",
    vars: [VariableDecl(name: "a", type: .bool), VariableDecl(name: "b", type: .bool), VariableDecl(name: "c", type: .bool), VariableDecl(name: "d", type: .bool)],
    wanted: CostEstimate(min: 1, max: 4)),
  CostCase(
    name: "lt",
    expr: "1 < 2",
    wanted: .fixed(1)),
  CostCase(
    name: "lte",
    expr: "1 <= 2",
    wanted: .fixed(1)),
  CostCase(
    name: "eq",
    expr: "1 == 2",
    wanted: .fixed(1)),
  CostCase(
    name: "gt",
    expr: "2 > 1",
    wanted: .fixed(1)),
  CostCase(
    name: "gte",
    expr: "2 >= 1",
    wanted: .fixed(1)),
  CostCase(
    name: "in",
    expr: "2 in [1, 2, 3]",
    wanted: CostEstimate(min: 13, max: 13)),
  CostCase(
    name: "plus",
    expr: "1 + 1",
    wanted: .fixed(1)),
  CostCase(
    name: "minus",
    expr: "1 - 1",
    wanted: .fixed(1)),
  CostCase(
    name: "/",
    expr: "1 / 1",
    wanted: .fixed(1)),
  CostCase(
    name: "/",
    expr: "1 * 1",
    wanted: .fixed(1)),
  CostCase(
    name: "%",
    expr: "1 % 1",
    wanted: .fixed(1)),
  CostCase(
    name: "ternary",
    expr: "true ? 1 : 2",
    wanted: .zero),
  CostCase(
    name: "string size",
    expr: #"size("123")"#,
    wanted: .fixed(1)),
  CostCase(
    name: "bytes size",
    expr: #"size(b"123")"#,
    wanted: .fixed(1)),
  CostCase(
    name: "bytes to string conversion",
    expr: "string(input)",
    vars: [VariableDecl(name: "input", type: .bytes)],
    hints: ["input": 500],
    wanted: CostEstimate(min: 1, max: 51)),
  CostCase(
    name: "bytes to string conversion equality",
    expr: "string(input) == string(input)",
    vars: [VariableDecl(name: "input", type: .bytes)],
    hints: ["input": 500],
    wanted: CostEstimate(min: 3, max: 152)),
  CostCase(
    name: "string to bytes conversion",
    expr: "bytes(input)",
    vars: [VariableDecl(name: "input", type: .string)],
    hints: ["input": 500],
    wanted: CostEstimate(min: 1, max: 51)),
  CostCase(
    name: "string to bytes conversion equality",
    expr: "bytes(input) == bytes(input)",
    vars: [VariableDecl(name: "input", type: .string)],
    hints: ["input": 500],
    wanted: CostEstimate(min: 3, max: 302)),
  CostCase(
    name: "int to string conversion",
    expr: "string(1)",
    wanted: CostEstimate(min: 1, max: 1)),
  CostCase(
    name: "contains",
    expr: "input.contains(arg1)",
    vars: [VariableDecl(name: "input", type: .string), VariableDecl(name: "arg1", type: .string)],
    hints: ["input": 500, "arg1": 500],
    wanted: CostEstimate(min: 2, max: 2502)),
  CostCase(
    name: "matches",
    expr: #"input.matches('\\d+a\\d+b')"#,
    vars: [VariableDecl(name: "input", type: .string)],
    hints: ["input": 500],
    wanted: CostEstimate(min: 3, max: 103)),
  CostCase(
    name: "matches global",
    expr: #"matches(input, '\\d+a\\d+b')"#,
    vars: [VariableDecl(name: "input", type: .string)],
    hints: ["input": 500],
    wanted: CostEstimate(min: 3, max: 103)),
  CostCase(
    name: "startsWith",
    expr: "input.startsWith(arg1)",
    vars: [VariableDecl(name: "input", type: .string), VariableDecl(name: "arg1", type: .string)],
    hints: ["arg1": 500],
    wanted: CostEstimate(min: 2, max: 52)),
  CostCase(
    name: "endsWith",
    expr: "input.endsWith(arg1)",
    vars: [VariableDecl(name: "input", type: .string), VariableDecl(name: "arg1", type: .string)],
    hints: ["arg1": 500],
    wanted: CostEstimate(min: 2, max: 52)),
  CostCase(
    name: "size receiver",
    expr: "input.size()",
    vars: [VariableDecl(name: "input", type: .string)],
    wanted: CostEstimate(min: 2, max: 2)),
  CostCase(
    name: "size",
    expr: "size(input)",
    vars: [VariableDecl(name: "input", type: .string)],
    wanted: CostEstimate(min: 2, max: 2)),
  CostCase(
    name: "ternary eval",
    expr: "(x > 2 ? input1 : input2).all(y, true)",
    vars: [VariableDecl(name: "x", type: .int), VariableDecl(name: "input1", type: .list(.object("google.expr.proto3.test.TestAllTypes"))), VariableDecl(name: "input2", type: .list(.object("google.expr.proto3.test.TestAllTypes")))],
    hints: ["input1": 1, "input2": 1],
    wanted: CostEstimate(min: 4, max: 7)),
  CostCase(
    name: "comprehension over map",
    expr: "input.all(k, input[k].single_int32 > 3)",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes")))],
    hints: ["input": 10],
    wanted: CostEstimate(min: 2, max: 82)),
  CostCase(
    name: "comprehension over nested map of maps",
    expr: "input.all(k, input[k].all(x, true))",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    hints: ["input": 5, "input.@values": 10],
    wanted: CostEstimate(min: 2, max: 187)),
  CostCase(
    name: "string size of map keys",
    expr: "input.all(k, k.contains(k))",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    hints: ["input": 5, "input.@keys": 10],
    wanted: CostEstimate(min: 2, max: 32)),
  CostCase(
    name: "comprehension variable shadowing",
    expr: "input.all(k, input[k].all(k, true) && k.contains(k))",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    hints: ["input": 2, "input.@values": 2, "input.@keys": 5],
    wanted: CostEstimate(min: 2, max: 34)),
  CostCase(
    name: "comprehension variable shadowing",
    expr: "input.all(k, input[k].all(k, true) && k.contains(k))",
    vars: [VariableDecl(name: "input", type: .map(key: .string, value: .map(key: .string, value: .object("google.expr.proto3.test.TestAllTypes"))))],
    hints: ["input": 2, "input.@values": 2, "input.@keys": 5],
    wanted: CostEstimate(min: 2, max: 34)),
  CostCase(
    name: "list concat",
    expr: "(list1 + list2).all(x, true)",
    vars: [VariableDecl(name: "list1", type: .list(.int)), VariableDecl(name: "list2", type: .list(.int))],
    hints: ["list1": 10, "list2": 10],
    wanted: CostEstimate(min: 4, max: 64)),
  CostCase(
    name: "str concat",
    expr: #""abcdefg".contains(str1 + str2)"#,
    vars: [VariableDecl(name: "str1", type: .string), VariableDecl(name: "str2", type: .string)],
    hints: ["str1": 10, "str2": 10],
    wanted: CostEstimate(min: 2, max: 6)),
  CostCase(
    name: "str concat custom cost estimate",
    expr: #""abcdefg".contains(str1 + str2)"#,
    vars: [VariableDecl(name: "str1", type: .string), VariableDecl(name: "str2", type: .string)],
    hints: ["str1": 10, "str2": 10],
    overloadEstimator: .containsString,
    wanted: CostEstimate(min: 2, max: 12)),
  CostCase(
    name: "list size comparison",
    expr: "list1.size() == list2.size()",
    vars: [VariableDecl(name: "list1", type: .list(.int)), VariableDecl(name: "list2", type: .list(.int))],
    wanted: CostEstimate(min: 5, max: 5)),
  CostCase(
    name: "list size from ternary",
    expr: "x > y ? list1.size() : list2.size()",
    vars: [VariableDecl(name: "x", type: .int), VariableDecl(name: "y", type: .int), VariableDecl(name: "list1", type: .list(.int)), VariableDecl(name: "list2", type: .list(.int))],
    wanted: CostEstimate(min: 5, max: 5)),
  CostCase(
    name: "list size from concat",
    expr: "([x, y] + list1 + list2).size()",
    vars: [VariableDecl(name: "x", type: .int), VariableDecl(name: "y", type: .int), VariableDecl(name: "list1", type: .list(.int)), VariableDecl(name: "list2", type: .list(.int))],
    hints: ["list1": 10, "list2": 20],
    wanted: CostEstimate(min: 17, max: 17)),
  CostCase(
    name: "list cost tracking through comprehension",
    expr: "[list1, list2].exists(l, l.exists(v, v.startsWith('hi')))",
    vars: [VariableDecl(name: "list1", type: .list(.string)), VariableDecl(name: "list2", type: .list(.string))],
    hints: ["list1": 10, "list1.@items": 64, "list2": 20, "list2.@items": 128],
    wanted: CostEstimate(min: 21, max: 265)),
  CostCase(
    name: "str endsWith equality",
    expr: #"str1.endsWith("abcdefghijklmnopqrstuvwxyz") == str2.endsWith("abcdefghijklmnopqrstuvwxyz")"#,
    vars: [VariableDecl(name: "str1", type: .string), VariableDecl(name: "str2", type: .string)],
    wanted: CostEstimate(min: 9, max: 9)),
  CostCase(
    name: "nested subexpression operators",
    expr: "((5 != 6) == (1 == 2)) == ((3 <= 4) == (9 != 9))",
    wanted: CostEstimate(min: 7, max: 7)),
  CostCase(
    name: "str size estimate",
    expr: "string(timestamp1) == string(timestamp2)",
    vars: [VariableDecl(name: "timestamp1", type: .timestamp), VariableDecl(name: "timestamp2", type: .timestamp)],
    wanted: CostEstimate(min: 5, max: 1844674407370955268)),
  CostCase(
    name: "timestamp equality check",
    expr: "timestamp1 == timestamp2",
    vars: [VariableDecl(name: "timestamp1", type: .timestamp), VariableDecl(name: "timestamp2", type: .timestamp)],
    wanted: CostEstimate(min: 3, max: 3)),
  CostCase(
    name: "duration inequality check",
    expr: "duration1 != duration2",
    vars: [VariableDecl(name: "duration1", type: .duration), VariableDecl(name: "duration2", type: .duration)],
    wanted: CostEstimate(min: 3, max: 3)),
  CostCase(
    name: ".filter list literal",
    expr: "[1,2,3,4,5].filter(x, x % 2 == 0)",
    wanted: CostEstimate(min: 41, max: 101)),
  CostCase(
    name: ".map list literal",
    expr: "[1,2,3,4,5].map(x, x)",
    wanted: CostEstimate(min: 86, max: 86)),
  CostCase(
    name: ".map.filter list literal",
    expr: "[1,2,3,4,5].map(x, x).filter(x, x % 2 == 0)",
    wanted: CostEstimate(min: 117, max: 177)),
  CostCase(
    name: ".map.exists list literal",
    expr: "[1,2,3,4,5].map(x, x).exists(x, x == 5) == true",
    wanted: CostEstimate(min: 108, max: 118)),
  CostCase(
    name: ".map.map list literal",
    expr: "[1,2,3,4,5].map(x, x).map(x, x)",
    wanted: CostEstimate(min: 162, max: 162)),
  CostCase(
    name: ".map list literal selection",
    expr: "[1,2,3,4,5].map(x, x)[4]",
    wanted: CostEstimate(min: 87, max: 87)),
  CostCase(
    name: "nested array selection",
    expr: "[[1,2],[1,2],[1,2],[1,2],[1,2]][4]",
    wanted: CostEstimate(min: 61, max: 61)),
  CostCase(
    name: "nested map selection",
    expr: "{'a': [1,2], 'b': [1,2], 'c': [1,2], 'd': [1,2], 'e': [1,2]}.b",
    wanted: CostEstimate(min: 81, max: 81)),
  CostCase(
    name: "comprehension on nested list",
    expr: "[[1, 1], [2, 2], [3, 3], [4, 4], [5, 5]].all(y, y.all(y, y == 1))",
    wanted: CostEstimate(min: 76, max: 136)),
  CostCase(
    name: "comprehension on transformed nested list",
    expr: "[1,2,3,4,5].map(x, [x, x]).all(y, y.all(y, y == 1))",
    wanted: CostEstimate(min: 157, max: 217)),
  CostCase(
    name: "comprehension on nested literal list",
    expr: #"["a", "ab", "abc", "abcd", "abcde"].map(x, [x, x]).all(y, y.all(y, y.startsWith('a')))"#,
    wanted: CostEstimate(min: 157, max: 217)),
  CostCase(
    name: "comprehension on nested variable list",
    expr: "input.map(x, [x, x]).all(y, y.all(y, y.startsWith('a')))",
    vars: [VariableDecl(name: "input", type: .list(.string))],
    hints: ["input": 5, "input.@items": 10],
    wanted: CostEstimate(min: 13, max: 208)),
  CostCase(
    name: "comprehension chaining with concat",
    expr: "[1,2,3,4,5].map(x, x).map(x, x) + [1]",
    wanted: CostEstimate(min: 173, max: 173)),
  CostCase(
    name: "nested comprehension",
    expr: "[1,2,3].all(i, i in [1,2,3].map(j, j + j))",
    wanted: CostEstimate(min: 20, max: 230)),
  CostCase(
    name: "nested dyn comprehension",
    expr: "dyn([1,2,3]).all(i, i in dyn([1,2,3]).map(j, j + j))",
    wanted: CostEstimate(min: 21, max: 234)),
  CostCase(
    name: "literal map access",
    expr: "{'hello': 'hi'}['hello'] != {'hello': 'bye'}['hello']",
    wanted: CostEstimate(min: 63, max: 63)),
  CostCase(
    name: "literal list access",
    expr: "['hello', 'hi'][0] != ['hello', 'bye'][1]",
    wanted: CostEstimate(min: 23, max: 23)),
  CostCase(
    name: "type call",
    expr: "type(1)",
    wanted: CostEstimate(min: 1, max: 1)),
  CostCase(
    name: "type call variable",
    expr: "type(self.val1)",
    vars: [VariableDecl(name: "self", type: .map(key: .string, value: .int))],
    wanted: CostEstimate(min: 3, max: 3)),
  CostCase(
    name: "type call variable equality",
    expr: "type(self.val1) == int",
    vars: [VariableDecl(name: "self", type: .map(key: .string, value: .int))],
    wanted: CostEstimate(min: 5, max: 1844674407370955268)),
  CostCase(
    name: "type literal equality cost",
    expr: "type(1) == int",
    wanted: CostEstimate(min: 3, max: 1844674407370955266)),
  CostCase(
    name: "type variable equality cost",
    expr: "type(1) == int",
    wanted: CostEstimate(min: 3, max: 1844674407370955266)),
  CostCase(
    name: "namespace variable equality",
    expr: "self.val1 == 1.0",
    vars: [VariableDecl(name: "self.val1", type: .double)],
    wanted: CostEstimate(min: 2, max: 2)),
  CostCase(
    name: "simple map variable equality",
    expr: "self.val1 == 1.0",
    vars: [VariableDecl(name: "self", type: .map(key: .string, value: .double))],
    wanted: CostEstimate(min: 3, max: 3)),
  CostCase(
    name: "date-time math",
    expr: "self.val1 == timestamp('2011-08-18T00:00:00.000+01:00') + duration('19h3m37s10ms')",
    vars: [VariableDecl(name: "self", type: .map(key: .string, value: .timestamp))],
    wanted: .fixed(6)),
  CostCase(
    name: "date-time math self-conversion",
    expr: "timestamp(self.val1) == timestamp('2011-08-18T00:00:00.000+01:00') + duration('19h3m37s10ms')",
    vars: [VariableDecl(name: "self", type: .map(key: .string, value: .timestamp))],
    wanted: .fixed(7)),
  CostCase(
    name: "boolean vars equal",
    expr: "self.val1 != self.val2",
    vars: [VariableDecl(name: "self", type: .map(key: .string, value: .bool))],
    wanted: .fixed(5)),
  CostCase(
    name: "boolean var equals literal",
    expr: "self.val1 != true",
    vars: [VariableDecl(name: "self", type: .map(key: .string, value: .bool))],
    wanted: .fixed(3)),
  CostCase(
    name: "double var equals literal",
    expr: "self.val1 == 1.0",
    vars: [VariableDecl(name: "self", type: .map(key: .string, value: .double))],
    wanted: .fixed(3)),
  CostCase(
    name: "bytes list max",
    expr: "[bytes('012345678901'), bytes('012345678901'), bytes('012345678901'), bytes('012345678901'), bytes('012345678901')].max()",
    overloadEstimator: .listBytesMax,
    wanted: CostEstimate(min: 25, max: 35)),
]

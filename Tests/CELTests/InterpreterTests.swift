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
// Ported from cel-go interpreter/interpreter_test.go: the testData table and TestInterpreter's
// evaluation in the default, optimized, exhaustive and state-tracking modes. The cases with protobuf
// messages are in InterpreterProtoCases.swift.

import Testing

@testable import CEL

struct InterpreterCase: Sendable, CustomTestStringConvertible {
  var name: String
  var expr: String
  var container: String = ""
  var abbrevs: [String] = []
  var vars: [VariableDecl] = []
  var funcs: [FunctionDecl] = []
  var unchecked = false
  var input: [String: Value] = [:]
  /// Unknown attribute patterns: evaluates with the partial attribute factory.
  var unknowns: [AttributePattern]?
  var errorOnBadPresenceTest = false
  /// Registers cel-go's proto2 and proto3 test messages (cel-go `typeOpts` with `ProtoTypeDefs`).
  var protos = false
  /// Resolves message fields by their JSON names (cel-go `types.JSONFieldNames(true)`).
  var jsonFieldNames = false
  var out: Value = .bool(true)
  var err: String?
  var progErr: String?

  var testDescription: String { name }
}

private func funcDecl(_ name: String, _ options: FunctionDecl.Option...) -> FunctionDecl {
  // swift-format-ignore: NeverUseForceTry
  try! FunctionDecl(name, options: options)
}

private let base64Encode: FunctionDecl = funcDecl(
  "base64.encode",
  .overload("base64_encode_string", argTypes: [.string], resultType: .string),
  .singletonUnaryBinding { val in
    guard case .string(let s) = val else { return Value.maybeNoSuchOverload(val) }
    return .string(base64(Array(s.utf8)))
  })

private func base64(_ bytes: [UInt8]) -> String {
  let table = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".unicodeScalars)
  var out = String.UnicodeScalarView()
  var i = 0
  while i < bytes.count {
    let b0 = Int(bytes[i])
    let b1 = i + 1 < bytes.count ? Int(bytes[i + 1]) : 0
    let b2 = i + 2 < bytes.count ? Int(bytes[i + 2]) : 0
    out.append(table[b0 >> 2])
    out.append(table[((b0 & 3) << 4) | (b1 >> 4)])
    out.append(i + 1 < bytes.count ? table[((b1 & 15) << 2) | (b2 >> 6)] : "=")
    out.append(i + 2 < bytes.count ? table[b2 & 63] : "=")
    i += 3
  }
  return String(out)
}

private func list(_ values: Value...) -> Value { .list(ArrayList(values)) }

private func map(_ entries: (MapKey, Value)...) -> Value { .map(OrderedMap(entries)) }

private let headers = map(("ip", "10.0.1.2"), ("path", "/admin/edit"), ("token", "admin"))

private let complexExpr = """
  !(headers.ip in ["10.0.1.4", "10.0.1.5"]) &&
    ((headers.path.startsWith("v1") && headers.token in ["v1", "v2", "admin"]) ||
    (headers.path.startsWith("v2") && headers.token in ["v2", "admin"]) ||
    (headers.path.startsWith("/admin") && headers.token == "admin" && headers.ip in ["10.0.1.2", "10.0.1.2", "10.0.1.2"]))
  """

let interpreterCases: [InterpreterCase] = [
  .init(name: "double_ne_nan", expr: "0.0/0.0 == 0.0/0.0", out: false),
  .init(name: "double_lt_nan", expr: "0.0/0.0 < 1.0", out: false),
  .init(name: "double_nan_lt", expr: "1.0 < 0.0/0.0", out: false),
  .init(name: "double_nan_le_nan", expr: "0.0/0.0 <= 0.0/0.0", out: false),
  .init(name: "double_gt_nan", expr: "0.0/0.0 > 1.0", out: false),
  .init(name: "double_nan_gt", expr: "1.0 > 0.0/0.0", out: false),
  .init(name: "double_nan_ge_nan", expr: "0.0/0.0 >= 0.0/0.0", out: false),
  .init(name: "and_false_1st", expr: "false && true", out: false),
  .init(name: "and_false_2nd", expr: "true && false", out: false),
  .init(name: "and_error_1st_false", expr: "1/0 != 0 && false", out: false),
  .init(name: "and_error_2nd_false", expr: "false && 1/0 != 0", out: false),
  .init(name: "and_error_1st_error", expr: "1/0 != 0 && true", err: "division by zero"),
  .init(name: "and_error_2nd_error", expr: "true && 1/0 != 0", err: "division by zero"),
  .init(
    name: "call_no_args", expr: "zero()",
    funcs: [
      funcDecl(
        "zero", .overload("zero", argTypes: [], resultType: .int),
        .singletonFunctionBinding { _ in .int(0) })
    ], unchecked: true, out: 0),
  .init(
    name: "call_one_arg", expr: "neg(1)",
    funcs: [
      funcDecl(
        "neg",
        .overload(
          "neg_int", argTypes: [.int], resultType: .int, .operandTraits(.negator),
          .unaryBinding { $0.negate() }))
    ], unchecked: true, out: -1),
  .init(
    name: "call_two_arg", expr: "b'abc'.concat(b'def')",
    funcs: [
      funcDecl(
        "concat",
        .memberOverload(
          "bytes_concat_bytes", argTypes: [.bytes, .bytes], resultType: .bytes, .operandTraits(.adder),
          .binaryBinding { $0.add($1) }))
    ], unchecked: true, out: .bytes(Array("abcdef".utf8))),
  .init(
    name: "call_four_args", expr: "addall(a, b, c, d) == 10",
    funcs: [
      funcDecl(
        "addall", .overload("addall_four", argTypes: [.int, .int, .int, .int], resultType: .int),
        .disableTypeGuards(true),
        .singletonFunctionBinding(
          { args in
            var total: Int64 = 0
            for case .int(let i) in args { total += i }
            return .int(total)
          }, traits: .adder))
    ], unchecked: true, input: ["a": 1, "b": 2, "c": 3, "d": 4]),
  .init(name: "call_ns_func", expr: "base64.encode('hello')", funcs: [base64Encode], out: "aGVsbG8="),
  .init(
    name: "call_ns_func_unchecked", expr: "base64.encode('hello')", funcs: [base64Encode], unchecked: true,
    out: "aGVsbG8="),
  .init(
    name: "call_ns_func_in_pkg", expr: "encode('hello')", container: "base64", funcs: [base64Encode],
    out: "aGVsbG8="),
  .init(
    name: "call_ns_func_unchecked_in_pkg", expr: "encode('hello')", container: "base64", funcs: [base64Encode],
    unchecked: true, out: "aGVsbG8="),
  .init(
    name: "complex", expr: complexExpr, vars: [VariableDecl(name: "headers", type: .map(key: .string, value: .string))],
    input: ["headers": headers]),
  .init(
    name: "complex_qual_vars", expr: complexExpr,
    vars: [
      VariableDecl(name: "headers.ip", type: .string), VariableDecl(name: "headers.path", type: .string),
      VariableDecl(name: "headers.token", type: .string),
    ],
    input: ["headers.ip": "10.0.1.2", "headers.path": "/admin/edit", "headers.token": "admin"]),
  .init(
    name: "cond", expr: "a ? b < 1.2 : c == ['hello']",
    vars: [
      VariableDecl(name: "a", type: .bool), VariableDecl(name: "b", type: .double),
      VariableDecl(name: "c", type: .list(.string)),
    ],
    input: ["a": true, "b": 2.0, "c": list("hello")], out: false),
  .init(
    name: "cond_attr_out_of_bounds_error", expr: "m[(x ? 0 : 1)] >= 0",
    vars: [VariableDecl(name: "m", type: .list(.int)), VariableDecl(name: "x", type: .bool)],
    input: ["m": list(-1), "x": false], err: "index out of bounds: 1"),
  .init(
    name: "cond_attr_qualify_bad_type_error", expr: "m[(x ? a : b)] >= 0",
    vars: [
      VariableDecl(name: "m", type: .list(.dyn)), VariableDecl(name: "a", type: .dyn),
      VariableDecl(name: "b", type: .dyn), VariableDecl(name: "x", type: .bool),
    ],
    input: [
      "m": list(1), "x": false, "a": .duration(CELDuration(nanoseconds: 1_000_000)),
      "b": .duration(CELDuration(nanoseconds: 1_000_000)),
    ], err: "invalid qualifier type"),
  .init(
    name: "cond_attr_qualify_bad_field_error", expr: "m[(x ? a : b).c] >= 0",
    vars: [
      VariableDecl(name: "m", type: .list(.dyn)), VariableDecl(name: "a", type: .dyn),
      VariableDecl(name: "b", type: .dyn), VariableDecl(name: "x", type: .bool),
    ],
    input: ["m": list(1), "x": false, "a": 1, "b": 2], err: "no such key: c"),
  .init(name: "in_empty_list", expr: "6 in []", out: false),
  .init(name: "in_constant_list", expr: "6 in [2, 12, 6]"),
  .init(name: "bytes_in_constant_list", expr: "b'hello' in [b'world', b'universe', b'hello']"),
  .init(name: "list_in_constant_list", expr: "[6] in [2, 12, [6]]"),
  .init(name: "in_constant_list_cross_type_uint_int", expr: "dyn(12u) in [2, 12, 6]"),
  .init(name: "in_constant_list_cross_type_double_int", expr: "dyn(6.0) in [2, 12, 6]"),
  .init(name: "in_constant_list_cross_type_int_double", expr: "dyn(6) in [2.1, 12.0, 6.0]"),
  .init(name: "not_in_constant_list_cross_type_int_double", expr: "dyn(2) in [2.1, 12.0, 6.0]", out: false),
  .init(name: "in_constant_list_cross_type_int_uint", expr: "dyn(6) in [2u, 12u, 6u]"),
  .init(name: "in_constant_list_cross_type_negative_int_uint", expr: "dyn(-6) in [2u, 12u, 6u]", out: false),
  .init(name: "in_constant_list_cross_type_negative_double_uint", expr: "dyn(-6.1) in [2u, 12u, 6u]", out: false),
  .init(name: "in_var_list_int", expr: "6 in [2, 12, x]", vars: [VariableDecl(name: "x", type: .dyn)], input: ["x": 6]),
  .init(
    name: "in_var_list_uint", expr: "6 in [2, 12, x]", vars: [VariableDecl(name: "x", type: .dyn)],
    input: ["x": .uint(6)]),
  .init(
    name: "in_var_list_double", expr: "6 in [2, 12, x]", vars: [VariableDecl(name: "x", type: .dyn)],
    input: ["x": 6.0]),
  .init(
    name: "in_var_list_double_double", expr: "dyn(6.0) in [2, 12, x]", vars: [VariableDecl(name: "x", type: .int)],
    input: ["x": 6]),
  .init(name: "in_constant_map", expr: "'other-key' in {'key': null, 'other-key': 42}"),
  .init(name: "in_constant_map_cross_type_string_number", expr: "'other-key' in {1: null, 2u: 42}", out: false),
  .init(name: "in_constant_map_cross_type_double_int", expr: "2.0 in {1: null, 2u: 42}"),
  .init(name: "not_in_constant_map_cross_type_double_int", expr: "2.1 in {1: null, 2u: 42}", out: false),
  .init(name: "in_constant_heterogeneous_map", expr: "'hello' in {1: 'one', false: true, 'hello': 'world'}"),
  .init(name: "not_in_constant_heterogeneous_map", expr: "!('hello' in {1: 'one', false: true})"),
  .init(
    name: "not_in_constant_heterogeneous_map_with_same_key_type", expr: "!('hello' in {1: 'one', 'world': true})"),
  .init(
    name: "in_var_key_map", expr: "'other-key' in {x: null, y: 42}",
    vars: [VariableDecl(name: "x", type: .string), VariableDecl(name: "y", type: .int)],
    input: ["x": "other-key", "y": 2]),
  .init(
    name: "in_var_value_map", expr: "'other-key' in {1: x, 2u: y}",
    vars: [VariableDecl(name: "x", type: .string), VariableDecl(name: "y", type: .int)],
    input: ["x": "other-value", "y": 2], out: false),
  .init(
    name: "index", expr: "m['key'][1] == 42u && m['null'] == null && m[string(0)] == 10",
    vars: [VariableDecl(name: "m", type: .map(key: .string, value: .dyn))],
    input: ["m": map(("key", list(.uint(21), .uint(42))), ("null", .null), ("0", 10))]),
  .init(
    name: "index_cross_type_float_uint", expr: "{1: 'hello'}[x] == 'hello' && {2: 'world'}[y] == 'world'",
    vars: [VariableDecl(name: "x", type: .dyn), VariableDecl(name: "y", type: .dyn)],
    input: ["x": 1.0, "y": .uint(2)]),
  .init(
    name: "no_index_cross_type_float_uint", expr: "{1: 'hello'}[x] == 'hello' && ['world'][y] == 'world'",
    vars: [VariableDecl(name: "x", type: .dyn), VariableDecl(name: "y", type: .dyn)],
    input: ["x": 2.0, "y": .uint(3)], err: "no such key: 2"),
  .init(
    name: "index_cross_type_double", expr: "{1: 'hello', 2: 'world'}[x] == 'hello'",
    vars: [VariableDecl(name: "x", type: .dyn)], input: ["x": 1.0]),
  .init(name: "index_cross_type_double_const", expr: "{1: 'hello', 2: 'world'}[dyn(2.0)] == 'world'"),
  .init(name: "index_cross_type_uint", expr: "{1: 'hello', 2: 'world'}[dyn(2u)] == 'world'"),
  .init(
    name: "index_cross_type_bad_qualifier", expr: "{1: 'hello', 2: 'world'}[x] == 'world'",
    vars: [VariableDecl(name: "x", type: .dyn)], input: ["x": .duration(CELDuration(nanoseconds: 1_000_000))],
    err: "invalid qualifier type"),
  .init(name: "index_list_int_double_type_index", expr: "[7, 8, 9][dyn(0.0)] == 7"),
  .init(name: "index_list_int_uint_type_index", expr: "[7, 8, 9][dyn(0u)] == 7"),
  .init(name: "index_list_int_bad_double_type_index", expr: "[7, 8, 9][dyn(0.1)] == 7", err: "unsupported index value"),
  .init(
    name: "index_relative",
    expr: "([[[1]], [[2]], [[3]]][0][0] + [2, 3, {'four': {'five': 'six'}}])[3].four.five == 'six'"),
  .init(name: "list_eq_false_with_error", expr: "['string', 1] == [2, 3]", out: false),
  .init(name: "list_eq_error", expr: "['string', true] == [2, 3]", out: false),
  .init(name: "literal_bool_false", expr: "false", out: false),
  .init(name: "literal_bool_true", expr: "true"),
  .init(name: "literal_null", expr: "null", out: .null),
  .init(name: "literal_list", expr: "[1, 2, 3]", out: list(1, 2, 3)),
  .init(name: "literal_map", expr: "{'hi': 21, 'world': 42u}", out: map(("hi", 21), ("world", .uint(42)))),
  .init(name: "literal_equiv_string_bytes", expr: #"string(bytes("\303\277")) == '''\303\277'''"#),
  .init(name: "literal_not_equiv_string_bytes", expr: #"string(b"\303\277") != '''\303\277'''"#),
  .init(name: "literal_equiv_bytes_string", expr: #"string(b"\303\277") == 'ÿ'"#),
  .init(name: "literal_bytes_string", expr: #"string(b'aaa"bbb')"#, out: #"aaa"bbb"#),
  .init(name: "literal_bytes_string2", expr: #"string(b"""Kim\t""")"#, out: "Kim\t"),
  .init(name: "timestamp_eq_timestamp", expr: "timestamp(0) == timestamp(0)"),
  .init(name: "timestamp_ne_timestamp", expr: "timestamp(1) != timestamp(2)"),
  .init(name: "timestamp_lt_timestamp", expr: "timestamp(0) < timestamp(1)"),
  .init(name: "timestamp_le_timestamp", expr: "timestamp(2) <= timestamp(2)"),
  .init(name: "timestamp_gt_timestamp", expr: "timestamp(1) > timestamp(0)"),
  .init(name: "timestamp_ge_timestamp", expr: "timestamp(2) >= timestamp(2)"),
  .init(
    name: "timestamp_methods",
    expr: """
      x.getFullYear() == 1970
      && x.getMonth() == 0
      && x.getDayOfYear() == 0
      && x.getDayOfMonth() == 0
      && x.getDate() == 1
      && x.getDayOfWeek() == 4
      && x.getHours() == 2
      && x.getMinutes() == 5
      && x.getSeconds() == 6
      && x.getMilliseconds() == 1
      && x.getFullYear('-07:30') == 1969
      && x.getDayOfYear('-07:30') == 364
      && x.getMonth('-07:30') == 11
      && x.getDayOfMonth('-07:30') == 30
      && x.getDate('-07:30') == 31
      && x.getDayOfWeek('-07:30') == 3
      && x.getHours('-07:30') == 18
      && x.getMinutes('-07:30') == 35
      && x.getSeconds('-07:30') == 6
      && x.getMilliseconds('-07:30') == 1
      && x.getFullYear('23:15') == 1970
      && x.getDayOfYear('23:15') == 1
      && x.getMonth('23:15') == 0
      && x.getDayOfMonth('23:15') == 1
      && x.getDate('23:15') == 2
      && x.getDayOfWeek('23:15') == 5
      && x.getHours('23:15') == 1
      && x.getMinutes('23:15') == 20
      && x.getSeconds('23:15') == 6
      && x.getMilliseconds('23:15') == 1
      """,
    vars: [VariableDecl(name: "x", type: .timestamp)],
    input: ["x": .timestamp(CELTimestamp(secondsSinceEpoch: 7506, nanoseconds: 1_000_000))]),
  .init(
    name: "string_to_timestamp", expr: "timestamp('1986-04-26T01:23:40Z')",
    out: .timestamp(CELTimestamp(secondsSinceEpoch: 514_862_620))),
  .init(name: "macro_all_non_strict", expr: "![0, 2, 4].all(x, 4/x != 2 && 4/(4-x) != 2)"),
  .init(
    name: "macro_all_non_strict_var",
    expr: """
      code == "111" && ["a", "b"].all(x, x in tags)
        || code == "222" && ["a", "b"].all(x, x in tags)
      """,
    vars: [VariableDecl(name: "code", type: .string), VariableDecl(name: "tags", type: .list(.string))],
    input: ["code": "222", "tags": list("a", "b")]),
  .init(name: "macro_exists_lit", expr: "[1, 2, 3, 4, 5u, 1.0].exists(e, type(e) == uint)"),
  .init(name: "macro_exists_nonstrict", expr: "[0, 2, 4].exists(x, 4/x == 2 && 4/(4-x) == 2)"),
  .init(
    name: "macro_exists_var", expr: "elems.exists(e, type(e) == uint)",
    vars: [VariableDecl(name: "elems", type: .list(.dyn))], input: ["elems": list(0, 1, 2, 3, 4, .uint(5), 6)]),
  .init(name: "macro_exists_one", expr: "[1, 2, 3].exists_one(x, (x % 2) == 0)"),
  .init(name: "macro_filter", expr: "[-10, -9, -8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3].filter(x, x > 0)", out: list(1, 2, 3)),
  .init(name: "macro_has_map_key", expr: "has({'a':1}.a) && !has({}.a)"),
  .init(name: "macro_map", expr: "[1, 2, 3].map(x, x * 2) == [2, 4, 6]"),
  .init(
    name: "matches_global", expr: "matches(input, 'k.*')", vars: [VariableDecl(name: "input", type: .string)],
    input: ["input": "kathmandu"]),
  .init(
    name: "matches_member",
    expr: """
      input.matches('k.*')
        && !'foo'.matches('k.*')
        && !'bar'.matches('k.*')
        && 'kilimanjaro'.matches('.*ro')
      """,
    vars: [VariableDecl(name: "input", type: .string)], input: ["input": "kathmandu"]),
  .init(
    name: "matches_error", expr: "input.matches(')k.*')", vars: [VariableDecl(name: "input", type: .string)],
    input: ["input": "kathmandu"], err: "unexpected ): `)k.*`", progErr: "unexpected ): `)k.*`"),
  .init(
    name: "or_true_1st", expr: #"ai == 20 || ar["foo"] == "bar""#,
    vars: [VariableDecl(name: "ai", type: .int), VariableDecl(name: "ar", type: .map(key: .string, value: .string))],
    input: ["ai": 20, "ar": map(("foo", "bar"))]),
  .init(
    name: "or_true_2nd", expr: #"ai == 20 || ar["foo"] == "bar""#,
    vars: [VariableDecl(name: "ai", type: .int), VariableDecl(name: "ar", type: .map(key: .string, value: .string))],
    input: ["ai": 2, "ar": map(("foo", "bar"))]),
  .init(
    name: "or_false", expr: #"ai == 20 || ar["foo"] == "bar""#,
    vars: [VariableDecl(name: "ai", type: .int), VariableDecl(name: "ar", type: .map(key: .string, value: .string))],
    input: ["ai": 2, "ar": map(("foo", "baz"))], out: false),
  .init(name: "or_error_1st_error", expr: "1/0 != 0 || false", err: "division by zero"),
  .init(name: "or_error_2nd_error", expr: "false || 1/0 != 0", err: "division by zero"),
  .init(name: "or_error_1st_true", expr: "1/0 != 0 || true"),
  .init(name: "or_error_2nd_true", expr: "true || 1/0 != 0"),
  .init(
    name: "pkg_qualified_id", expr: "b.c.d != 10", container: "a.b", vars: [VariableDecl(name: "a.b.c.d", type: .int)],
    input: ["a.b.c.d": 9]),
  .init(name: "pkg_qualified_id_unchecked", expr: "c.d != 10", container: "a.b", unchecked: true, input: ["a.c.d": 9]),
  .init(
    name: "pkg_qualified_index_unchecked", expr: "b.c['d'] == 10", container: "a.b", unchecked: true,
    input: ["a.b.c": map(("d", 10))]),
  .init(name: "type_dyn_equals_string", expr: "type(dyn('')) == string"),
  .init(
    name: "type_override", expr: "type == 'string'", vars: [VariableDecl(name: "type", type: .string)],
    input: ["type": "string"]),
  .init(
    name: "select_key",
    expr: """
      m.strMap['val'] == 'string'
        && m.floatMap['val'] == 1.5
        && m.doubleMap['val'] == -2.0
        && m.intMap['val'] == -3
        && m.uintMap['val'] == 6u
        && m.boolMap['val'] == true
        && m.boolMap['val'] != false
      """,
    vars: [VariableDecl(name: "m", type: .map(key: .string, value: .dyn))],
    input: [
      "m": map(
        ("strMap", map(("val", "string"))), ("floatMap", map(("val", 1.5))), ("doubleMap", map(("val", -2.0))),
        ("intMap", map(("val", -3))), ("uintMap", map(("val", .uint(6)))), ("boolMap", map(("val", true))))
    ]),
  .init(
    name: "select_bool_key",
    expr: """
      m.boolStr[true] == 'string'
        && m.boolFloat64[false] == -2.1
        && m.boolInt[false] == -3
        && m.boolUint[true] == 5u
        && m.boolBool[true]
      """,
    vars: [VariableDecl(name: "m", type: .map(key: .string, value: .dyn))],
    input: [
      "m": map(
        ("boolStr", map((true, "string"))), ("boolFloat64", map((false, -2.1))), ("boolInt", map((false, -3))),
        ("boolUint", map((true, .uint(5)))), ("boolBool", map((true, true))))
    ]),
  .init(
    name: "select_uint_key",
    expr: "m.uintIface[1u] == 'string' && m.uint64Iface[3u] == -2.1",
    vars: [VariableDecl(name: "m", type: .map(key: .string, value: .dyn))],
    input: ["m": map(("uintIface", map((.uint(1), "string"))), ("uint64Iface", map((.uint(3), -2.1))))]),
  .init(
    name: "select_index",
    expr: """
      m.strList[0] == 'string'
        && m.doubleList[0] == -2.0
        && m.intList[0] == -3
        && m.uintList[0] == 6u
        && m.boolList[0] == true
        && m.boolList[1] != true
        && m.ifaceList[0] == {}
      """,
    vars: [VariableDecl(name: "m", type: .map(key: .string, value: .dyn))],
    input: [
      "m": map(
        ("strList", list("string")), ("doubleList", list(-2.0)), ("intList", list(-3)), ("uintList", list(.uint(6))),
        ("boolList", list(true, false)), ("ifaceList", list(map())))
    ]),
  .init(
    name: "select_subsumed_field", expr: "a.b.c",
    vars: [VariableDecl(name: "a.b.c", type: .int), VariableDecl(name: "a.b", type: .map(key: .string, value: .string))],
    input: ["a.b.c": 10, "a.b": map(("c", "ten"))], out: 10),
  .init(
    name: "call_with_error_unary", expr: "try(0/0)",
    funcs: [
      funcDecl(
        "try",
        .overload(
          "try_dyn", argTypes: [.dyn], resultType: .dyn, .nonStrict,
          .unaryBinding { arg in
            if case .error(let e) = arg { return .string("error: \(e.message)") }
            return arg
          }))
    ], unchecked: true, out: "error: division by zero"),
  .init(
    name: "call_with_error_binary", expr: "try(0/0, 0)",
    funcs: [
      funcDecl(
        "try",
        .overload(
          "try_dyn", argTypes: [.dyn, .dyn], resultType: .list(.dyn), .nonStrict,
          .binaryBinding { a, b in
            if case .error(let e) = a { return .string("error: \(e.message)") }
            return .list(ArrayList([a, b]))
          }))
    ], unchecked: true, out: "error: division by zero"),
  .init(
    name: "call_with_error_function", expr: "try(0/0, 0, 0)",
    funcs: [
      funcDecl(
        "try",
        .overload(
          "try_dyn", argTypes: [.dyn, .dyn, .dyn], resultType: .list(.dyn), .nonStrict,
          .functionBinding { args in
            if case .error(let e) = args[0] { return .string("error: \(e.message)") }
            return .list(ArrayList(args))
          }))
    ], unchecked: true, out: "error: division by zero"),
  .init(
    name: "literal_map_optional_field",
    expr: "{?'hi': {}.?missing, ?'world': {'present': 42u}.?present}", out: map(("world", .uint(42)))),
  .init(
    name: "literal_map_optional_field_bad_init", expr: "{?'hi': 'world'}", unchecked: true,
    err: "cannot initialize optional entry 'hi' from non-optional"),
  .init(name: "literal_list_optional_element", expr: "[?{}.?missing, ?{'present': 42u}.?present]", out: list(.uint(42))),
  .init(
    name: "literal_list_optional_bad_element", expr: "[?123]", unchecked: true,
    err: "cannot initialize optional list element from non-optional value 123"),
  .init(
    name: "unknown_optional_map", expr: "{?'hi': a}", vars: [VariableDecl(name: "a", type: .optional(.int))],
    unknowns: [AttributePattern("a")], out: .unknown(UnknownSet(exprID: 4, attribute: AttributeTrail(variable: "a")))),
  .init(
    name: "unknown_optional_list", expr: "[?a]", vars: [VariableDecl(name: "a", type: .optional(.int))],
    unknowns: [AttributePattern("a")], out: .unknown(UnknownSet(exprID: 2, attribute: AttributeTrail(variable: "a")))),
  .init(
    name: "unknown_optional_list_multiple", expr: "[?a, ?b]",
    vars: [VariableDecl(name: "a", type: .optional(.int)), VariableDecl(name: "b", type: .optional(.int))],
    unknowns: [AttributePattern("a"), AttributePattern("b")],
    out: .unknown(
      UnknownSet(exprID: 2, attribute: AttributeTrail(variable: "a")).merging(
        UnknownSet(exprID: 3, attribute: AttributeTrail(variable: "b"))))),
  .init(
    name: "unknown_eq_multiple", expr: "a == b",
    vars: [VariableDecl(name: "a", type: .int), VariableDecl(name: "b", type: .int)],
    unknowns: [AttributePattern("a"), AttributePattern("b")],
    out: .unknown(
      UnknownSet(exprID: 1, attribute: AttributeTrail(variable: "a")).merging(
        UnknownSet(exprID: 3, attribute: AttributeTrail(variable: "b"))))),
  .init(
    name: "unknown_ne_multiple", expr: "a != b",
    vars: [VariableDecl(name: "a", type: .int), VariableDecl(name: "b", type: .int)],
    unknowns: [AttributePattern("a"), AttributePattern("b")],
    out: .unknown(
      UnknownSet(exprID: 1, attribute: AttributeTrail(variable: "a")).merging(
        UnknownSet(exprID: 3, attribute: AttributeTrail(variable: "b"))))),
  .init(
    name: "unknown_eq_error_precedence", expr: "a == (1/0)", vars: [VariableDecl(name: "a", type: .int)],
    unknowns: [AttributePattern("a")], err: "division by zero"),
  .init(
    name: "unknown_ne_error_precedence", expr: "a != (1/0)", vars: [VariableDecl(name: "a", type: .int)],
    unknowns: [AttributePattern("a")], err: "division by zero"),
  .init(
    name: "unknown_optional_map_multiple", expr: "{?'hi': a, ?'world': b}",
    vars: [VariableDecl(name: "a", type: .optional(.int)), VariableDecl(name: "b", type: .optional(.int))],
    unknowns: [AttributePattern("a"), AttributePattern("b")],
    out: .unknown(
      UnknownSet(exprID: 4, attribute: AttributeTrail(variable: "a")).merging(
        UnknownSet(exprID: 7, attribute: AttributeTrail(variable: "b"))))),
  .init(
    name: "unknown_optional_map_error_precedence", expr: "{?'hi': a, ?'world': {'x': 1/0}.?missing}",
    vars: [VariableDecl(name: "a", type: .optional(.int))], unknowns: [AttributePattern("a")],
    err: "division by zero"),
  .init(
    name: "unknown_optional_map_invalid_type_precedence", expr: "{?'hi': a, ?'world': 'not-optional'}",
    vars: [VariableDecl(name: "a", type: .optional(.int))], unchecked: true, unknowns: [AttributePattern("a")],
    err: "cannot initialize optional entry 'world' from non-optional value not-optional"),
  .init(name: "bad_argument_in_optimized_list", expr: "1/0 in [1, 2, 3]", err: "division by zero"),
  .init(name: "list_index_error", expr: "mylistundef[0]", unchecked: true, err: "no such attribute(s): mylistundef"),
  .init(
    name: "pkg_list_index_error", expr: "pkg.mylistundef[0]", container: "goog", unchecked: true,
    err: "no such attribute(s): goog.pkg.mylistundef, pkg.mylistundef"),
  .init(
    name: "unknown_attribute", expr: "a[0]", vars: [VariableDecl(name: "a", type: .map(key: .int, value: .bool))],
    input: ["a": map((1, true))], unknowns: [AttributePattern("a").qualInt(0)],
    out: .unknown(UnknownSet(exprID: 2, attribute: AttributeTrail(variable: "a", qualifierPath: [.int(0)])))),
  .init(
    name: "macro_has_map_key_unknown_propagates", expr: "has(a.b)",
    vars: [VariableDecl(name: "a", type: .map(key: .string, value: .bool))], unknowns: [AttributePattern("a")],
    out: .unknown(UnknownSet(exprID: 4, attribute: AttributeTrail(variable: "a")))),
  .init(
    name: "unknown_attribute_mixed_qualifier", expr: "a[dyn(0u)]",
    vars: [VariableDecl(name: "a", type: .map(key: .int, value: .bool))], input: ["a": map((1, true))],
    unknowns: [AttributePattern("a").qualInt(0)],
    out: .unknown(UnknownSet(exprID: 2, attribute: AttributeTrail(variable: "a", qualifierPath: [.uint(0)])))),
  .init(
    name: "invalid_presence_test_on_int_literal", expr: "has(dyn(1).invalid)", errorOnBadPresenceTest: true,
    err: "no such key: invalid"),
  .init(
    name: "invalid_presence_test_on_list_literal", expr: "has(dyn([]).invalid)", errorOnBadPresenceTest: true,
    err: "unsupported index type 'string' in list"),
  .init(name: "optional_select_on_undefined", expr: "{}.?invalid", out: .optional(nil)),
  .init(name: "optional_select_on_null_literal", expr: #"{"invalid": dyn(null)}.?invalid.?nested"#, out: .optional(nil)),
  .init(
    name: "local_shadow_identifier_in_select", expr: "[{'z': 0}].exists(y, y.z == 0)", container: "cel.example",
    vars: [VariableDecl(name: "cel.example.y", type: .int)], input: ["cel.example.y": map(("z", 1))]),
  .init(
    name: "local_shadow_identifier_in_select_global_disambiguation",
    expr: "[{'z': 0}].exists(y, y.z == 0 && .y.z == 1)", container: "y", vars: [VariableDecl(name: "y.z", type: .int)],
    input: ["y.z": 1]),
  .init(
    name: "local_shadow_identifier_with_global_disambiguation", expr: "[0].exists(x, x == 0 && .x == 1)",
    vars: [VariableDecl(name: "x", type: .int)], input: ["x": 1]),
  .init(
    name: "local_double_shadow_identifier_with_global_disambiguation", expr: "[0].exists(x, [x+1].exists(x, x == .x))",
    vars: [VariableDecl(name: "x", type: .int)], input: ["x": 1]),
  .init(
    name: "unchecked_local_shadow_identifier_in_select", expr: "[{'z': 0}].exists(y, y.z == 0)",
    container: "cel.example", vars: [VariableDecl(name: "cel.example.y", type: .int)], unchecked: true,
    input: ["cel.example.y": map(("z", 1))]),
  .init(
    name: "unchecked_local_shadow_identifier_in_select_global_disambiguation",
    expr: "[{'z': 0}].exists(y, y.z == 0 && .y.z == 1)", container: "y", vars: [VariableDecl(name: "y.z", type: .int)],
    unchecked: true, input: ["y.z": 1]),
  .init(
    name: "unchecked_local_shadow_identifier_with_global_disambiguation", expr: "[0].exists(x, x == 0 && .x == 1)",
    vars: [VariableDecl(name: "x", type: .int)], unchecked: true, input: ["x": 1]),
  .init(
    name: "unchecked_local_double_shadow_identifier_with_global_disambiguation",
    expr: "[0].exists(x, [x+1].exists(x, x == .x))", vars: [VariableDecl(name: "x", type: .int)], unchecked: true,
    input: ["x": 1]),
]

/// Builds the environment of cel-go's `program` test helper: the standard library, all macros,
/// optional syntax, variadic logical operators and cross-type numeric comparisons.
func interpreterEnvironment(_ tc: InterpreterCase) throws -> ProgramEnvironment {
  var options: [Container.Option] = []
  if !tc.container.isEmpty {
    options.append(.name(tc.container))
  }
  if !tc.abbrevs.isEmpty {
    options.append(.abbreviations(tc.abbrevs))
  }
  var env = ProgramEnvironment(
    container: try Container(options: options),
    provider: tc.protos ? testTypeRegistry(jsonFieldNames: tc.jsonFieldNames) : TypeRegistry(),
    parserOptions: [.enableOptionalSyntax(true), .enableVariadicOperatorASTs(true)],
    errorOnBadPresenceTest: tc.errorOnBadPresenceTest)
  env.checkerOptions = [.crossTypeNumericComparisons(true)]
  // cel-go's test checker env has the stdlib functions but no type identifier declarations.
  env.declaresStandardTypes = false
  try env.declare(tc.vars, functions: tc.funcs)
  return env
}

/// Plans the test case with the given evaluation options.
func interpreterProgram(_ tc: InterpreterCase, _ evalOptions: EvalOptions = []) throws -> PlannedProgram {
  let env = try interpreterEnvironment(tc)
  var ast = try env.parse(tc.expr)
  if !tc.unchecked {
    ast = try env.check(ast, source: TextSource(tc.expr))
  }
  var options = evalOptions
  if tc.unknowns != nil {
    options.insert(.partialEval)
  }
  return try env.program(ast, options: ProgramOptions(evalOptions: options))
}

func interpreterActivation(_ tc: InterpreterCase) -> any Activation {
  let vars = MapActivation(tc.input)
  if let unknowns = tc.unknowns {
    return PartialActivationWrapper(vars, unknowns: unknowns)
  }
  return vars
}

struct InterpreterTests {
  private func verify(_ tc: InterpreterCase, _ got: Value, mode: String, requireNodeID: Bool) {
    if case .unknown = tc.out {
      #expect(got == tc.out, "\(mode): got \(got), want \(tc.out)")
    } else if let err = tc.err {
      guard case .error(let e) = got else {
        Issue.record("\(mode): got \(got), want error containing \(err)")
        return
      }
      #expect(e.message.contains(err), "\(mode): got error \(e.message), want \(err)")
      if requireNodeID {
        #expect(e.exprID != 0, "\(mode): error without an AST node id: \(e)")
      }
    } else {
      #expect(got.celEquals(tc.out) == .bool(true), "\(mode): got \(got), want \(tc.out)")
    }
  }

  @Test(arguments: interpreterCases + interpreterProtoCases)
  func interpreter(_ tc: InterpreterCase) throws {
    let program = try interpreterProgram(tc)
    verify(tc, program.eval(interpreterActivation(tc)).value, mode: "default", requireNodeID: false)

    let modes: [(String, EvalOptions)] = [
      ("optimize", .optimize), ("exhaustive", [.exhaustiveEval, .trackState]), ("track", .trackState),
    ]
    for (mode, options) in modes {
      if let progErr = tc.progErr, options.contains(.optimize) {
        #expect(throws: (any Error).self, "\(mode): want program error \(progErr)") {
          try interpreterProgram(tc, options)
        }
        continue
      }
      let program = try interpreterProgram(tc, options)
      let result = program.eval(interpreterActivation(tc))
      verify(tc, result.value, mode: mode, requireNodeID: true)
      if options.contains(.trackState) {
        #expect(result.state != nil, "\(mode): no evaluation state")
      }
    }
  }
}

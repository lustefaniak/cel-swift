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
// Ported from cel-go interpreter/prune_test.go.

import CELGoTestProtos
import CELProtobuf
import Testing

@testable import CEL

struct PruneCase: Sendable, CustomTestStringConvertible {
  var input: [String: Value]?
  var unknowns: [AttributePattern] = []
  var expr: String
  var out: String
  var iterRange: String?

  var testDescription: String { expr }
}

private func unknown(_ vars: String...) -> (input: [String: Value]?, unknowns: [AttributePattern]) {
  ([:], vars.map { AttributePattern($0) })
}

private func partial(_ input: [String: Value], _ vars: String...) -> (
  input: [String: Value]?, unknowns: [AttributePattern]
) {
  (input, vars.map { AttributePattern($0) })
}

private func tc(
  _ act: (input: [String: Value]?, unknowns: [AttributePattern])? = nil, _ expr: String, _ out: String,
  iterRange: String? = nil
) -> PruneCase {
  PruneCase(input: act?.input, unknowns: act?.unknowns ?? [], expr: expr, out: out, iterRange: iterRange)
}

let pruneCases: [PruneCase] = [
  tc(nil, "{{'nested_key': true}.nested_key: true}", "{true: true}"),
  tc(partial(["msg": ["foo": "bar"]]), "msg", #"{"foo": "bar"}"#),
  tc(nil, "true && false", "false"),
  tc(unknown("x"), "(true || false) && x", "x"),
  tc(unknown("x"), "(false || false) && x", "false"),
  tc(unknown("a"), "a && [1, 1u, 1.0].exists(x, type(x) == uint)", "a"),
  tc(unknown("this"), "this in []", "false"),
  PruneCase(
    input: ["this": ["b": "exists"]], unknowns: [AttributePattern("this")], expr: "has(this.a) || !has(this.b)",
    out: "has(this.a) || !has(this.b)"),
  PruneCase(
    input: ["this": ["b": "exists"]], unknowns: [AttributePattern("this").qualString("a")],
    expr: "has(this.a) || !has(this.b)", out: "has(this.a)"),
  PruneCase(
    input: ["this": ["b": "exists"]], unknowns: [AttributePattern("this").qualString("a")],
    expr: "!has(this.b) || has(this.a)", out: "has(this.a)"),
  PruneCase(
    input: ["this": .map(OrderedMap())], unknowns: [AttributePattern("this")],
    expr: "(!(this.a in []) || has(this.a)) || !has(this.b)", out: "true"),
  PruneCase(
    input: ["this": .map(OrderedMap())], unknowns: [AttributePattern("this")], expr: "has(this.a) || !has(this.b)",
    out: "has(this.a) || !has(this.b)"),
  PruneCase(
    input: ["this": .map(OrderedMap())], unknowns: [AttributePattern("this")],
    expr: "(has(this.a) || !(this.a in [])) || !has(this.b)", out: "true"),
  PruneCase(
    input: ["this": ["a": "exists"]], unknowns: [AttributePattern("this").qualString("b")],
    expr: "has(this.a) && !has(this.b)", out: "!has(this.b)"),
  PruneCase(
    input: ["this": .map(OrderedMap())], unknowns: [AttributePattern("this")],
    expr: "(has(this.a) && this.a in []) || !has(this.b)", out: "!has(this.b)"),
  PruneCase(
    input: ["this": .map(OrderedMap())], unknowns: [AttributePattern("this")],
    expr: "(this.a in [] && has(this.a)) || !has(this.b)", out: "!has(this.b)"),
  PruneCase(
    input: ["this": ["a": .map(OrderedMap())]], unknowns: [AttributePattern("this").qualString("a")],
    expr: "has(this.a.b)", out: "has(this.a.b)"),
  PruneCase(
    input: ["this": ["a": .map(OrderedMap())]], unknowns: [AttributePattern("this").qualString("a")],
    expr: #"has(this["a"].b)"#, out: #"has(this["a"].b)"#),
  PruneCase(
    input: [
      "this": proto3Types.value(
        of: Google_Expr_Proto3_Test_TestAllTypes.with {
          $0.singleInt32 = 0
          $0.singleInt64 = 1
        })
    ], unknowns: [AttributePattern("this").qualString("single_int64")],
    expr: "has(this.single_int32) && !has(this.single_int64)", out: "false"),
  tc(unknown("this"), "this in {}", "false"),
  tc(partial(["rules": .list(ArrayList())], "this"), "this in rules", "false"),
  tc(
    partial(["rules": ["not_in": .list(ArrayList())]], "this"),
    "this.size() > 0 ? this in rules.not_in : !(this in rules.not_in)", "(this.size() > 0) ? false : true"),
  tc(
    partial(["rules": ["not_in": .list(ArrayList())]], "this"),
    """
    this.size() > 0 ? this in rules.not_in :
    				!(this in rules.not_in) ? true : false
    """, "(this.size() > 0) ? false : true"),
  tc(nil, "{'hello': 'world'.size()}", #"{"hello": 5}"#),
  tc(nil, "[b'bytes-string']", #"[b"\142\171\164\145\163\055\163\164\162\151\156\147"]"#),
  tc(nil, "[b'bytes'] + [b'-' + b'string']", #"[b"\142\171\164\145\163", b"\055\163\164\162\151\156\147"]"#),
  tc(nil, "1u + 3u", "4u"),
  tc(nil, "2 < 3", "true"),
  tc(nil, "!false", "true"),
  tc(unknown("y"), "!y", "!y"),
  tc(partial(["y": 10]), "optional.of(y)", "optional.of(10)"),
  tc(unknown("a"), "a.?b", "a.?b"),
  tc(partial(["a": ["b": 10]]), "a.?b", "optional.of(10)"),
  tc(partial(["a": ["b": 10]]), #"a[?"b"]"#, "optional.of(10)"),
  tc(unknown(), "{'b': optional.of(10)}.?b", "optional.of(optional.of(10))"),
  tc(partial(["a": [:]]), "a.?b", "optional.none()"),
  tc(unknown(), "[10].last()", "optional.of(10)"),
  tc(unknown(), "[].last()", "optional.none()"),
  tc(unknown("a"), #"a[?"b"]"#, #"a[?"b"]"#),
  tc(unknown(), "[1, 2, 3, ?optional.none()]", "[1, 2, 3]"),
  tc(unknown(), "[1, 2, 3, ?optional.of(10)]", "[1, 2, 3, 10]"),
  tc(unknown(), "{1: 2, ?3: optional.none()}", "{1: 2}"),
  tc(unknown("a"), "[?optional.none(), a, 2, 3]", "[a, 2, 3]"),
  tc(unknown("a"), "[?optional.of(10), ?a, 2, 3]", "[10, ?a, 2, 3]"),
  tc(unknown("a"), "[?optional.of(10), a, 2, 3]", "[10, a, 2, 3]"),
  tc(partial(["a": "hi"], "b"), "{?a: b.?c}", #"{?"hi": b.?c}"#),
  tc(partial(["a": "hi"], "b"), #""hi" in {?a: b.?c}"#, #""hi" in {?"hi": b.?c}"#),
  tc(partial(["a": "hi"], "b"), #""hi" in {?a: optional.of("world")}"#, "true"),
  tc(partial(["a": "hi"], "b"), #"{?a: optional.of("world")}[b]"#, #"{"hi": "world"}[b]"#),
  tc(unknown("y"), "duration('1h') + duration('2h') > y", #"duration("10800s") > y"#),
  tc(unknown("x"), "[x, timestamp(0)]", #"[x, timestamp("1970-01-01T00:00:00Z")]"#),
  tc(nil, "[timestamp(0), timestamp(1)]", #"[timestamp("1970-01-01T00:00:00Z"), timestamp("1970-01-01T00:00:01Z")]"#),
  tc(nil, #"{"epoch": timestamp(0)}"#, #"{"epoch": timestamp("1970-01-01T00:00:00Z")}"#),
  tc(partial(["x": false], "y"), "!y && !x", "!y"),
  tc(nil, "!y && !(1/0 < 0)", "!y && !(1/0 < 0)"),
  tc(partial(["y": false]), "!y && !(1/0 < 0)", "!(1/0 < 0)"),
  tc(unknown(), "test == null", "test == null"),
  tc(unknown(), "test == null || true", "true"),
  tc(unknown(), "test == null && false", "false"),
  tc(unknown("b", "c"), "true ? b < 1.2 : c == ['hello']", "b < 1.2"),
  tc(unknown("b", "c"), "false ? b < 1.2 : c == ['hello']", #"c == ["hello"]"#),
  tc(unknown(), "[1+3, 2+2, 3+1, four]", "[4, 4, 4, four]"),
  tc(unknown(), "undef == {'a': 1, 'field': 2}.field", #"undef == {"a": 1, "field": 2}.field"#),
  tc(unknown(), "undef in {'a': 1, 'field': [2, 3]}.field", #"undef in {"a": 1, "field": [2, 3]}.field"#),
  tc(unknown(), "undef == {'field': [1 + 2, 2 + 3]}", #"undef == {"field": [1 + 2, 2 + 3]}"#),
  tc(unknown(), "undef in {'a': 1, 'field': [undef, 3]}.field", #"undef in {"a": 1, "field": [undef, 3]}.field"#),
  tc(unknown("def"), "def == {'a': 1, 'field': 2}.field", "def == 2"),
  tc(unknown("def"), "def in {'a': 1, 'field': [2, 3]}.field", "def in [2, 3]"),
  tc(unknown("def"), "def == {'field': [1 + 2, 2 + 3]}", #"def == {"field": [3, 5]}"#),
  tc(unknown("def"), "def in {'a': 1, 'field': [def, 3]}.field", #"def in {"a": 1, "field": [def, 3]}.field"#),
  tc(
    partial(["foo": "bar"], "r.attr"), #"foo == "bar" && r.attr.loc in ["GB", "US"]"#,
    #"r.attr.loc in ["GB", "US"]"#),
  tc(
    partial(
      [
        "users": [
          ["name": "alice", "role": "EMPLOYEE"], ["name": "bob", "role": "MANAGER"],
          ["name": "eve", "role": "CUSTOMER"],
        ]
      ], "r.attr"),
    #"users.filter(u, u.role=="MANAGER").map(u, u.name) == r.attr.authorized["managers"]"#,
    #"["bob"] == r.attr.authorized["managers"]"#),
  PruneCase(
    input: ["users": ["alice", "bob"]], unknowns: [AttributePattern("r").qualString("attr").wildcard()],
    expr: "users.filter(u, u.startsWith(r.attr.prefix))",
    out: #"["alice", "bob"].filter(u, u.startsWith(r.attr.prefix))"#, iterRange: #"["alice", "bob"]"#),
  PruneCase(
    input: ["users": ["alice", "bob"]], unknowns: [AttributePattern("r").qualString("attr").wildcard()],
    expr: "users.filter(u, r.attr.prefix.endsWith(u))",
    out: #"["alice", "bob"].filter(u, r.attr.prefix.endsWith(u))"#, iterRange: #"["alice", "bob"]"#),
  tc(unknown("four"), "[1+3, 2+2, 3+1, four]", "[4, 4, 4, four]"),
  tc(
    unknown("four"), "[1+3, 2+2, 3+1, four].exists(x, x == four)", "[4, 4, 4, four].exists(x, x == four)",
    iterRange: "[4, 4, 4, four]"),
  tc(unknown("a", "c"), "[has(a.b), has(c.d)].exists(x, x == true)", "[has(a.b), has(c.d)].exists(x, x == true)"),
  tc(
    partial(["a": [:]], "c"), "[has(a.b), has(c.d)].exists(x, x == true)",
    "[false, has(c.d)].exists(x, x == true)"),
  tc(
    partial(["a": [:]], "c"), "[has(a.b), has(c.d)].exists(x, x == true)",
    "[false, has(c.d)].exists(x, x == true)", iterRange: "[false, has(c.d)]"),
  tc(partial(["a": [:]]), "[?a[?0], a.b]", "[a.b]"),
  tc(partial(["a": [:]], "a"), "[?a[?0], a.b].exists(x, x == true)", "[?a[?0], a.b].exists(x, x == true)"),
  tc(partial(["a": [:]]), "[?a[?0], a.b].exists(x, x == true)", "[a.b].exists(x, x == true)"),
  tc(partial(["a": [:]]), "[a[0], a.b].exists(x, x == true)", "[a[0], a.b].exists(x, x == true)"),
]

struct InterpreterPruneTests {
  private func stripWhitespace(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != " " && $0 != "\n" && $0 != "\t" }))
  }

  @Test(arguments: pruneCases)
  func prune(_ tc: PruneCase) throws {
    // cel-go's TestPrune plans every case with a registry holding proto3 TestAllTypes.
    var env = ProgramEnvironment(
      functions: StandardLibrary.functions + OptionalLibrary.functions(),
      provider: TypeRegistry(composing: proto3Types, adapter: proto3Types),
      parserOptions: [.enableOptionalSyntax(true), .populateMacroCalls(true)])
    env.decorators = [OptionalLibrary.decorator]
    let parsed = try env.parse(tc.expr)
    let program = try env.program(
      parsed, options: ProgramOptions(evalOptions: [.exhaustiveEval, .partialEval]))
    let activation: any Activation =
      tc.input.map { PartialActivationWrapper(MapActivation($0), unknowns: tc.unknowns) } ?? EmptyActivation()
    let result = program.eval(activation)
    let state = try #require(result.state)
    let pruned = pruneAST(parsed.expr, macroCalls: parsed.sourceInfo.macroCalls, state: state)
    if let iterRange = tc.iterRange {
      let compre = try #require(pruned.expr.asComprehension, "pruned expression is not a comprehension")
      #expect(try Unparser.unparse(compre.iterRange, sourceInfo: pruned.sourceInfo) == iterRange)
    }
    let actual = try Unparser.unparse(pruned.expr, sourceInfo: pruned.sourceInfo)
    #expect(stripWhitespace(actual) == stripWhitespace(tc.out), "got \(actual)")
  }
}

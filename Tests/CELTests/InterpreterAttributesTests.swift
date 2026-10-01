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
// Ported from cel-go interpreter/attributes_test.go, attribute_patterns_test.go and
// activation_test.go (the cases without protobuf messages). Go's native map and slice inputs become
// CEL maps and lists.

import Testing

@testable import CEL

private func factory(_ container: String = "") throws -> DefaultAttributeFactory {
  DefaultAttributeFactory(
    container: container.isEmpty ? .default : try Container(.name(container)), provider: TypeRegistry())
}

private func qual(_ fac: any AttributeFactory, _ id: Int64, _ value: Value, optional: Bool = false) throws
  -> any Qualifier
{
  try fac.newQualifier(objType: nil, qualID: id, value: .value(value), optional: optional)
}

private func qual(_ fac: any AttributeFactory, _ id: Int64, _ attr: any Attribute, optional: Bool = false) throws
  -> any Qualifier
{
  try fac.newQualifier(objType: nil, qualID: id, value: .attribute(attr), optional: optional)
}

private func frame(_ bindings: [String: Value]) -> ExecutionFrame {
  ExecutionFrame(MapActivation(bindings))
}

private func resolve(_ attr: any Attribute, _ vars: ExecutionFrame) -> Result<Value, ResolveError> {
  do {
    return .success(try attr.resolve(vars))
  } catch {
    return .failure(error)
  }
}

struct InterpreterAttributesTests {
  @Test func absoluteAttr() throws {
    let fac = try factory("acme.ns")
    let vars = frame(["acme.a": ["b": [MapKey.uint(4): [false: "success"]] as Value]])
    // acme.a.b[4][false]
    var attr: any Attribute = fac.absoluteAttribute(id: 1, names: ["acme.a"])
    attr = try attr.addingQualifier(qual(fac, 2, "b"))
    attr = try attr.addingQualifier(qual(fac, 3, .uint(4)))
    attr = try attr.addingQualifier(qual(fac, 4, false))
    #expect(try attr.resolve(vars) == "success")
  }

  @Test func absoluteAttrType() throws {
    let attr = try factory().absoluteAttribute(id: 1, names: ["int"])
    #expect(try attr.resolve(frame([:])) == .type(.int))
  }

  @Test func absoluteAttrError() throws {
    let fac = try factory()
    let vars = frame(["err": .error(EvalError("invalid variable computation"))])
    let attr = try fac.absoluteAttribute(id: 1, names: ["err"]).addingQualifier(qual(fac, 2, "message"))
    guard case .failure = resolve(attr, vars) else {
      Issue.record("want an error")
      return
    }
  }

  private let relativeData: Value = ["a": [-1: [2, 42]], "b": 1]

  @Test func relativeAttr() throws {
    let fac = try factory()
    // <map-literal>.a[-1][b] -> 42
    var attr = fac.relativeAttribute(id: 1, operand: EvalConst(id: 1, value: relativeData))
    attr = try attr.addingQualifier(qual(fac, 2, "a"))
    attr = try attr.addingQualifier(qual(fac, 3, -1))
    attr = try attr.addingQualifier(fac.absoluteAttribute(id: 4, names: ["b"]))
    #expect(try attr.resolve(frame(["a": ["x": 1], "b": 1])) == 42)
  }

  @Test func relativeAttrOneOf() throws {
    let fac = try factory("acme.ns")
    // <map-literal>.a[-1][b], where b resolves to acme.b.
    let data: Value = ["a": [-1: [2, 42]], "acme.b": 1]
    var attr = fac.relativeAttribute(id: 1, operand: EvalConst(id: 1, value: data))
    attr = try attr.addingQualifier(qual(fac, 2, "a"))
    attr = try attr.addingQualifier(qual(fac, 3, -1))
    attr = try attr.addingQualifier(fac.maybeAttribute(id: 4, name: "b"))
    #expect(try attr.resolve(frame(["acme.b": 1])) == 42)
  }

  @Test func relativeAttrConditional() throws {
    let fac = try factory()
    // <map-literal>.a[-1][(false ? b : c)[0]] -> 42
    let data: Value = ["a": [-1: [2, 42]], "b": [0, 1], "c": [1, 0]]
    var condAttr = fac.conditionalAttribute(
      id: 4, expr: EvalConst(id: 2, value: false), truthy: fac.absoluteAttribute(id: 5, names: ["b"]),
      falsy: fac.absoluteAttribute(id: 6, names: ["c"]))
    condAttr = try condAttr.addingQualifier(qual(fac, 7, 0))
    var attr = fac.relativeAttribute(id: 1, operand: EvalConst(id: 1, value: data))
    attr = try attr.addingQualifier(qual(fac, 2, "a"))
    attr = try attr.addingQualifier(qual(fac, 3, -1))
    attr = try attr.addingQualifier(condAttr)
    #expect(try attr.resolve(frame(["b": [0, 1], "c": [1, 0]])) == 42)
  }

  @Test func relativeAttrRelativeQualifier() throws {
    let fac = try factory("acme.ns")
    // <obj>.a[-1][<mp>[b]] == <obj>.a[-1]["second"] -> 2u
    let data: Value = ["a": [-1: ["first": .uint(1), "second": .uint(2), "third": .uint(3)]], "b": .uint(2)]
    let mp: Value = [.uint(1): "first", .uint(2): "second", .uint(3): "third"]
    var relAttr = fac.relativeAttribute(id: 4, operand: EvalConst(id: 1, value: mp))
    relAttr = try relAttr.addingQualifier(qual(fac, 5, fac.absoluteAttribute(id: 5, names: ["b"])))
    var attr = fac.relativeAttribute(id: 1, operand: EvalConst(id: 1, value: data))
    attr = try attr.addingQualifier(qual(fac, 2, "a"))
    attr = try attr.addingQualifier(qual(fac, 3, -1))
    attr = try attr.addingQualifier(relAttr)
    #expect(try attr.resolve(frame(["b": .uint(2)])) == .uint(2))
  }

  @Test func oneofAttr() throws {
    let fac = try factory("acme.ns")
    let vars = frame(["a": ["b": [2, 42]], "acme.a.b": 1, "acme.ns.a.b": "found"])
    // a.b -> acme.ns.a.b per namespace resolution.
    let attr = try fac.maybeAttribute(id: 1, name: "a").addingQualifier(qual(fac, 2, "b"))
    #expect(try attr.resolve(vars) == "found")
  }

  @Test(arguments: [(true, Value.int(42)), (false, .uint(42))])
  func conditionalAttrBranch(_ cond: Bool, _ want: Value) throws {
    let fac = try factory()
    let vars = frame(["a": [-1: [2, 42]], "b": ["c": [-1: [.uint(2), .uint(42)]]]])
    // (cond ? a : b.c)[-1][1]
    let tv = fac.absoluteAttribute(id: 2, names: ["a"])
    let fv = try fac.maybeAttribute(id: 3, name: "b").addingQualifier(qual(fac, 4, "c"))
    var attr = fac.conditionalAttribute(id: 1, expr: EvalConst(id: 0, value: .bool(cond)), truthy: tv, falsy: fv)
    attr = try attr.addingQualifier(qual(fac, 5, -1))
    attr = try attr.addingQualifier(qual(fac, 6, 1))
    #expect(try attr.resolve(vars) == want)
  }

  @Test func conditionalAttrErrorUnknown() throws {
    let fac = try factory()
    let tv = fac.absoluteAttribute(id: 2, names: ["a"])
    let fv = fac.maybeAttribute(id: 3, name: "b")
    let errCond = fac.conditionalAttribute(
      id: 1, expr: EvalConst(id: 0, value: .error(EvalError("test error"))), truthy: tv, falsy: fv)
    guard case .failure = resolve(errCond, frame([:])) else {
      Issue.record("want an error")
      return
    }
    let unkCond = fac.conditionalAttribute(
      id: 1, expr: EvalConst(id: 0, value: .unknown(UnknownSet(expressionID: 1))), truthy: tv, falsy: fv)
    #expect(try unkCond.resolve(frame([:])).isUnknown)
  }

  struct OptionalCase: Sendable {
    var quals: [Value] = []
    var optQuals: [Value] = []
    var vars: [String: Value]
    var out: Value?
    var err: String?
  }

  @Test(arguments: [
    // a.?b[0][false]
    OptionalCase(optQuals: ["b", 0, false], vars: ["a": ["b": [0: [false: "success"]]]], out: .optional("success")),
    OptionalCase(
      optQuals: ["b", .uint(0), false], vars: ["a": ["b": [0: [false: "success"]]]], out: .optional("success")),
    OptionalCase(optQuals: ["b", 0.0, false], vars: ["a": ["b": [0: [false: "success"]]]], out: .optional("success")),
    // a.?b[1] with no value
    OptionalCase(optQuals: ["b", .uint(1)], vars: ["a": ["b": [:]]], out: .optional(nil)),
    // a.b[1] with no value
    OptionalCase(quals: ["b", .uint(1)], vars: ["a": ["b": [:]]], err: "no such key: 1"),
    // a.b[?1] on an empty list
    OptionalCase(quals: ["b"], optQuals: [1], vars: ["a": ["b": []]], out: .optional(nil)),
    OptionalCase(quals: ["b", 1], vars: ["a": ["b": [:]]], err: "no such key: 1"),
    OptionalCase(quals: ["b", 1, false], vars: ["a": ["b": []]], err: "index out of bounds: 1"),
    // a.?b[0][true] with no value
    OptionalCase(optQuals: ["b", 0, false], vars: ["a": ["b": [0: [:]]]], out: .optional(nil)),
    // a.b[0][?true] with no value
    OptionalCase(quals: ["b", 0], optQuals: [true], vars: ["a": ["b": [0: [:]]]], out: .optional(nil)),
    OptionalCase(quals: ["b", 0, true], vars: ["a": ["b": [0: [:]]]], err: "no such key: true"),
    // a.b[0][false] where 'a' is optional
    OptionalCase(
      quals: ["b", 0, false], vars: ["a": .optional(["b": [0: [false: "success"]]])], out: .optional("success")),
    OptionalCase(quals: ["b", 0, false], vars: ["a": .optional(nil)], out: .optional(nil)),
    // a.?c[1][true]
    OptionalCase(optQuals: ["c", 1, true], vars: ["a": [:]], out: .optional(nil)),
    // a.c[1][true]
    OptionalCase(quals: ["c", 1, true], vars: ["a": [:]], err: "no such key: c"),
    // a, no bindings
    OptionalCase(vars: [:], err: "no such attribute(s): a"),
  ])
  func optional(_ tc: OptionalCase) throws {
    let fac = try factory("ns")
    var id: Int64 = 1
    var attr: any Attribute = fac.absoluteAttribute(id: id, names: ["a"])
    for q in tc.quals {
      id += 1
      attr = try attr.addingQualifier(qual(fac, id, q))
    }
    for q in tc.optQuals {
      id += 1
      attr = try attr.addingQualifier(qual(fac, id, q, optional: true))
    }
    switch resolve(attr, frame(tc.vars)) {
    case .success(let out):
      #expect(tc.err == nil, "got \(out), want error \(tc.err ?? "")")
      if let want = tc.out {
        #expect(out == want)
      }
    case .failure(let err):
      #expect(err.evalError.message == tc.err)
    }
  }

  @Test func optionalDynamicQualifiers() throws {
    let fac = try factory("ns")
    let vars = frame(["a": ["hello": "world", "goodbye": "universe"], "b": "hello", "c.d.e": "goodbye"])
    // a[?b]
    let a1 = try fac.absoluteAttribute(id: 1, names: ["a"]).addingQualifier(
      qual(fac, 2, fac.absoluteAttribute(id: 0, names: ["b"]), optional: true))
    #expect(try a1.resolve(vars) == .optional("world"))
    // a[?(false ? b : c.d.e)]
    let cond = fac.conditionalAttribute(
      id: 0, expr: EvalConst(id: 100, value: false), truthy: fac.absoluteAttribute(id: 101, names: ["b"]),
      falsy: fac.maybeAttribute(id: 102, name: "c.d.e"))
    let a2 = try fac.absoluteAttribute(id: 1, names: ["a"]).addingQualifier(qual(fac, 2, cond, optional: true))
    #expect(try a2.resolve(vars) == .optional("universe"))
    // a[?c.d.e] where c.d.e errors
    let cde = try fac.maybeAttribute(id: 102, name: "c.d").addingQualifier(qual(fac, 103, "e"))
    let errVars = frame(["a": ["goodbye": "universe"], "c.d": [:]])
    for optional in [false, true] {
      let a3 = try fac.absoluteAttribute(id: 1, names: ["a"]).addingQualifier(qual(fac, 2, cde, optional: optional))
      guard case .failure(let err) = resolve(a3, errVars) else {
        Issue.record("want an error")
        continue
      }
      #expect(err.evalError.message == "no such key: e")
    }
  }

  // MARK: attribute_patterns_test.go

  struct PatternAttr: Sendable {
    var unchecked = false
    var container = ""
    var name: String
    var quals: [Value] = []
  }

  private func genAttr(_ fac: any AttributeFactory, _ a: PatternAttr) throws -> any Attribute {
    var attr: any Attribute =
      a.unchecked ? fac.maybeAttribute(id: 1, name: a.name) : fac.absoluteAttribute(id: 1, names: [a.name])
    var id: Int64 = 1
    for q in a.quals {
      attr = try attr.addingQualifier(qual(fac, id, q))
      id += 1
    }
    return attr
  }

  static let patternTests: [(String, AttributePattern, [PatternAttr], [PatternAttr])] = [
    ("var", AttributePattern("var"), [.init(name: "var"), .init(name: "var", quals: ["field"])], [.init(name: "ns.var")]),
    (
      "var_namespace", AttributePattern("ns.app.var"),
      [
        .init(name: "ns.app.var"), .init(name: "ns.app.var", quals: [0]),
        .init(unchecked: true, container: "ns.app", name: "ns", quals: ["app", "var", "foo"]),
      ],
      [.init(name: "ns.var"), .init(unchecked: true, container: "ns.app", name: "ns", quals: ["var"])]
    ),
    (
      "var_field", AttributePattern("var").qualString("field"),
      [
        .init(name: "var"), .init(name: "var", quals: ["field"]), .init(unchecked: true, name: "var", quals: ["field"]),
        .init(name: "var", quals: ["field", .uint(1)]),
      ],
      [.init(name: "var", quals: ["other"])]
    ),
    (
      "var_index", AttributePattern("var").qualInt(0),
      [
        .init(name: "var"), .init(name: "var", quals: [0]), .init(name: "var", quals: [0.0]),
        .init(name: "var", quals: [0, false]), .init(name: "var", quals: [.uint(0)]),
      ],
      [.init(name: "var", quals: [1, false])]
    ),
    (
      "var_index_uint", AttributePattern("var").qualUint(1),
      [
        .init(name: "var"), .init(name: "var", quals: [.uint(1)]), .init(name: "var", quals: [.uint(1), true]),
        .init(name: "var", quals: [1, false]),
      ],
      [.init(name: "var", quals: [.uint(0)])]
    ),
    (
      "var_index_bool", AttributePattern("var").qualBool(true),
      [.init(name: "var"), .init(name: "var", quals: [true]), .init(name: "var", quals: [true, "name"])],
      [.init(name: "var", quals: [false]), .init(name: "none")]
    ),
    (
      "var_wildcard", AttributePattern("ns.var").wildcard(),
      [
        .init(name: "ns.var"), .init(unchecked: true, container: "ns", name: "var", quals: [true]),
        .init(unchecked: true, container: "ns", name: "var", quals: ["name"]),
      ],
      [.init(name: "var", quals: [false]), .init(name: "none")]
    ),
    (
      "var_wildcard_field", AttributePattern("var").wildcard().qualString("field"),
      [.init(name: "var"), .init(name: "var", quals: [true]), .init(name: "var", quals: [10, "field"])],
      [.init(name: "var", quals: [10, "other"])]
    ),
    (
      "var_wildcard_wildcard", AttributePattern("var").wildcard().wildcard(),
      [.init(name: "var"), .init(name: "var", quals: [true]), .init(name: "var", quals: [10, "field"])],
      [.init(name: "none")]
    ),
  ]

  @Test(arguments: patternTests.map(\.0))
  func attributePatternUnknownResolution(_ name: String) throws {
    let test = try #require(Self.patternTests.first { $0.0 == name })
    let (_, pattern, matches, misses) = test
    for (attrs, wantUnknown) in [(matches, true), (misses, false)] {
      for a in attrs {
        let container = a.unchecked ? try Container(.name(a.container)) : .default
        let fac = PartialAttributeFactory(container: container, provider: TypeRegistry())
        let attr = try genAttr(fac, a)
        let vars = ExecutionFrame(PartialActivationWrapper(EmptyActivation(), unknowns: [pattern]))
        switch resolve(attr, vars) {
        case .success(let v):
          #expect(wantUnknown && v.isUnknown, "\(name): \(a) got \(v)")
        case .failure(let err):
          #expect(!wantUnknown, "\(name): \(a) got error \(err.evalError)")
        }
      }
    }
  }

  @Test func attributePatternCrossReference() throws {
    let fac = PartialAttributeFactory(container: .default, provider: TypeRegistry())
    var a: any Attribute = fac.absoluteAttribute(id: 1, names: ["a"])
    a = try a.addingQualifier(fac.absoluteAttribute(id: 2, names: ["b"]))
    func eval(_ bindings: [String: Value], _ patterns: [AttributePattern]) throws -> Value {
      try a.resolve(ExecutionFrame(PartialActivationWrapper(MapActivation(bindings), unknowns: patterns)))
    }
    let unknownB = UnknownSet(expressionID: 2, attribute: AttributeTrail(variable: "b"))
    guard case .unknown(let u1) = try eval(["a": [1, 2]], [AttributePattern("b")]) else {
      Issue.record("want unknown")
      return
    }
    #expect(unknownB.contains(u1))
    guard case .unknown(let u2) = try eval(["a": [1, 2]], [AttributePattern("a").qualInt(0), AttributePattern("b")])
    else {
      Issue.record("want unknown")
      return
    }
    #expect(unknownB.contains(u2))
    guard case .unknown(let u3) = try eval(["a": [1, 2], "b": 0], [AttributePattern("a").qualInt(0).qualString("c")])
    else {
      Issue.record("want unknown")
      return
    }
    #expect(UnknownSet(expressionID: 2, attribute: AttributeTrail(variable: "a", qualifierPath: [.int(0)])).contains(u3))
    #expect(try eval(["a": [1, 2], "b": 0], []) == 1)
    // The unknown id moves when the attribute becomes more specific: a[b].c
    a = try a.addingQualifier(qual(fac, 3, "c"))
    guard case .unknown(let u4) = try eval(["a": [1, 2], "b": 0], [AttributePattern("a").qualInt(0).qualString("c")])
    else {
      Issue.record("want unknown")
      return
    }
    #expect(
      UnknownSet(expressionID: 3, attribute: AttributeTrail(variable: "a", qualifierPath: [.int(0), .string("c")])).contains(
        u4))
  }

  @Test func attributePatternLocallyBound() throws {
    let fac = PartialAttributeFactory(container: .default, provider: TypeRegistry())
    let frame = ExecutionFrame(
      PartialActivationWrapper(EmptyActivation(), unknowns: [AttributePattern("x"), AttributePattern("y")]))
    let unit = EvalConst(id: 0, value: .null)
    let fold = EvalFold(
      id: 0, accuVar: "", iterVar: "x", iterVar2: "", iterRange: unit, accu: unit, cond: unit, step: unit,
      result: unit)
    let folder = Folder(fold: fold, parentFrame: frame)
    let frame1 = frame.push(folder)
    #expect(!(try fac.absoluteAttribute(id: 1, names: ["x"]).resolve(frame1)).isUnknown)
    #expect(try fac.absoluteAttribute(id: 2, names: ["y"]).resolve(frame1).isUnknown)
  }

  @Test func partialAttributeFactoryResolveUnknownQualifier() throws {
    let fac = PartialAttributeFactory(container: .default, provider: TypeRegistry())
    let vars = ExecutionFrame(
      PartialActivationWrapper(MapActivation(["a": ["b": 1]]), unknowns: [AttributePattern("a").qualString("b")]))
    let a = try fac.absoluteAttribute(id: 1, names: ["a"]).addingQualifier(qual(fac, 2, "b"))
    guard case .unknown(let u) = try a.resolve(vars) else {
      Issue.record("want unknown")
      return
    }
    #expect(UnknownSet(expressionID: 2, attribute: AttributeTrail(variable: "a", qualifierPath: [.string("b")])).contains(u))
    #expect(fac.maybeAttribute(id: 10, name: ".global_var").id == 10)
  }

  // MARK: activation_test.go

  @Test func hierarchicalActivation() {
    let parent = MapActivation(["a": "world", "b": -42])
    let child = MapActivation(["a": true, "c": "universe"])
    let combined = HierarchicalActivation(parent: parent, child: child)
    #expect(combined.resolveName("a") == true)
    #expect(combined.resolveName("b") == -42)
    #expect(combined.resolveName("c") == "universe")
    #expect(combined.resolveName("d") == nil)
  }

  @Test func asPartialActivation() {
    let parent = PartialActivationWrapper(MapActivation(["a": "world"]), unknowns: [AttributePattern("c")])
    let child = MapActivation(["d": "universe"])
    let combined = HierarchicalActivation(parent: parent, child: child)
    #expect(combined.asPartialActivation()?.unknownAttributePatterns == [AttributePattern("c")])
    #expect(child.asPartialActivation() == nil)
  }

  @Test func lazyActivationResolvesOnce() {
    final class Counter: @unchecked Sendable { var n = 0 }
    let counter = Counter()
    let act = LazyActivation(lazy: [
      "now": {
        counter.n += 1
        return .int(Int64(counter.n))
      }
    ])
    #expect(act.resolveName("now") == 1)
    #expect(act.resolveName("now") == 1)
    #expect(act.resolveName("other") == nil)
  }

  @Test func isLocalVariableNested() {
    let frame = ExecutionFrame(EmptyActivation())
    let unit = EvalConst(id: 0, value: .null)
    let fold1 = EvalFold(
      id: 0, accuVar: "accu1", iterVar: "iter1", iterVar2: "iter1_2", iterRange: unit, accu: unit, cond: unit,
      step: unit, result: unit)
    let frame1 = frame.push(Folder(fold: fold1, parentFrame: frame))
    let fold2 = EvalFold(
      id: 0, accuVar: "accu2", iterVar: "iter2", iterVar2: "", iterRange: unit, accu: unit, cond: unit, step: unit,
      result: unit)
    let frame2 = frame1.push(Folder(fold: fold2, parentFrame: frame1))
    for (name, want) in [
      ("accu2", true), ("iter2", true), ("accu1", true), ("iter1", true), ("iter1_2", true), ("x", false),
    ] {
      #expect(frame2.isLocalVariable(name) == want, "\(name)")
    }
  }
}

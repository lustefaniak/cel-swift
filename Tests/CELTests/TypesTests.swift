// Copyright 2023 Google LLC
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
// Ported from cel-go common/types/types_test.go, type_test.go and the non-protobuf parts of
// provider_test.go.

import Testing

@testable import CEL

struct TypesTests {
  @Test(arguments: [
    (CELType.list(.int), "list(int)"),
    (.map(key: .uint, value: .double), "map(uint, double)"),
    (.bool, "bool"),
    (.dyn, "dyn"),
    (.null, "null_type"),
    (.wrapper(.bool), "wrapper(bool)"),
    (.optional(.list(.string)), "optional_type(list(string))"),
    (.objectType("my.type.Message"), "my.type.Message"),
    (.objectType("google.protobuf.Int32Value"), "wrapper(int)"),
    (.objectType("google.protobuf.UInt32Value"), "wrapper(uint)"),
    (.objectType("google.protobuf.Value"), "dyn"),
    (.type(.string), "type(string)"),
    (.typeParam("T"), "<T>"),
    (.listOfDyn, "list(dyn)"),
    (.mapOfDyn, "map(dyn, dyn)"),
  ])
  func typeString(type: CELType, out: String) {
    #expect(type.description == out)
  }

  @Test(arguments: [
    (CELType.string, CELType.string, true),
    (.string, .int, false),
    (.optional(.string), .optional(.int), false),
    (.optional(.uint), .optional(.uint), true),
    (.optional(.typeParam("T")), .optional(.typeParam("T")), true),
    (.map(key: .bool, value: .int), .map(key: .bool, value: .int), true),
    (.map(key: .typeParam("K1"), value: .int), .map(key: .typeParam("K2"), value: .int), false),
    (
      .map(key: .typeParam("K1"), value: .object("my.msg.First")),
      .map(key: .typeParam("K2"), value: .object("my.msg.Last")), false
    ),
  ])
  func isExactType(t1: CELType, t2: CELType, isExact: Bool) {
    #expect(t1.isExactType(t2) == isExact)
  }

  @Test(arguments: [
    (CELType.string, CELType.string, true),
    (.string, .int, false),
    (.optional(.string), .optional(.int), false),
    (.optional(.uint), .optional(.uint), true),
    (.map(key: .bool, value: .int), .map(key: .bool, value: .int), true),
    (.map(key: .typeParam("K1"), value: .int), .map(key: .typeParam("K2"), value: .int), true),
    (
      .map(key: .typeParam("K1"), value: .object("my.msg.First")),
      .map(key: .typeParam("K2"), value: .object("my.msg.Last")), false
    ),
  ])
  func isEquivalentType(t1: CELType, t2: CELType, isEquivalent: Bool) {
    #expect(t1.isEquivalentType(t2) == isEquivalent)
  }

  @Test(arguments: [
    (CELType.wrapper(.double), CELType.null, true),
    (.wrapper(.double), .double, true),
    (.opaque(name: "vector", parameters: [.wrapper(.double)]), .opaque(name: "vector", parameters: [.null]), true),
    (.opaque(name: "vector", parameters: [.wrapper(.double)]), .opaque(name: "vector", parameters: [.double]), true),
    (.opaque(name: "vector", parameters: [.dyn]), .opaque(name: "vector", parameters: [.wrapper(.int)]), true),
    (.object("my.msg.MsgName"), .object("my.msg.MsgName"), true),
    (.map(key: .typeParam("K"), value: .int), .map(key: .string, value: .int), true),
    (.map(key: .string, value: .int), .map(key: .typeParam("K"), value: .int), false),
    (.opaque(name: "vector", parameters: [.double]), .opaque(name: "vector", parameters: [.wrapper(.int)]), false),
    (.opaque(name: "vector", parameters: [.wrapper(.double)]), .opaque(name: "vector", parameters: [.dyn]), false),
    (.object("my.msg.MsgName"), .object("my.msg.MsgName2"), false),
  ])
  func isAssignableType(t1: CELType, t2: CELType, isAssignable: Bool) {
    #expect(t1.isAssignable(from: t2) == isAssignable)
  }

  @Test func isAssignableRuntimeType() {
    let oneNano = Value.duration(CELDuration(nanoseconds: 1))
    let tests: [(CELType, Value, Bool)] = [
      (.wrapper(.double), .null, true),
      (.wrapper(.double), .double(0), true),
      (.list(.string), .map(OrderedMap()), false),
      (.list(.string), [], true),
      (.list(.string), [oneNano], false),
      (.list(.string), ["hello"], true),
      (.map(key: .string, value: .duration), .map(OrderedMap()), true),
      (.map(key: .string, value: .duration), ["one": oneNano], true),
      (.map(key: .string, value: .dyn), ["one": oneNano], true),
      (.map(key: .dyn, value: .dyn), ["one": oneNano], true),
      (.map(key: .string, value: .duration), ["one": .int(1)], false),
    ]
    for (type, value, expected) in tests {
      #expect(type.isAssignableRuntime(value) == expected, "\(type) <- \(value)")
    }
  }

  @Test func hasTrait() {
    #expect(CELType.bool.hasTrait(.comparer))
    #expect(CELType.bool.hasTrait([.comparer, .negator]))
    #expect(CELType.bool.hasTrait(.adder) == false)
    #expect(CELType.list(.int).hasTrait(TypeTraits.lister))
    #expect(CELType.object("my.Msg").hasTrait([.fieldTester, .indexer]))
    #expect(CELType.wrapper(.int).traits == CELType.int.traits)
  }

  @Test func kindsAndNames() {
    #expect(CELType.wrapper(.int).kind == .int)
    #expect(CELType.wrapper(.int).declaredTypeName == "wrapper(int)")
    #expect(CELType.duration.runtimeTypeName == "google.protobuf.Duration")
    #expect(CELType.objectType("google.protobuf.Struct") == .map(key: .string, value: .dyn))
    #expect(CELType.optional(.int).parameters == [.int])
    #expect(CELType.type(nil).parameters.isEmpty)
  }

  // type_test.go: Type values convert to `type` and `string`.
  @Test func typeValueConversions() {
    #expect(Value.type(.int).convert(to: .type(nil)) == .type(.type(nil)))
    #expect(Value.type(.list(.int)).convert(to: .string) == "list")
    #expect(
      Value.type(.int).convert(to: .int)
        == .error(EvalError("type conversion error from 'type' to 'int'")))
    #expect(Value.type(.int).celType == .type(nil))
    #expect(Value.type(.list(.int)).celEquals(.type(.list(.string))) == true)
    #expect(Value.type(.int).celEquals(.type(.uint)) == false)
  }
}

// MARK: - Registry (provider_test.go, non-protobuf)

private struct MyStruct: ObjectValue {
  var foo: String
  var bar: Int64

  var celType: CELType { .object("custom.MyStruct") }

  func field(_ name: String) -> Value {
    switch name {
    case "Foo": return .string(foo)
    case "Bar": return .int(bar)
    default: return .error(EvalError("no such field '\(name)'"))
    }
  }

  func isFieldSet(_ name: String) -> Value {
    switch name {
    case "Foo": return .bool(!foo.isEmpty)
    case "Bar": return .bool(bar != 0)
    default: return .error(EvalError("no such field '\(name)'"))
    }
  }

  func isEqual(to other: any ObjectValue) -> Bool {
    guard let other = other as? MyStruct else { return false }
    return foo == other.foo && bar == other.bar
  }
}

private struct MyStructDescriptor: StructTypeDescriptor {
  var typeName: String { "custom.MyStruct" }
  var fieldNames: [String] { ["Bar", "Foo"] }

  func fieldType(named name: String) -> StructFieldType? {
    switch name {
    case "Foo": return StructFieldType(name: name, type: .string)
    case "Bar": return StructFieldType(name: name, type: .int)
    default: return nil
    }
  }

  func newValue(fields: [String: Value]) -> Value {
    var s = MyStruct(foo: "", bar: 0)
    for (name, value) in fields {
      switch (name, value) {
      case ("Foo", .string(let v)): s.foo = v
      case ("Bar", .int(let v)): s.bar = v
      default: return .error(EvalError("no such field: \(name)"))
      }
    }
    return .object(s)
  }
}

struct TypeRegistryTests {
  private func registry() throws -> TypeRegistry {
    var reg = TypeRegistry()
    try reg.register(MyStructDescriptor())
    return reg
  }

  @Test func registerType() throws {
    var reg = TypeRegistry()
    try reg.register(.opaque(name: "http.Request", parameters: [.typeParam("T")]))
    try reg.register(.opaque(name: "http.Request", parameters: [.typeParam("V")]))
    var reg2 = TypeRegistry()
    try reg2.register(.opaque(name: "http.Request", parameters: [.typeParam("T"), .typeParam("V")]))
    #expect(throws: DeclarationError.self) {
      try reg2.register(.opaque(name: "http.Request", parameters: [.typeParam("V")]))
    }
    var reg3 = TypeRegistry()
    #expect(throws: DeclarationError.self) {
      try reg3.register(.object("bool"))
    }
  }

  @Test func copyIsIndependent() throws {
    let original = TypeRegistry()
    var copy = original
    try copy.register(MyStructDescriptor())
    #expect(copy.findStructType("custom.MyStruct") != nil)
    #expect(original.findStructType("custom.MyStruct") == nil)
  }

  @Test func standardIdentifiers() {
    let reg = TypeRegistry()
    #expect(reg.findIdent("int") == .type(.int))
    #expect(reg.findIdent("list") == .type(.listOfDyn))
    #expect(reg.findIdent("google.protobuf.Duration") == .type(.duration))
    #expect(reg.findIdent("nope") == nil)
    #expect(TypeRegistry.empty.findIdent("int") == nil)
  }

  @Test func enumValues() {
    var reg = TypeRegistry()
    reg.registerEnumValue("google.expr.proto3.test.GlobalEnum.GOO", number: 0)
    reg.registerEnumValue("google.expr.proto3.test.GlobalEnum.GAR", number: 1)
    #expect(reg.enumValue("google.expr.proto3.test.GlobalEnum.GAR") == .int(1))
    #expect(reg.findIdent("google.expr.proto3.test.GlobalEnum.GOO") == .int(0))
    #expect(reg.enumValue("x.Y") == .error(EvalError("unknown enum name 'x.Y'")))
  }

  @Test func structTypeDescriptor() throws {
    let reg = try registry()
    for name in ["custom.MyStruct", ".custom.MyStruct"] {
      let st = try #require(reg.findStructType(name))
      #expect(st.runtimeTypeName == "type")
      #expect(st.parameters.first?.runtimeTypeName == "custom.MyStruct")
    }
    #expect(reg.findStructFieldNames("custom.MyStruct") == ["Bar", "Foo"])
    #expect(reg.findStructFieldType("custom.MyStruct", fieldName: "Foo")?.type == .string)
    #expect(reg.findStructFieldType("custom.MyStruct", fieldName: "Bar")?.type == .int)
    #expect(reg.findStructFieldType("custom.MyStruct", fieldName: "Baz") == nil)
    #expect(reg.findIdent("custom.MyStruct") != nil)

    let val = reg.newValue("custom.MyStruct", fields: ["Foo": "hello", "Bar": 42])
    #expect(val.get("Foo") == "hello")
    #expect(val.get("Bar") == 42)
    let field = try #require(reg.findStructFieldType("custom.MyStruct", fieldName: "Bar"))
    guard case .object(let object) = val else {
      Issue.record("expected an object, got \(val)")
      return
    }
    #expect(field.isSet(object))
    #expect(field.getFrom(object) == 42)
    #expect(reg.newValue("custom.Missing", fields: [:]) == .error(EvalError("unknown type 'custom.Missing'")))
  }

  @Test func composedProvider() throws {
    let base = try registry()
    let composed = TypeRegistry(composing: base)
    #expect(composed.findStructType("custom.MyStruct") != nil)
    #expect(composed.newValue("custom.MyStruct", fields: ["Bar": 1]).get("Bar") == 1)
  }

  @Test func nativeToValuePrimitive() {
    let reg = TypeRegistry()
    let tests: [(Any, Value)] = [
      (true, true),
      (Int(-10), -10),
      (Int32(-1), -1),
      (Int64(2), 2),
      (UInt(6), .uint(6)),
      (UInt32(3), .uint(3)),
      (UInt64(4), .uint(4)),
      (Float(5.5), 5.5),
      (Double(-5.5), -5.5),
      ("hello", "hello"),
      (Array("world".utf8), .bytes(Array("world".utf8))),
      (CELDuration(nanoseconds: 500), .duration(CELDuration(nanoseconds: 500))),
      (CELTimestamp(secondsSinceEpoch: 12345), .timestamp(CELTimestamp(secondsSinceEpoch: 12345))),
      ([Int32(1), 2, 3], [1, 2, 3]),
      (["a": 1] as [String: Any], ["a": 1]),
      ([Int32(1): Int32(1)] as [AnyHashable: Any], [1: 1]),
      (Optional<Int>.none as Any, .null),
      (Optional<Int>.some(3) as Any, 3),
    ]
    for (input, want) in tests {
      #expect(reg.nativeToValue(input) == want, "\(input)")
    }
  }

  @Test func unsupportedConversion() {
    struct NonConvertible {}
    #expect(TypeRegistry().nativeToValue(NonConvertible()).isError)
  }
}
